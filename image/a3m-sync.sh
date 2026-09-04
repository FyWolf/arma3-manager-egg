#!/bin/bash

# Arma 3 Manager — background Workshop mod downloader
#
# Copyright (C) 2026  FyWolf
# AGPL-3.0-or-later. See NOTICE.md.
#
# ## What this is for
#
# Downloading mods without restarting anything.
#
# Upstream fetches mods in the entrypoint, before the game binary launches, so
# every mod change costs a restart and every restart costs however long the
# download takes. On a 40 GB set that is the session, not an inconvenience.
#
# This runs *alongside* the game server: the panel writes a request file at any
# time, this picks it up within seconds and downloads into the SteamCMD cache
# while players carry on playing. The mods are then already on disk, so the
# restart that activates them is as fast as a restart with no mod changes at all.
#
# ## What it deliberately does not do
#
# **It does not build the `@<id>` folders.** Those are what the running server
# has open, and rebuilding one underneath a live Arma is how you corrupt a
# session — the entrypoint's own linking step does `rm -rf @<id>` first. Since
# Arma reads its mod list once at startup, a mod linked now could not be loaded
# before the next restart anyway, so there is nothing to gain and a live server
# to lose.
#
# The next boot links it, and because the files are already cached that step is
# a hard-link copy rather than a download. `MODS_LOWERCASE` is applied there too,
# for the same reason.
#
# So: this makes the *download* asynchronous. Activation is still a restart,
# because Arma gives no other option.
#
# ## Modes
#
#   daemon  watch for requests until killed. Started by the entrypoint.
#   once    process one pending request, then exit. For testing and for cron.
#
# Usage: a3m-sync.sh [daemon|once]

# Overridable so the test suite can source this against a fixture directory.
# In the image it is always /a3m-common.sh.
source "${A3M_COMMON:-/a3m-common.sh}"

# Defaults for everything that comes from the egg's environment.
#
# Not tidiness: an egg is free not to declare OPTIONALMODS, and a variable that
# is merely *absent* would abort this script under `set -u` and take background
# sync with it — for a mod list the customer never used. Defaulting is also what
# lets the tests run the real functions under `set -u`.
: "${STEAM_USER:=}"
: "${STEAM_PASS:=}"
: "${MODIFICATIONS:=}"
: "${SERVERMODS:=}"
: "${OPTIONALMODS:=}"
: "${STEAMCMD_ATTEMPTS:=3}"

A3M_DAEMON_RUNNING=0                            # 1 only inside the daemon loop
A3M_REQUEST="${A3M_DIR}/request.json"           # Written by the panel
A3M_ACTIVE="${A3M_DIR}/request.active.json"     # Claimed request, being worked
A3M_LOCK="${A3M_DIR}/sync.lock"                 # A directory: mkdir is atomic
A3M_SYNC_LOG="${A3M_DIR}/sync.log"              # SteamCMD output, kept away from the boot log
A3M_SYNC_POLL="${A3M_SYNC_POLL:-10}"            # Seconds between checks for a request
A3M_SYNC_NICE="${A3M_SYNC_NICE:-10}"            # How far to yield to the game server
A3M_LOCK_STALE="${A3M_LOCK_STALE:-7200}"        # Seconds before a lock is assumed abandoned

# Log to the container console as well as the file. The console is what the
# customer already has open, and "ACE3 downloaded" appearing there while they
# play is the clearest possible signal that a background sync is a real thing
# and not a spinner in a web page.
function SyncLog { #[Input: string message]
    local line
    line="[$(date '+%H:%M:%S')] [A3M-SYNC] $1"

    echo -e "${line}"
    echo "${line}" >> "${A3M_SYNC_LOG}" 2>/dev/null
}

# Steam credentials are the server's own, and this refuses rather than trying.
#
# An anonymous login cannot fetch Arma 3 Workshop items at all — the account has
# to own the game — so without real credentials every download would fail
# identically, three attempts at a time, forever. Saying so once is kinder than
# a log full of failures.
function CredentialsUsable { #[No input]
    [[ -n ${STEAM_USER} && ${STEAM_USER} != "anonymous" && -n ${STEAM_PASS} ]]
}

