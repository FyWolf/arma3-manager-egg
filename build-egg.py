#!/usr/bin/env python3
"""Generate egg-arma3-manager.json from the upstream Arma 3 egg.

The egg is *derived*, never hand-edited. Upstream owns the install script, the
config-file parsers and twenty-six variables, all of which change over time; the
only things this fork owns are the image, the identity and a handful of added
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
# All are `user_viewable` and none is `user_editable`: every one of them is a
# host-side knob, and a customer has no reason to retune a poll interval or
# switch progress reporting off. They stay visible so a support conversation can
# confirm what they are set to.
#
# There is deliberately no "download without starting" variable. Mods are fetched
# by the server's own container — at boot, or on request by the sync daemon while
# it runs — and a variable that makes the container exit instead of starting is a
# server that never comes back up if anyone forgets to unset it.
ADDED = [
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
        "to .arma3-manager/status.json, and can download mods in the background while "
        "the server is running."
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
