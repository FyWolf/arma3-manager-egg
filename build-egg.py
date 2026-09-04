#!/usr/bin/env python3
"""Generate egg-arma3-manager.json from the upstream Arma 3 egg.

The egg is *derived*, never hand-edited. Upstream owns the install script, the
config-file parsers and twenty-six variables, all of which change over time; the
only things this fork owns are the image, the identity and three added
variables. Keeping that as a transform means pulling a newer upstream egg is
re-running this script and reading the diff, rather than replaying edits by hand
into a 21 KB JSON document and hoping nothing was missed.

Usage:
    python build-egg.py [path/to/upstream-egg-arma3.json]
"""

import json
import sys
from collections import OrderedDict

UPSTREAM = sys.argv[1] if len(sys.argv) > 1 else "upstream-egg-arma3.json"
OUTPUT = "egg-arma3-manager.json"

IMAGE = "ghcr.io/fywolf/arma3-manager-egg:latest"
REPO = "https://github.com/FyWolf/arma3-manager-egg"

# The variables this fork adds. Everything else on the egg is upstream's.
#
# All three are `user_viewable` but only SYNC_ONLY is `user_editable`: a customer
# has a real reason to press "download without starting", and no reason at all to
# retune a poll interval or switch the progress reporting off. Both of those are
# host-side knobs, visible so that a support conversation can confirm what they
# are set to.
ADDED = [
    OrderedDict([
        ("name", "[A3M] Sync Mods Without Starting"),
        ("description",
         "When enabled, the container downloads and updates all mods and then exits "
         "without starting the game server. Use this to fetch a large mod set before "
         "a session rather than making players wait through it at boot.\n\n"
         "Arma reads its mod list once, at startup, so mods fetched while a server is "
         "running would not load until the next restart anyway — this only decides "
         "when that restart happens.\n\n"
         "Remember to turn this back off, or the server will never start. "
         "(1 Enable | 0 Disable)"),
        ("env_variable", "A3M_SYNC_ONLY"),
        ("default_value", "0"),
        ("user_viewable", True),
        ("user_editable", True),
        ("rules", ["required", "boolean"]),
    ]),
    OrderedDict([
        ("name", "[A3M] Background Mod Downloads"),
        ("description",
         "Runs a mod downloader alongside the game server, so mods can be fetched at "
         "any time from the panel without stopping or restarting anything.\n\n"
         "Downloads go into the SteamCMD cache. The mods themselves are activated at "
         "the next restart, because Arma reads its mod list once at startup and there "
         "is no way around that — but the restart is then instant instead of waiting "
         "for a download.\n\n"
         "Turn this off to get the stock behaviour, where mods are only ever fetched "
         "while the server boots. (1 Enable | 0 Disable)"),
        ("env_variable", "A3M_BACKGROUND_SYNC"),
        ("default_value", "1"),
        ("user_viewable", True),
        ("user_editable", False),
        ("rules", ["required", "boolean"]),
    ]),
    OrderedDict([
        ("name", "[A3M] Background Sync Check Interval"),
        ("description",
         "Seconds between checks for a download request from the panel. This is a "
         "cheap check for one file, so a short interval costs almost nothing — it "
         "mostly decides how quickly a customer sees their download start."),
        ("env_variable", "A3M_SYNC_POLL"),
        ("default_value", "10"),
        ("user_viewable", True),
        ("user_editable", False),
        ("rules", ["required", "integer", "between:2,600"]),
    ]),
    OrderedDict([
        ("name", "[A3M] Background Sync Priority"),
        ("description",
         "How far the background downloader yields to the game server, as a `nice` "
         "value from 0 (equal footing) to 19 (only spare capacity).\n\n"
         "Arma is latency sensitive in a way a download is not, so the default leans "
         "well away from the game. A background sync that costs the players their "
         "tickrate is not a background sync."),
        ("env_variable", "A3M_SYNC_NICE"),
        ("default_value", "10"),
        ("user_viewable", True),
        ("user_editable", False),
        ("rules", ["required", "integer", "between:0,19"]),
    ]),
    OrderedDict([
        ("name", "[A3M] Progress Poll Interval"),
        ("description",
         "Seconds between rewrites of .arma3-manager/status.json while mods download. "
         "Each rewrite measures the size of the mod currently transferring, which is a "
         "directory walk — so a very short interval costs disk I/O on a busy node and "
         "buys a smoother bar and nothing else."),
        ("env_variable", "A3M_POLL_INTERVAL"),
        ("default_value", "5"),
        ("user_viewable", True),
        ("user_editable", False),
        ("rules", ["required", "integer", "between:1,120"]),
    ]),
    OrderedDict([
        ("name", "[A3M] Disable Progress Reporting"),
        ("description",
         "Stops the container writing .arma3-manager/status.json entirely. The server "
         "and its mods behave exactly as the stock Arma 3 egg; the panel's Mods page "
         "falls back to reading directory listings, which can show whether a mod is "
         "present but not a percentage, a name or a reason for a failure.\n\n"
         "Only useful for isolating whether a problem comes from this fork. "
         "(1 Disable | 0 Enable)"),
        ("env_variable", "A3M_DISABLE"),
        ("default_value", "0"),
        ("user_viewable", True),
        ("user_editable", False),
        ("rules", ["required", "boolean"]),
    ]),
]


