#!/bin/bash

# Arma 3 Manager — shared progress reporting
#
# Copyright (C) 2026  FyWolf
# AGPL-3.0-or-later, as the entrypoint this was lifted out of. See NOTICE.md.
#
# Sourced by both `entrypoint.sh` and `a3m-sync.sh`, which is the entire reason
# it is a separate file: the background sync daemon reports through exactly the
# same status.json as a boot-time download, so the panel cannot tell — and does
# not need to care — which of the two fetched a mod.
#
# Two copies of these functions would drift, and the drift would be invisible:
# the daemon would go on writing a status file the panel still parsed, with
# subtly different states in it.
#
# Callers may set STEAMCMD_DIR, WORKSHOP_DIR and GAME_ID before sourcing. The
# defaults below match the stock Arma 3 image.

: "${STEAMCMD_DIR:=./steamcmd}"
: "${WORKSHOP_DIR:=./Steam/steamapps/workshop}"
: "${GAME_ID:=107410}"

# Read by A3M_Enabled and A3M_Render. Defaulted because an egg need not declare
# them, and an absent variable would abort a caller running under `set -u`.
: "${A3M_DISABLE:=}"
: "${A3M_SYNC_ONLY:=}"

## A3M === ARMA 3 MANAGER CONSTANTS ===
A3M_DIR="./.arma3-manager"                      # Everything this fork writes lives here and nowhere else
A3M_STATUS="${A3M_DIR}/status.json"             # Machine-readable progress, polled by the panel
A3M_MODS="${A3M_DIR}/mods"                      # One <id>.state file per mod; the monitor renders from these
A3M_WANTED="${A3M_DIR}/wanted.json"             # Optional, written by the panel: mod names and expected sizes
A3M_POLL="${A3M_POLL_INTERVAL:-5}"              # Seconds between progress rewrites
A3M_MONITOR_PID=""                              # Set when the background monitor starts

## A3M === ARMA 3 MANAGER PROGRESS REPORTING ===
#
# Why this exists at all: the panel cannot see inside this container. Upstream's
# only progress signal is human-readable console text, so a panel is left to
# infer state from directory listings — which cannot tell "queued" from "failed",
# cannot name a mod, and cannot show a percentage. These functions write the same
# facts as JSON, next to the files they describe.
#
# The design constraint is that a crashed or killed container must not leave a
# status file claiming a download is still running. Every state change is written
# through immediately, and the phase is set to a terminal value on the way out.
#
# State lives in one small file per mod rather than a shell array, because the
# renderer runs as a **background subshell** and cannot see the main shell's
# variables. One writer per file, so there is no locking to get wrong.

# True when the tracking directory is usable. Everything else is a no-op if not,
# so a read-only or full volume degrades to upstream behaviour rather than
# failing the boot.
function A3M_Enabled { #[No input; returns 0 when tracking is on]
    [[ ${A3M_DISABLE} != "1" ]] && [[ -d ${A3M_DIR} ]]
}

# Read one field for one mod out of the panel-written wanted.json.
# Absent file, absent mod or absent field all yield an empty string, which the
# renderer turns into null — the panel simply shows no size and no name.
function A3M_Wanted { #[Input: string id; string field]
    [[ -f ${A3M_WANTED} ]] || return 0
    jq -r --arg id "$1" --arg field "$2" \
        '(.mods[$id][$field] // "") | tostring' "${A3M_WANTED}" 2>/dev/null
}

# A mod's display name, preferring what the panel resolved from the Steam API.
#
# Two sources, in that order, because they fail in opposite conditions: the panel
# has the API but writes wanted.json before the container starts, so it misses a
# mod added by hand to MODIFICATIONS; the entrypoint scrapes the name off the
# Workshop page but only for a mod it actually downloads this run. Either alone
# leaves rows reading as a bare id.
function A3M_Name { #[Input: string id]
    local name

    name="$(A3M_Wanted "$1" name)"
    if [[ -z $name ]]; then
        name="$(cat "${A3M_MODS}/$1.name" 2>/dev/null)"
    fi

    printf '%s' "${name}"
}

# Record a mod's state. `waiting`, `downloading`, `done` or `failed`.
# The optional third argument is a human-readable reason, kept only for `failed`.
function A3M_SetState { #[Input: string id; string state; string error(optional)]
    A3M_Enabled || return 0
    mkdir -p "${A3M_MODS}"
    echo "$2" > "${A3M_MODS}/$1.state"
    # `${3:-}` rather than `$3`: the third argument is genuinely optional and an
    # unset positional is a hard error under `set -u`. Upstream does not set it,
    # but a caller that does should not be able to abort a boot from here.
    if [[ -n ${3:-} ]]; then
        echo "$3" > "${A3M_MODS}/$1.err"
    else
        rm -f "${A3M_MODS}/$1.err"
    fi
    A3M_Render
}

# Record the overall phase, so the panel can distinguish "not started yet" from
# "finished with nothing to do".
function A3M_Phase { #[Input: string phase]
    A3M_Enabled || return 0
    echo "$1" > "${A3M_DIR}/phase"
    A3M_Render
}