# Take the lock, or return 1 if another sync holds it.
#
# `mkdir` because it is atomic on every filesystem Wings will hand us, unlike
# test-then-create. A lock older than A3M_LOCK_STALE is assumed to belong to a
# container that was killed mid-download and is broken open — otherwise one
# `docker kill` at the wrong moment disables background sync permanently, which
# is the same shape of bug as the mod-set install reaper in the panel.
function Lock { #[No input]
    if mkdir "${A3M_LOCK}" 2>/dev/null; then
        return 0
    fi

    local age
    age=$(( $(date +%s) - $(stat -c %Y "${A3M_LOCK}" 2>/dev/null || date +%s) ))

    if (( age > A3M_LOCK_STALE )); then
        SyncLog "Clearing a stale sync lock (${age}s old)."
        rmdir "${A3M_LOCK}" 2>/dev/null
        mkdir "${A3M_LOCK}" 2>/dev/null && return 0
    fi

    return 1
}

function Unlock { #[No input]
    rmdir "${A3M_LOCK}" 2>/dev/null
}

# Whether this item is already in the SteamCMD cache.
function Cached { #[Input: string id]
    [[ -d "${WORKSHOP_DIR}/content/${GAME_ID}/$1" ]]
}

# Fetch one Workshop item. Returns 0 on success.
#
# `nice` because this runs next to a live game server, and Arma is latency
# sensitive in a way that a download is not. A background sync that costs the
# players their tickrate is not a background sync.
function DownloadOne { #[Input: string id]
    local id="$1"
    local attempt=0
    local attempts="${STEAMCMD_ATTEMPTS:-3}"

    while (( attempt < attempts )); do
        attempt=$(( attempt + 1 ))

        if (( attempt > 1 )); then
            SyncLog "Retrying ${id} (attempt ${attempt} of ${attempts})..."
            sleep 3
        fi

        nice -n "${A3M_SYNC_NICE}" "${STEAMCMD_DIR}/steamcmd.sh" \
            "+login \"${STEAM_USER}\" \"${STEAM_PASS}\"" \
            +workshop_download_item "${GAME_ID}" "${id}" \
            +quit >> "${A3M_SYNC_LOG}" 2>&1

        # The directory is the fact, not the exit code: SteamCMD exits 0 on
        # plenty of things that fetched nothing.
        if Cached "${id}"; then
            return 0
        fi
    done

    return 1
}

