# Notice

This repository contains modified versions of work by other people. The AGPL
requires that those modifications are stated, and this file is that statement.

## `image/entrypoint.sh`

Derived from `games/arma3/entrypoint.sh` in
[pelican-eggs/yolks](https://github.com/pelican-eggs/yolks).

Copyright (C) 2025 David Wolfe (Red-Thirten) and contributors.
Contributors: Aussie Server Hosts, Stephen White (SilK).
Licensed **AGPL-3.0-or-later**, and this fork is distributed under the same
licence. The full text is in [`LICENSE`](LICENSE).

Modifications, © 2026 FyWolf. Every one of them is marked in-file with `A3M`:

1. **Progress reporting.** A block of functions (`A3M_Init`, `A3M_SetState`,
   `A3M_Phase`, `A3M_Render`, `A3M_Name`, `A3M_Wanted`, `A3M_MonitorStart`,
   `A3M_MonitorStop`, `A3M_Enabled`) writes `.arma3-manager/status.json`
   describing each mod's state, byte count, percentage and failure reason.
2. **Hooks into the existing mod loop.** The load order is seeded as `waiting`
   before any download starts; the mod being fetched is marked `downloading`; the
   result is marked `done` or `failed` from whether the mod folder exists; a mod
   upstream skips as already-current is marked `done`.
3. **A background monitor** rewrites the status file on a timer while SteamCMD
   works, so a large mod shows a moving percentage.
4. **`A3M_SYNC_ONLY`.** When set, mods are downloaded and updated and the script
   exits 0 without starting the game server.
5. **A background sync daemon** is started alongside the game server and killed
   with it, so mods can be downloaded at any time without a restart.
6. **The A3M functions were moved** into `a3m-common.sh`, which the entrypoint
   sources, so the daemon and the boot-time download report identically.
7. **Header comment** recording the fork and pointing here.

Nothing else is changed. The SteamCMD invocation, retry and error handling, mod
linking, key handling, lowercase repair, headless clients, parameter file
generation and the server launch are upstream's and are untouched.

## `image/a3m-common.sh` and `image/a3m-sync.sh`

New files, © 2026 FyWolf, AGPL-3.0-or-later.

`a3m-common.sh` holds the progress-reporting functions lifted out of the forked
entrypoint, so that the entrypoint and the sync daemon share one implementation.
`a3m-sync.sh` is entirely new: a background downloader that watches for a request
file written by the panel and fetches Workshop items while the server runs.

Neither contains upstream code beyond the functions noted above.

## `image/Dockerfile`

Derived from `games/arma3/Dockerfile` in the same repository, AGPL-3.0-or-later.

Modifications: `jq` added to the installed packages (the entrypoint requires it);
`apt` lists cleaned up in the same layer; image labels repointed at this
repository; `a3m-common.sh` and `a3m-sync.sh` copied in alongside the
entrypoint.

## `image/passwd.template`

Unmodified, from the same repository.

## `egg-arma3-manager.json`

Derived from `arma/arma3/egg-arma3.json` in
[pelican-eggs/games-steamcmd](https://github.com/pelican-eggs/games-steamcmd),
by David Wolfe (Red-Thirten), MIT licensed.

It is **generated** by [`build-egg.py`](build-egg.py) rather than edited, so the
difference from upstream stays reviewable. The transform changes the egg's
identity (name, author, uuid, description, tags), repoints `docker_images` at
this repository's image, and appends three variables — `A3M_SYNC_ONLY`,
`A3M_POLL_INTERVAL` and `A3M_DISABLE`.

The install script, the config-file parsers, the startup command and all
twenty-five upstream variables are passed through unchanged; `build-egg.py`
fails rather than overwrite an upstream variable that gains one of these names.

`upstream-egg-arma3.json` is a verbatim copy of the source document, kept so the
transform can be re-run and diffed.