# Rewrite status.json from the state files plus what is on disk right now.
#
# Written to a temp file and moved into place, because the panel polls this and a
# half-written file must never be readable — `mv` within one filesystem is atomic.
function A3M_Render { #[No input]
    A3M_Enabled || return 0

    local phase modId state err want have

    phase="$(cat "${A3M_DIR}/phase" 2>/dev/null)"
    [[ -z $phase ]] && phase="idle"

    {
        for stateFile in "${A3M_MODS}"/*.state; do
            [[ -e $stateFile ]] || continue

            modId="$(basename "${stateFile}" .state)"
            state="$(cat "${stateFile}" 2>/dev/null)"
            err="$(cat "${A3M_MODS}/${modId}.err" 2>/dev/null)"
            want="$(A3M_Wanted "${modId}" bytes)"
            [[ $want =~ ^[0-9]+$ ]] || want=0

            # Bytes on disk. While transferring, SteamCMD stages the item under
            # `downloads/`; on success it *moves* it into `content/`. Sizing the
            # right one of those is what makes the percentage real rather than a
            # bar that animates on a timer.
            have=0
            case "${state}" in
                downloading)
                    have=$(du -sb "${WORKSHOP_DIR}/downloads/${GAME_ID}/${modId}" 2>/dev/null | cut -f1)
                    ;;
                done)
                    have=$(du -sb "${WORKSHOP_DIR}/content/${GAME_ID}/${modId}" 2>/dev/null | cut -f1)
                    # An optional mod has its source deleted to save space, and a
                    # cache clear removes it too. Both are still "done", so fall
                    # back to the expected size rather than reporting a shrink.
                    [[ -z $have || $have == 0 ]] && have=${want}
                    ;;
            esac
            [[ $have =~ ^[0-9]+$ ]] || have=0

            jq -nc \
                --arg id "${modId}" \
                --arg state "${state}" \
                --arg name "$(A3M_Name "${modId}")" \
                --arg err "${err}" \
                --argjson have "${have}" \
                --argjson want "${want}" \
                '{
                    id: $id,
                    state: $state,
                    name: (if $name == "" then null else $name end),
                    bytes: $have,
                    expected_bytes: (if $want == 0 then null else $want end),
                    percent: (if $want > 0
                        then ([(($have * 100) / $want) | floor, 100] | min)
                        else null end),
                    error: (if $err == "" then null else $err end)
                }'
        done
    } | jq -s \
        --arg phase "${phase}" \
        --argjson ts "$(date +%s)" \
        --argjson syncOnly "$( [[ ${A3M_SYNC_ONLY} == "1" ]] && echo true || echo false )" \
        '{
            version: 1,
            updated_at: $ts,
            phase: $phase,
            sync_only: $syncOnly,
            totals: {
                total: length,
                done: (map(select(.state == "done")) | length),
                downloading: (map(select(.state == "downloading")) | length),
                waiting: (map(select(.state == "waiting")) | length),
                failed: (map(select(.state == "failed")) | length)
            },
            mods: .
        }' > "${A3M_STATUS}.tmp" 2>/dev/null \
        && mv -f "${A3M_STATUS}.tmp" "${A3M_STATUS}"
}

# Seed every mod in the load order as `waiting`, so the panel shows the whole
# list from the first poll instead of it materialising one row at a time.
function A3M_Init { #[Input: string mods (space separated, @ prefixed or bare)]
    [[ ${A3M_DISABLE} == "1" ]] && return 0

    # Clear the previous run's per-mod states, which would otherwise be reported
    # as this run's progress. Only the states: `wanted.json` is written by the
    # panel *before* the container starts, so wiping the whole directory here
    # would delete the sizes and names this run is about to report with.
    rm -rf "${A3M_MODS:?}"
    rm -f "${A3M_STATUS}" "${A3M_DIR}/monitor"
    mkdir -p "${A3M_MODS}" || return 0

    # Both separators are accepted. Upstream converts `;` to spaces before this
    # is reached, but the semicolon form is what every egg variable, every
    # launcher preset and every hand-typed mod list uses — so a caller passing
    # the unconverted string would otherwise seed *nothing*, silently, and the
    # panel would show an empty mod list while the download ran perfectly.
    # `tr -d '\r'`: a carriage return from a Windows-pasted egg variable makes
    # every id fail `^[0-9]+$`, so nothing is seeded and the panel shows an empty
    # mod list while the download runs perfectly. A CR prints as nothing, so
    # there is no way to see it in a log.
    for modId in $(echo "$1" | tr -d '\r' | tr ';' ' ' | sed -e 's/@//g'); do
        if [[ $modId =~ ^[0-9]+$ ]]; then
            echo "waiting" > "${A3M_MODS}/${modId}.state"
        fi
    done

    A3M_Phase "starting"
}

# Rewrite status.json on a timer while SteamCMD works, so a single large mod
# shows a moving percentage rather than sitting still until it completes.
function A3M_MonitorStart { #[No input]
    A3M_Enabled || return 0

    while true; do
        sleep "${A3M_POLL}"
        # Stop if the main script has finished with us.
        [[ -f "${A3M_DIR}/monitor" ]] || break
        A3M_Render
    done &

    A3M_MONITOR_PID=$!
    touch "${A3M_DIR}/monitor"
}

function A3M_MonitorStop { #[No input]
    rm -f "${A3M_DIR}/monitor"
    if [[ -n ${A3M_MONITOR_PID} ]]; then
        kill "${A3M_MONITOR_PID}" 2>/dev/null
        wait "${A3M_MONITOR_PID}" 2>/dev/null
    fi
    A3M_MONITOR_PID=""
}