# Ids to sync: whatever the request names, or the load order this container
# booted with.
#
# The env fallback is deliberately second. MODIFICATIONS is read once, at
# container start, so it is stale the moment the panel edits the load order —
# and a background sync that fetched a stale list would quietly download the
# wrong mods. The panel therefore always names them explicitly.
function RequestedIds { #[Input: string requestFile]
    local ids=""

    # `tr -d '\r'` is load bearing. A carriage return survives every split below
    # and turns `450814997` into `450814997\r`, which fails `^[0-9]+$` and is
    # dropped — invisibly, because a CR in a log just moves the cursor rather
    # than printing. Two real sources: an egg variable pasted from Windows, and
    # jq itself, which emits CRLF when run on a Windows host.
    if [[ -f $1 ]]; then
        ids=$(jq -r '(.mods // [])[] | tostring' "$1" 2>/dev/null | tr -d '\r' | tr '\n' ' ')
    fi

    if [[ -z ${ids// /} ]]; then
        ids=$(echo "${MODIFICATIONS};${SERVERMODS};${OPTIONALMODS}" | tr -d '\r' | tr ';' ' ' | sed -e 's/@//g')
    fi

    echo "${ids}"
}

# Work one request through.
function ProcessRequest { #[No input]
    if ! Lock; then
        SyncLog "Another sync is already running; leaving this request queued."

        return 0
    fi

    # Claim it by renaming, so the panel can write a *new* request while this one
    # runs without the two being confused for each other.
    mv -f "${A3M_REQUEST}" "${A3M_ACTIVE}" 2>/dev/null

    local ids
    ids=$(RequestedIds "${A3M_ACTIVE}")

    local wanted=()

    for id in ${ids}; do
        [[ $id =~ ^[0-9]+$ ]] && wanted+=("${id}")
    done

    if (( ${#wanted[@]} == 0 )); then
        SyncLog "Request named no Workshop mods; nothing to do."
        rm -f "${A3M_ACTIVE}"
        Unlock

        return 0
    fi

    if ! CredentialsUsable; then
        SyncLog "No usable Steam account on this server, so nothing can be downloaded."
        SyncLog "Arma 3 Workshop items need an account that owns the game; 'anonymous' cannot fetch them."

        for id in "${wanted[@]}"; do
            A3M_SetState "${id}" "failed" "This server has no Steam account that owns Arma 3, so the Workshop cannot be reached. Its STEAM_USER and STEAM_PASS variables need setting."
        done

        rm -f "${A3M_ACTIVE}"
        Unlock

        return 0
    fi

    SyncLog "Starting background sync of ${#wanted[@]} mod(s)."

    A3M_Phase "syncing"

    # Seed first so the panel's next poll shows the whole job rather than
    # discovering it one mod at a time.
    for id in "${wanted[@]}"; do
        if Cached "${id}"; then
            A3M_SetState "${id}" "done"
        else
            A3M_SetState "${id}" "waiting"
        fi
    done

    A3M_MonitorStart

    local failed=0

    for id in "${wanted[@]}"; do
        if Cached "${id}"; then
            continue
        fi

        A3M_SetState "${id}" "downloading"
        SyncLog "Downloading $(A3M_Name "${id}" || true) (${id})..."

        if DownloadOne "${id}"; then
            A3M_SetState "${id}" "done"
            SyncLog "Finished ${id}."
        else
            failed=$(( failed + 1 ))
            A3M_SetState "${id}" "failed" "SteamCMD could not fetch this mod in ${STEAMCMD_ATTEMPTS:-3} attempts. See .arma3-manager/sync.log. A timeout on a very large mod is the usual cause and retrying often works."
            SyncLog "FAILED ${id} — see ${A3M_SYNC_LOG}."
        fi
    done

    A3M_MonitorStop

    rm -f "${A3M_ACTIVE}"
    Unlock

    if (( failed > 0 )); then
        SyncLog "Background sync finished with ${failed} failure(s)."
        A3M_Phase "synced_with_errors"
    else
        SyncLog "Background sync complete. Restart the server when convenient to load the new mods."
        A3M_Phase "synced"
    fi

    # Hand the phase back to whatever the container is actually doing. The
    # daemon only ever runs alongside a started server, so leaving it on
    # "synced" would tell the panel the server was down.
    if [[ ${A3M_DAEMON_RUNNING:-0} == "1" ]]; then
        sleep 2
        A3M_Phase "running"
    fi
}

function Daemon { #[No input]
    A3M_DAEMON_RUNNING=1

    SyncLog "Background mod sync is watching for requests (every ${A3M_SYNC_POLL}s)."

    # A request left behind by a container that died mid-sync is picked up here
    # rather than sitting forever: the panel already told us to fetch it.
    if [[ -f ${A3M_ACTIVE} && ! -f ${A3M_REQUEST} ]]; then
        SyncLog "Resuming a sync that was interrupted."
        mv -f "${A3M_ACTIVE}" "${A3M_REQUEST}" 2>/dev/null
    fi

    while true; do
        if [[ -f ${A3M_REQUEST} ]]; then
            ProcessRequest
        fi

        sleep "${A3M_SYNC_POLL}"
    done
}

# Sourced by the tests, which want the functions without the daemon loop.
if [[ ${A3M_SYNC_LIB_ONLY:-0} == "1" ]]; then
    return 0
fi

trap 'Unlock' EXIT INT TERM

mkdir -p "${A3M_DIR}" 2>/dev/null

case "${1:-daemon}" in
    daemon)
        Daemon
        ;;
    once)
        if [[ -f ${A3M_REQUEST} || -f ${A3M_ACTIVE} ]]; then
            [[ -f ${A3M_REQUEST} ]] || mv -f "${A3M_ACTIVE}" "${A3M_REQUEST}" 2>/dev/null
            ProcessRequest
        else
            SyncLog "No pending request."
        fi
        ;;
    *)
        echo "Usage: $0 [daemon|once]" >&2
        exit 2
        ;;
esac