# Prepended to upstream's install script.
#
# Wings' `reinstall` is the one API that starts a container on a stopped
# server's volume: it waits for the server to be offline, mounts the volume at
# /mnt/server, and runs this script. Wings' own comment on the function is the
# guarantee this relies on — "This does not touch any existing files for the
# server, other than what the script modifies."
#
# So a reinstall whose script only downloads mods *is* the dummy container, and
# it is how mods are fetched while the server is down without asking the
# customer to set A3M_SYNC_ONLY and remember to unset it.
#
# The real work is done by a3m-sync.sh, fetched rather than reimplemented. The
# installer image is not ours — it is upstream's Debian image, running as root,
# which our game image is not — so the scripts cannot simply be baked in. This
# egg already curls server.cfg and basic.cfg from GitHub during install, so a
# fetch here is the established pattern rather than a new dependency.
#
# Reimplementing the download loop inline was the alternative and is the wrong
# one: the panel reads status.json, and a second implementation of it would
# drift from the daemon's while continuing to parse.
A3M_INSTALL_PREFIX = '''#!/bin/bash

## A3M === MODS-ONLY FAST PATH ===
##
## Runs when the panel has left a download request on the volume and the game is
## already installed. Fetches only the requested Workshop mods and exits, instead
## of re-validating twenty-odd gigabytes of game files nobody asked about.
##
## Falls through to the full install below whenever it cannot do that safely.

A3M_REQUEST_FILE="/mnt/server/.arma3-manager/request.json"
A3M_SCRIPT_REF="${A3M_SCRIPT_REF:-main}"
A3M_SCRIPT_BASE="https://raw.githubusercontent.com/FyWolf/arma3-manager-egg/${A3M_SCRIPT_REF}/image"

if [[ -f ${A3M_REQUEST_FILE} ]] \\
    && { [[ -f /mnt/server/arma3server_x64 ]] || [[ -f /mnt/server/arma3server ]]; } \\
    && [[ -f /mnt/server/steamcmd/steamcmd.sh ]]; then

    echo -e "\\n[A3M]: A mod download was requested and the game is already installed."
    echo -e "[A3M]: Fetching only the requested mods. The game files are not touched.\\n"

    apt -y update > /dev/null 2>&1
    apt -y --no-install-recommends install curl ca-certificates jq > /dev/null 2>&1

    cd /mnt/server || exit 0
    export HOME=/mnt/server

    if curl -sSLf -o /tmp/a3m-common.sh "${A3M_SCRIPT_BASE}/a3m-common.sh" \\
        && curl -sSLf -o /tmp/a3m-sync.sh "${A3M_SCRIPT_BASE}/a3m-sync.sh"; then

        chmod +x /tmp/a3m-sync.sh
        A3M_COMMON=/tmp/a3m-common.sh bash /tmp/a3m-sync.sh once

        echo -e "\\n[A3M]: Mod download finished. The server can be started.\\n"

        # Exit 0 even if individual mods failed. A non-zero exit here marks the
        # whole server as install-failed in the panel, which is a far worse
        # state than one mod missing — and the per-mod reasons are already in
        # status.json, where the Mods page shows them on the row that failed.
        exit 0
    fi

    # The request is deliberately left in place. The sync daemon picks it up the
    # next time the server starts, so the mods still arrive; they arrive later.
    # Exiting non-zero here would flag the server as broken over a failed
    # download of two shell scripts.
    echo -e "\\n[A3M]: Could not fetch the sync scripts from GitHub."
    echo -e "[A3M]: The request has been left queued and will run at the next server start.\\n"
    exit 0
fi

## A3M === END FAST PATH — upstream's install script follows, unmodified ===

'''


