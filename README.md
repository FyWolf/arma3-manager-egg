# Arma 3 Manager — egg and image

A Pelican egg and container image for Arma 3 dedicated servers that **report what
their mod downloads are doing**, for use with the
[`arma3-manager`](https://github.com/FyWolf/arma3-manager) panel plugin.

It is a fork of the stock Arma 3 egg and yolk, and a deliberately small one. Mods
download exactly as they do upstream — same SteamCMD calls, same retries, same
linking. The difference is that this one writes down what happened.

**Licence:** AGPL-3.0-or-later, inherited from the upstream entrypoint. See
[`NOTICE.md`](NOTICE.md) for what was changed and by whom.

## Why this exists

The panel cannot see inside a running container. It can read files, and that is
all — so with the stock image, "how far along is this download?" has to be
inferred from directory listings.

That inference is weak in ways that matter:

| Question | Directory listing | This egg |
|---|---|---|
| Is the mod on disk? | yes | yes |
| Is it downloading right now? | roughly — the staging directory exists | yes |
| **How far through is it?** | **no** | yes, by size |
| **What is it called?** | no — the panel must ask Steam | yes |
| **Did it fail, and why?** | **no. A failed mod and a queued mod look identical** | yes, with the reason |

The last row is the one that justifies the fork. Upstream reports a failed
download to the **console**, which scrolls away and which no panel parses. On
disk, a mod that failed after three attempts is indistinguishable from one that
has not been reached yet — both are simply absent. So the page says "waiting"
forever, and the customer waits for something that already gave up.

## What it writes

`.arma3-manager/status.json`, next to the mods it describes:

```json
{
  "version": 1,
  "updated_at": 1757001234,
  "phase": "mods",
  "sync_only": false,
  "totals": { "total": 4, "done": 2, "downloading": 1, "waiting": 0, "failed": 1 },
  "mods": [
    { "id": "450814997", "state": "done",        "name": "CBA_A3", "bytes": 231334, "expected_bytes": 231334, "percent": 100, "error": null },
    { "id": "463939057", "state": "downloading", "name": "ACE3",   "bytes": 4194304, "expected_bytes": 8388608, "percent": 50, "error": null },
    { "id": "332350688", "state": "failed",      "name": "RHSAFRF","bytes": 0, "expected_bytes": 9663676416, "percent": 0, "error": "SteamCMD did not produce @332350688. …" }
  ]
}
```

`phase` is one of `starting`, `mods`, `running`, `synced`, `synced_with_errors`.
A mod's `state` is `waiting`, `downloading`, `done` or `failed`.

The file is written to a temporary name and **moved** into place, so a poll never
reads a half-written document.

### Where the percentage comes from

Measured, not estimated. SteamCMD stages an item in
`Steam/steamapps/workshop/downloads/<app>/<id>` while it transfers and moves it
into `content/<app>/<id>` when it completes, so the size of the staging directory
against the item's known size is a real fraction.

SteamCMD's own transfer output gives nothing usable here: `workshop_download_item`
prints no incremental progress in a non-interactive shell. Sizing the directory
is the only honest source, which is why a background monitor samples it on a
timer rather than parsing a log.

`expected_bytes` comes from `.arma3-manager/wanted.json`, which the **panel**
writes before the container starts — it has the Steam Web API and this container
deliberately has no credentials beyond the server's own. Without that file
everything still works; `percent` and `expected_bytes` are simply `null` and the
page shows state without a bar.

The percentage is clamped to 100. It genuinely can overshoot: a mod updated since
the panel last looked is larger than its recorded size.

**A percentage is per mod, not per set.** A ten-mod set does not report "40%"
across the whole download, because the sizes of mods that have not started are
only as good as `wanted.json`.

## Background downloads

**This is the feature the fork exists for.** Mods download while the server runs,
on request, with no restart and no stop.

Upstream fetches mods in the entrypoint, *before* the game binary launches. So
every mod change costs a restart, and every restart costs however long the
download takes — on a 40 GB set that is the session, not an inconvenience.

Here, `a3m-sync.sh` runs alongside the game. The panel writes
`.arma3-manager/request.json` at any time; the daemon picks it up within
`A3M_SYNC_POLL` seconds and downloads into the SteamCMD cache while players carry
on playing, reporting through the same `status.json` as a boot-time download.

```
panel writes request.json  ──►  daemon claims it (request.active.json)
                                     │
                                     ├── downloads into Steam/steamapps/workshop/content/
                                     ├── writes status.json every few seconds
                                     └── logs to the console and .arma3-manager/sync.log
```

### What it deliberately does not do

**It does not build the `@<id>` folders.** Those are what the running server has
open, and the entrypoint's linking step starts with `rm -rf @<id>` — doing that
underneath a live Arma is how you corrupt a session.

There is nothing to gain by it either: **Arma reads its mod list once, at
startup**, so a mod linked now could not be loaded before the next restart
regardless. The next boot links it, and because the files are already cached that
step is a hard-link copy rather than a download.

So this makes the **download** asynchronous. Activation is still a restart —
Arma gives no other option — but the restart is as fast as one with no mod
changes at all, which is the whole point.

### The parts that stop it eating the server

- **`nice`** (`A3M_SYNC_NICE`, default 10). Arma is latency sensitive in a way a
  download is not. A background sync that costs the players their tickrate is not
  a background sync.
- **It starts after the boot update finishes**, never beside it. Two SteamCMD
  processes against one Steam account and one workshop directory is a race over
  the same files, and the loser looks like a corrupt mod.
- **A lock** (`mkdir`, which is atomic) so two requests cannot overlap. A lock
  older than two hours is assumed to belong to a container that was killed
  mid-download and is broken open — otherwise one `docker kill` at the wrong
  moment disables background sync permanently.
- **It is killed with the server.** Without that the daemon survives as an orphan
  and the next start has two of them polling the same file.
- **A request is claimed by renaming it**, so the panel can queue a new one while
  the current one runs.

### When the server is off

Nothing runs, because there is no container. Two options then: start the server
normally, or use `A3M_SYNC_ONLY` below to download without bringing the game up.

## Sync without starting the server

Set `A3M_SYNC_ONLY=1`. The container downloads and updates every mod, writes the
final status, and exits **0** without launching Arma.

Exit 0 matters: Wings treats a non-zero exit as a crash, and a crash-restart
policy would turn download-and-exit into a loop.

This is what lets a customer fetch a 40 GB mod set in the afternoon and start the
server in the evening without the wait. It does not let mods change under a
*running* server, and nothing can — Arma reads its mod list once, at startup. The
only thing ever in question is when the restart happens; this puts that in the
customer's hands.

Remember to set it back to `0`, or the server will never start. The console says
so on every sync.

## Installing

1. **Import the egg.** Admin → Eggs → Import Egg, and give it
   `egg-arma3-manager.json` from this repository (or its raw URL). It carries its
   own uuid, so it is a *new* egg and does not modify the stock Arma 3 one.
2. **Point servers at it.** Existing Arma 3 servers can be switched over; the
   image and the mod layout are compatible, so nothing needs re-downloading.
3. **Map it in the plugin.** Admin → Arma 3 Eggs in `arma3-manager`, so the
   pages appear. The `arma3-manager` tag and the 233780 app id both let it be
   detected automatically, but pinning it writes the decision down.
4. **Steam credentials** are unchanged and still per-server: `STEAM_USER` and
   `STEAM_PASS` on the egg, an account that owns Arma 3. This repository adds no
   shared credential and the panel still holds none.

The image is published to `ghcr.io/fywolf/arma3-manager-egg:latest`.

## Added variables

| Variable | Default | Editable by customer | What it does |
|---|---|---|---|
| `A3M_SYNC_ONLY` | `0` | yes | Download mods, then exit without starting the server |
| `A3M_BACKGROUND_SYNC` | `1` | no | Run the downloader alongside the server |
| `A3M_SYNC_POLL` | `10` | no | Seconds between checks for a download request |
| `A3M_SYNC_NICE` | `10` | no | How far the downloader yields to the game (`nice`, 0–19) |
| `A3M_POLL_INTERVAL` | `5` | no | Seconds between progress rewrites |
| `A3M_DISABLE` | `0` | no | Stop writing `status.json` entirely |

`A3M_POLL_INTERVAL` is a host knob, not a customer one: each rewrite walks the
transferring mod's directory, so a one-second interval costs disk I/O on a busy
node and buys nothing but a smoother bar.

`A3M_DISABLE` exists to answer "is this fork the problem?" in one restart. With
it set the container behaves exactly as the stock image and the plugin falls back
to directory probing.

## Developing

```bash
bash tests/status-json.sh              # 30 assertions on the status file
bash tests/sync.sh                     # 28 assertions on the background daemon
python build-egg.py                    # regenerate the egg from upstream
bash -n image/{entrypoint,a3m-common,a3m-sync}.sh
```

Neither test needs a container. `tests/status-json.sh` sources `a3m-common.sh`
and runs it against a fake server directory with real files, so byte counts and
percentages are measured rather than mocked. `tests/sync.sh` goes further and
runs the real `ProcessRequest` against a **fake SteamCMD** — a stub that creates
or refuses to create the content directory — because the interesting failures are
in the wiring: a request claimed but never released, a lock that outlives its
process, a download that "succeeds" while fetching nothing. Stubbing
`DownloadOne` would catch none of those.

Both need `jq`, which the image needs too.

**Run it before building an image.** The status file is the only thing the panel
reads, and every way it can be wrong is silent — a malformed document, a missed
transition or a bad percentage all leave the download working perfectly and the
page reporting nonsense, with no error anywhere.

Four bugs these caught, every one of which reads fine in the source: seeding
parsed a semicolon-separated list as one token and tracked nothing; the optional
error argument aborted the script under `set -u`; `A3M_DAEMON_RUNNING` was read
before it was ever set, which would abort any egg that does not declare every
variable; and a **carriage return** in an id — from a Windows-pasted egg variable
— made it fail `^[0-9]+$` and be dropped silently, invisible in every log because
a CR just moves the cursor.

### Pulling a newer upstream

```bash
curl -sSLo upstream-egg-arma3.json \
  https://raw.githubusercontent.com/pelican-eggs/games-steamcmd/main/arma/arma3/egg-arma3.json
python build-egg.py
```

The egg is a transform, so this is the whole update. `build-egg.py` fails loudly
if upstream adds a variable named like one of ours.

The **entrypoint** is a genuine fork and has to be merged by hand. Every change
is marked `A3M`, which is what keeps that diff readable — please keep it that way.

## Relationship to the stock egg

Use the stock egg if you do not run the `arma3-manager` plugin. This one exists
solely to feed that plugin better information; on its own it is the stock egg
plus a JSON file nothing reads.
