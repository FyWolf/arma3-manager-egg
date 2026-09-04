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
bash tests/status-json.sh    # 30 assertions, no container needed
python build-egg.py          # regenerate the egg from upstream
bash -n image/entrypoint.sh  # syntax
```

`tests/status-json.sh` extracts the `A3M` functions out of the entrypoint and
runs them against a fake server directory with real files, so the byte counts and
percentages are measured rather than mocked. It needs `jq`, which the entrypoint
needs too.

**Run it before building an image.** The status file is the only thing the panel
reads, and every way it can be wrong is silent — a malformed document, a missed
transition or a bad percentage all leave the download working perfectly and the
page reporting nonsense, with no error anywhere.

Two bugs it caught the first time it ran, both of which read fine in the source:
seeding parsed a semicolon-separated list as one token and silently tracked
nothing, and the optional error argument aborted the script under `set -u`.

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