def main() -> int:
    with open(UPSTREAM, encoding="utf-8") as handle:
        egg = json.load(handle, object_pairs_hook=OrderedDict)

    egg["_comment"] = (
        "DERIVED FILE - do not edit by hand. Generated by build-egg.py from the "
        "upstream pelican-eggs Arma 3 egg. Upstream keeps its own copyright and "
        "its install script, config parsers and variables are unmodified. "
        "See NOTICE.md. " + REPO
    )

    egg["name"] = "Arma 3 (Manager)"
    egg["author"] = "alanpoux@gmail.com"
    egg["description"] = (
        "Arma 3 dedicated server with machine-readable mod download progress, for use "
        "with the Arma 3 Manager panel plugin. Downloads mods exactly as the stock egg "
        "does, and additionally reports per-mod state, percentage and failure reasons "
        "to .arma3-manager/status.json, and can sync mods without starting the game."
    )

    # A distinct uuid: same uuid as upstream would make this an *update* to the
    # stock egg on import, silently repointing every existing Arma 3 server at
    # this image.
    # Hex only — "a3m…" reads nicely and is not a UUID, which the panel rejects
    # on import with a validation error rather than anything about eggs.
    egg["uuid"] = "a3f0e991-4c2b-4f7a-9d18-0b6a1f3c5d20"

    egg["docker_images"] = OrderedDict([("Arma 3 Manager", IMAGE)])

    egg["meta"] = OrderedDict([
        ("version", "PLCN_v1"),
        ("update_url",
         "https://raw.githubusercontent.com/FyWolf/arma3-manager-egg/refs/heads/main/"
         + OUTPUT),
    ])

    tags = list(egg.get("tags") or [])
    for tag in ("arma", "arma3", "arma3-manager"):
        if tag not in tags:
            tags.append(tag)
    egg["tags"] = tags

    # Prepend the mods-only fast path to upstream's install script.
    #
    # Upstream's script keeps its own shebang, which becomes a harmless comment
    # once it is no longer on the first line; stripping it would make the diff
    # against upstream larger than the change actually is.
    script = egg["scripts"]["installation"]["script"]

    if "A3M === MODS-ONLY FAST PATH" in script:
        raise SystemExit("Upstream script already carries the fast path — reconcile before regenerating.")

    egg["scripts"]["installation"]["script"] = A3M_INSTALL_PREFIX + script

    existing = {v.get("env_variable") for v in egg.get("variables", [])}
    highest = max((v.get("sort") or 0) for v in egg.get("variables", [])) if egg.get("variables") else 0

    for offset, variable in enumerate(ADDED, start=1):
        if variable["env_variable"] in existing:
            raise SystemExit(
                "Upstream now declares %s itself — reconcile before regenerating."
                % variable["env_variable"]
            )
        added = OrderedDict(variable)
        added["sort"] = highest + offset
        egg["variables"].append(added)

    with open(OUTPUT, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(egg, handle, indent=4, ensure_ascii=False)
        handle.write("\n")

    print("Wrote %s" % OUTPUT)
    print("  image     %s" % IMAGE)
    print("  variables %d (%d added)" % (len(egg["variables"]), len(ADDED)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
