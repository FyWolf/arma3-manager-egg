#!/bin/bash

# Arma 3 Yolk Entrypoint - entrypoint.sh
# Date: 2025/10/15
# Copyright (C) 2025  David Wolfe (Red-Thirten) and contributors
# Contributors: Aussie Server Hosts (https://aussieserverhosts.com/), Stephen White (SilK)
#
# MODIFIED VERSION — see NOTICE.md in this repository for the full list of changes.
# Copyright (C) 2026  FyWolf
#
# This is a fork of the upstream Arma 3 yolk entrypoint, carrying two additions
# for the Arma 3 Manager panel plugin, both marked in-file with `A3M`:
#
#   1. It writes machine-readable download progress to .arma3-manager/status.json
#      so the panel can report per-mod state instead of guessing from directory
#      listings.
#   2. A3M_SYNC_ONLY downloads and updates mods, then exits without starting the
#      game server.
#
# Everything else is upstream and is deliberately left alone, so that pulling a
# newer upstream entrypoint stays a readable diff. AGPL-3.0-or-later, as upstream.
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published
# by the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
# 
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

## === CONSTANTS ===
STEAMCMD_DIR="./steamcmd"                       # SteamCMD's directory containing steamcmd.sh
WORKSHOP_DIR="./Steam/steamapps/workshop"       # SteamCMD's directory containing workshop downloads
STEAMCMD_LOG="${STEAMCMD_DIR}/steamcmd.log"     # Log file for SteamCMD
GAME_ID=107410                                  # SteamCMD ID for the Arma 3 GAME (not server). Only used for Workshop mod downloads.
SERVER_PARAM_FILE="startup_params_server.txt"   # File name for the auto-generated server par file to be used during startup
HC_PARAM_FILE="startup_params_hc.txt"           # File name for the auto-generated Headless Client par file to be used during startup
EGG_URL='https://github.com/pelican-eggs/games-steamcmd/tree/main/arma/arma3'   # URL for Egg & README (only used as info to legacy users)

## A3M === ARMA 3 MANAGER CONSTANTS ===
A3M_DIR="./.arma3-manager"                      # Everything this fork writes lives here and nowhere else
A3M_STATUS="${A3M_DIR}/status.json"             # Machine-readable progress, polled by the panel
A3M_MODS="${A3M_DIR}/mods"                      # One <id>.state file per mod; the monitor renders from these
A3M_WANTED="${A3M_DIR}/wanted.json"             # Optional, written by the panel: mod names and expected sizes
A3M_POLL="${A3M_POLL_INTERVAL:-5}"              # Seconds between progress rewrites
A3M_MONITOR_PID=""                              # Set when the background monitor starts

# Color Codes
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

## === ENVIRONMENT VARS ===
# HOME, STARTUP, STEAM_USER, STEAM_PASS, SERVER_BINARY, MOD_FILE, MODIFICATIONS, SERVERMODS, OPTIONALMODS, UPDATE_SERVER, VALIDATE_SERVER,
# MODS_LOWERCASE, STEAMCMD_APPID, STEAMCMD_BETAID, HC_NUM, SERVER_PASSWORD, HC_HIDE, STEAMCMD_ATTEMPTS, BASIC_CFG_URL,
# PARAM_NOLOGS, PARAM_AUTOINIT, PARAM_FILEPATCHING, PARAM_LOADMISSIONTOMEMORY, PARAM_LIMITFPS

## === GLOBAL VARS ===
# updateAttempt, modifiedStartup, allMods, clientMods

## === DEFINE FUNCTIONS ===

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
    for modId in $(echo "$1" | tr ';' ' ' | sed -e 's/@//g'); do
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

# Runs SteamCMD with specified variables and performs error handling.
function RunSteamCMD { #[Input: int server=0 mod=1 optional_mod=2; int id]
    # Clear previous SteamCMD log
    if [[ -f "${STEAMCMD_LOG}" ]]; then
        rm -f "${STEAMCMD_LOG:?}"
    fi

    updateAttempt=0
    # Loop for specified number of attempts
    while (( $updateAttempt < $STEAMCMD_ATTEMPTS )); do
        # Increment attempt counter
        updateAttempt=$((updateAttempt+1))

        # Notify if not first attempt
        if (( $updateAttempt > 1 )); then
            echo -e "\t${YELLOW}Re-Attempting download/update in 3 seconds...${NC} (Attempt ${CYAN}${updateAttempt}${NC} of ${CYAN}${STEAMCMD_ATTEMPTS}${NC})\n"
            sleep 3
        fi

        # Check if updating server or mod
        if [[ $1 == 0 ]]; then # Server
            ${STEAMCMD_DIR}/steamcmd.sh +force_install_dir ${HOME} "+login \"${STEAM_USER}\" \"${STEAM_PASS}\"" +app_update $2 $( [[ -n ${STEAMCMD_BETAID} ]] && printf %s "-beta ${STEAMCMD_BETAID}" ) $( [[ ${VALIDATE_SERVER} == 1 ]] && printf %s "validate" ) +quit | tee -a "${STEAMCMD_LOG}"
        else # Mod
            ${STEAMCMD_DIR}/steamcmd.sh "+login \"${STEAM_USER}\" \"${STEAM_PASS}\"" +workshop_download_item ${GAME_ID} $2 +quit | tee -a "${STEAMCMD_LOG}"
        fi

        # Error checking for SteamCMD
        steamcmdExitCode=${PIPESTATUS[0]}
        loggedErrors=$(grep -i "error\|failed" "${STEAMCMD_LOG}" | grep -iv "setlocal\|SDL\|steamservice\|thread priority\|libcurl")
        if [[ -n ${loggedErrors} ]]; then # Catch errors (ignore setlocale, SDL, steamservice, thread priority, and libcurl warnings)
            # Soft errors
            if [[ -n $(grep -i "Timeout downloading item" "${STEAMCMD_LOG}") ]]; then # Mod download timeout
                echo -e "\n${YELLOW}[UPDATE]: ${NC}Timeout downloading Steam Workshop mod: \"${CYAN}${modName}${NC}\" (${CYAN}${2}${NC})"
                echo -e "\t(This is expected for particularly large mods)"
            elif [[ -n $(grep -i "0x402\|0x6\|0x602" "${STEAMCMD_LOG}") ]]; then # Connection issue with Steam
                echo -e "\n${YELLOW}[UPDATE]: ${NC}Connection issue with Steam servers."
                echo -e "\t(Steam servers may currently be down, or a connection cannot be made reliably)"
            # Hard errors
            elif [[ -n $(grep -i "Password check for AppId" "${STEAMCMD_LOG}") ]]; then # Incorrect beta branch password
                echo -e "\n${RED}[UPDATE]: ${YELLOW}Incorrect password given for beta branch \"${STEAMCMD_BETAID}\". ${CYAN}Skipping download...${NC}"
                echo -e "\t(Please contact the maintainer of this image; an update may be required)"
                break
            # Fatal errors
            elif [[ -n $(grep -i "Invalid Password\|two-factor\|No subscription" "${STEAMCMD_LOG}") ]]; then # Wrong username/password, Steam Guard is turned on, or host is using anonymous account
                echo -e "\n${RED}[UPDATE]: Cannot login to Steam - Improperly configured account and/or credentials${NC}"
                echo -e "\t${YELLOW}Please contact your administrator/host and give them the following message:${NC}"
                echo -e "\t${CYAN}Your Egg, or your client's server, is not configured with valid Steam credentials.${NC}"
                echo -e "\t${CYAN}Either the username/password is wrong, or Steam Guard is not fully disabled${NC}"
                echo -e "\t${CYAN}in accordance to this Egg's documentation/README.${NC}\n"
                exit 1
            elif [[ -n $(grep -i "Download item" "${STEAMCMD_LOG}") ]]; then # Steam account does not own base game for mod downloads, account rate-limit, or unknown
                echo -e "\n${RED}[UPDATE]: Cannot download mod - Download failed${NC}"
                echo -e "\t${YELLOW}While unknown, this error is likely due to your host's Steam account not owning the base game,${NC}"
                echo -e "\t${YELLOW}or the account is being rate-limited by Steam.${NC}"
                echo -e "\t${YELLOW}(Please contact your administrator/host if this issue persists)${NC}\n"
                exit 1
            elif [[ -n $(grep -i "0x202\|0x212" "${STEAMCMD_LOG}") ]]; then # Not enough disk space
                echo -e "\n${RED}[UPDATE]: Unable to complete download - Not enough storage${NC}"
                echo -e "\t${YELLOW}You have run out of your allotted disk space.${NC}"
                echo -e "\t${YELLOW}Please contact your administrator/host for potential storage upgrades.${NC}\n"
                exit 1
            elif [[ -n $(grep -i "0x606" "${STEAMCMD_LOG}") ]]; then # Disk write failure
                echo -e "\n${RED}[UPDATE]: Unable to complete download - Disk write failure${NC}"
                echo -e "\t${YELLOW}This is normally caused by directory permissions issues,${NC}"
                echo -e "\t${YELLOW}but could be a more serious hardware issue.${NC}"
                echo -e "\t${YELLOW}(Please contact your administrator/host if this issue persists)${NC}\n"
                exit 1
            else # Unknown caught error
                echo -e "\n${RED}[UPDATE]: ${YELLOW}An unknown error has occurred with SteamCMD. ${CYAN}Skipping download...${NC}"
                echo -e "SteamCMD Errors:\n${loggedErrors}"
                echo -e "\t${YELLOW}(Please contact your administrator/host if this issue persists)${NC}\n"
                break
            fi
        elif [[ $steamcmdExitCode != 0 ]]; then # Unknown fatal error
            echo -e "\n${RED}[UPDATE]: SteamCMD has crashed for an unknown reason!${NC} (Exit code: ${CYAN}${steamcmdExitCode}${NC})"
            echo -e "\t${YELLOW}(Please contact your administrator/host for support)${NC}\n"
            cp -r /tmp/dumps ./dumps
            exit $steamcmdExitCode
        else # Success!
            if [[ $1 == 0 ]]; then # Server
                echo -e "\n${GREEN}[UPDATE]: Game server is up to date!${NC}"
            else # Mod
                echo -e "\n\tMoving any mod ${CYAN}.bikey${NC} files to the ${CYAN}keys/${NC} folder..."
                if [[ $1 == 1 ]]; then # Regular mod
                    # Move any .bikey's to the keys directory
                    find "${WORKSHOP_DIR}/content/${GAME_ID}/$2" -name "*.bikey" -type f -exec cp -t "keys" {} +
                    # Make a fresh hard link copy of the downloaded mod to the current directory
                    echo -e "\tMaking ${CYAN}hard link${NC} copy of mod to: ${CYAN}$(pwd)/@$2${NC}"
                    rm -rf @$2
                    mkdir @$2
                    cp -al ${WORKSHOP_DIR}/content/${GAME_ID}/$2/* @$2/
                    # Make the hard link copy's contents all lowercase
                    # (This complies with Arma's mod-folder rules while not disturbing the mod's SteamCMD source files)
                    ModsLowercase @$2
                elif [[ $1 == 2 ]]; then # Optional mod
                    # Give optional mod keys a custom name during move which can be checked later for deleting un-configured mods
                    for file in $(find "${WORKSHOP_DIR}/content/${GAME_ID}/$2" -name "*.bikey" -type f); do
                        filename=$(basename ${file})
                        cp $file keys/optional_$2_${filename}
                    done;
                    # Delete mod folder to save space
                    echo -e "\tMod is an ${CYAN}optional mod${NC}. Deleting mod files to save space..."
                    rm -r ${WORKSHOP_DIR}/content/${GAME_ID}/$2
                    # Create a directory so time-based detection of auto updates works correctly
                    mkdir -p "@${2}_optional" && touch "@${2}_optional"
                    touch "@${2}_optional/DON'T DELETE THIS DIRECTORY - USED FOR AUTO UPDATES"
                fi
                echo -e "${GREEN}[UPDATE]: Mod download/update successful!${NC}"
            fi
            break
        fi
        if (( $updateAttempt == $STEAMCMD_ATTEMPTS )); then # Notify if failed last attempt
            if [[ $1 == 0 ]]; then # Server
                echo -e "\t${RED}Final attempt made! ${YELLOW}Unable to complete game server update. ${CYAN}Skipping...${NC}"
                echo -e "\t(Please try again at a later time)"
                sleep 3
            else # Mod
                echo -e "\t${RED}Final attempt made! ${YELLOW}Unable to complete mod download/update. ${CYAN}Skipping...${NC}"
                echo -e "\t(You may try again later, or manually upload this mod to your server via SFTP)"
                sleep 3
            fi
        fi
    done
}

# Takes a directory (string) as input, and recursively makes all files & folders lowercase.
function ModsLowercase {
    echo -e "\tMaking mod ${CYAN}$1${NC} files/folders ${CYAN}lowercase${NC}..."
    for SRC in `find ./$1 -depth`; do
        DST=`dirname "${SRC}"`/`basename "${SRC}" | tr '[A-Z]' '[a-z]'`
        if [ "${SRC}" != "${DST}" ]
        then
            [ ! -e "${DST}" ] && mv -T "${SRC}" "${DST}"
        fi
    done
}

# Removes duplicate items from a semicolon delimited string
function RemoveDuplicates { #[Input: str - Output: printf of new str]
    if [[ -n $1 ]]; then # If nothing to compare, skip to prevent extra semicolon being returned
        echo $1 | sed -e 's/;/\n/g' | sort -u | xargs printf '%s;'
    fi
}

## === ENTRYPOINT START ===

# Wait for the container to fully initialize
sleep 1

# Switch to the container's working directory
cd ${HOME} || exit 1

# Check for old Eggs
if [[ -z ${PARAM_NOLOGS+x} ]]; then # PARAM_NOLOGS was not in the previous version
    echo -e "\n${RED}[STARTUP_ERR]: Please contact your administrator/host for support, and give them the following message:${NC}\n"
    echo -e "\t${CYAN}Your Arma 3 Egg is outdated and no longer supported.${NC}"
    echo -e "\t${CYAN}Please download the latest version at the following link, and install it in your panel:${NC}"
    echo -e "\t${CYAN}${EGG_URL}${NC}\n"
    exit 1
fi

# Collect and parse all specified mods
if [[ -n ${MODIFICATIONS} ]] && [[ ${MODIFICATIONS} != *\; ]]; then # Add manually specified mods to the client-side mods list, while checking for trailing semicolon
    clientMods="${MODIFICATIONS};"
else
    clientMods=${MODIFICATIONS}
fi
if [[ -f ${MOD_FILE} ]] && [[ -n "$(cat ${MOD_FILE} | grep 'Created by Arma 3 Launcher')" ]]; then # If the mod list file exists and is valid, parse and add mods to the client-side mods list
    clientMods+=$(cat ${MOD_FILE} | grep 'id=' | cut -d'=' -f3 | cut -d'"' -f1 | xargs printf '@%s;')
elif [[ -n "${MOD_FILE}" ]]; then # If MOD_FILE is not null, warn user file is missing or invalid
    echo -e "\n${YELLOW}[STARTUP_WARN]: Arma 3 Modlist file \"${CYAN}${MOD_FILE}${YELLOW}\" could not be found, or is invalid!${NC}"
    echo -e "\tEnsure your uploaded modlist's file name matches your Startup Parameter."
    echo -e "\tOnly files exported from an Arma 3 Launcher are permitted."
    if [[ -n "${clientMods}" ]]; then
        echo -e "\t${CYAN}Reverting to the manual mod list...${NC}"
    fi
fi
if [[ -n ${SERVERMODS} ]] && [[ ${SERVERMODS} != *\; ]]; then # Add server mods to the master mods list, while checking for trailing semicolon
    allMods="${SERVERMODS};"
else
    allMods=${SERVERMODS}
fi
if [[ -n ${OPTIONALMODS} ]] && [[ ${OPTIONALMODS} != *\; ]]; then # Add specified optional mods to the mods list, while checking for trailing semicolon
    allMods+="${OPTIONALMODS};"
else
    allMods+=${OPTIONALMODS}
fi
allMods+=$clientMods # Add all client-side mods to the master mod list
clientMods=$(RemoveDuplicates ${clientMods}) # Remove duplicate mods from clientMods, if present
allMods=$(RemoveDuplicates ${allMods}) # Remove duplicate mods from allMods, if present
allMods=$(echo $allMods | sed -e 's/;/ /g') # Convert from string to array

## A3M: seed the status file with the whole load order before anything downloads,
## so the panel's first poll shows every mod rather than discovering them one at
## a time and appearing to grow the list as it goes.
A3M_Init "${allMods}"

# Update everything (server and mods), if specified
if [[ ${UPDATE_SERVER} == 1 ]]; then
    echo -e "\n${GREEN}[STARTUP]: ${CYAN}Starting checks for all updates...${NC}"
    echo -e "(It is okay to ignore any \"SDL\", \"steamservice\", and \"thread priority\" errors during this process)\n"

    ## Update game server
    echo -e "${GREEN}[UPDATE]:${NC} Checking for ${CYAN}game server${NC} updates with App ID: ${CYAN}${STEAMCMD_APPID}${NC}..."
    if [[ ${VALIDATE_SERVER} == 1 ]]; then
        echo -e "\t${CYAN}File validation enabled.${NC} (This may take extra time to complete)"
    fi
    if [[ -n ${STEAMCMD_BETAID} ]]; then
        echo -e "\tDownload/Update of ${CYAN}\"${STEAMCMD_BETAID}\" branch enabled.${NC}"
    fi
    echo -e ""

    RunSteamCMD 0 ${STEAMCMD_APPID}

    ## Update mods
    if [[ -n $allMods ]]; then
        echo -e "\n${GREEN}[UPDATE]:${NC} Checking all ${CYAN}Steam Workshop mods${NC} for updates..."

        ## A3M: from here until the mod loop ends, rewrite status.json on a timer.
        ## This is what turns a 10 GB mod from "stuck on downloading" into a
        ## moving percentage — the size of the staging directory is the only
        ## honest source for that, and only a timer can sample it.
        A3M_Phase "mods"
        A3M_MonitorStart

        for modID in $(echo $allMods | sed -e 's/@//g'); do
            if [[ $modID =~ ^[0-9]+$ ]]; then # Only check mods that are in ID-form
                # If a mod is defined in OPTIONALMODS, and is not defined in clientMods or SERVERMODS, then treat as an optional mod
                # Optional mods are given a different directory which is checked to see if a new update is available. This is to ensure
                # if an optional mod is switched to be a standard client-side mod, this script will redownload the mod
                if [[ "${OPTIONALMODS}" == *"@${modID};"* ]] && [[ "${clientMods}" != *"@${modID};"* ]] && [[ "${SERVERMODS}" != *"@${modID};"* ]]; then
                    modType=2
                    modDir=@${modID}_optional
                else
                    modType=1
                    modDir=@${modID}
                fi

                # Get mod's latest update in epoch time from its Steam Workshop changelog page
                latestUpdate=$(curl -sL https://steamcommunity.com/sharedfiles/filedetails/changelog/$modID | grep '<p id=' | head -1 | cut -d'"' -f2)

                # If the update time is valid and newer than the local directory's creation date, or the mod hasn't been downloaded yet, download the mod
                if [[ ! -d $modDir ]] || [[ ( -n $latestUpdate ) && ( $latestUpdate =~ ^[0-9]+$ ) && ( $latestUpdate > $(stat -c %Y "$modDir") ) ]]; then
                    # Get the mod's name from the Workshop page as well
                    modName=$(curl -sL https://steamcommunity.com/sharedfiles/filedetails/changelog/$modID | grep 'workshopItemTitle' | cut -d'>' -f2 | cut -d'<' -f1)
                    if [[ -z $modName ]]; then # Set default name if unavailable
                        modName="[NAME UNAVAILABLE]"
                    fi
                    if [[ ! -d $modDir ]]; then
                        echo -e "\n${GREEN}[UPDATE]:${NC} Downloading new Mod: \"${CYAN}${modName}${NC}\" (${CYAN}${modID}${NC})"
                    else
                        echo -e "\n${GREEN}[UPDATE]:${NC} Mod update found for: \"${CYAN}${modName}${NC}\" (${CYAN}${modID}${NC})"
                    fi
                    if [[ -n $latestUpdate ]] && [[ $latestUpdate =~ ^[0-9]+$ ]]; then # Notify last update date, if valid
                        echo -e "\tMod was last updated: ${CYAN}$(date -d @${latestUpdate})${NC}"
                    fi
                    
                    echo -e "\tAttempting mod update/download via SteamCMD...\n"

                    ## A3M: name it now that we have one, and mark it in flight.
                    ## The name is written even when the panel supplied no
                    ## wanted.json, because upstream already paid for it above.
                    if [[ -n ${modName} && ${modName} != "[NAME UNAVAILABLE]" ]] && A3M_Enabled; then
                        printf '%s' "${modName}" > "${A3M_MODS}/${modID}.name" 2>/dev/null
                    fi
                    A3M_SetState "${modID}" "downloading"

                    RunSteamCMD $modType $modID

                    ## A3M: RunSteamCMD reports failure only to the console, and
                    ## returns success either way. The mod folder is the fact
                    ## that decides it — it exists only if the download landed
                    ## and was linked, which is exactly what "installed" means
                    ## for the `-mod=` line.
                    if [[ -d $modDir ]]; then
                        A3M_SetState "${modID}" "done"
                    else
                        A3M_SetState "${modID}" "failed" "SteamCMD did not produce ${modDir}. Check the console log for the reason — a timeout on a very large mod is the usual one, and starting the server again resumes it."
                    fi
                else
                    ## A3M: upstream skips a mod that is already current. That is
                    ## a finished mod, not an absent one, and reporting it as
                    ## waiting would leave the count permanently short.
                    A3M_SetState "${modID}" "done"
                fi
            fi
        done

        ## A3M: the timer stops here. Everything after this point is start-up, and
        ## a monitor left running would keep rewriting a file nothing updates.
        A3M_MonitorStop
        A3M_Render

        # Check over key files for un-configured optional mods' .bikey files
        for keyFile in $(find "keys" -name "*.bikey" -type f); do
            keyFileName=$(basename ${keyFile})

            # If the key file is using the optional mod file name
            if [[ "${keyFileName}" == "optional_"* ]]; then
                modID=$(echo "${keyFileName}" | cut -d _ -f 2)

                # If mod is not in optional mods, delete it
                # If a mod is configured in clientMods or SERVERMODS, we should still delete this file
                # as a new file will have been copied that does not follow the naming scheme
                if [[ "${OPTIONALMODS}" != *"@${modID};"* ]]; then

                    # We only need to let the user know the key file is being deleted if this mod is no longer configured at all.
                    # If clientMods contains the mod ID, we'd just confuse the user by telling them we are deleting the optional .bikey file
                    if [[ "${clientMods}" != *"@${modID};"* ]]; then
                        echo -e "\tKey file and directory for un-configured optional mod ${CYAN}${modID}${NC} is being deleted..."
                    fi

                    # Delete the optional mod .bikey file and directory
                    rm ${keyFile}
                    rm -r @${modID}_optional
                fi
            fi
        done;

        echo -e "${GREEN}[UPDATE]:${NC} Steam Workshop mod update check ${GREEN}complete${NC}!"
    fi
fi

## A3M === SYNC-ONLY MODE ===
#
# Download and update mods, then stop without starting the game.
#
# This is the whole reason a customer can press "Download mods" in the panel and
# not have players dropped into a server that is about to restart anyway. Arma
# reads its mod list once, at startup, so mods fetched underneath a running
# server would not be loaded until the next boot regardless — the choice is only
# ever *when* the restart happens, and this makes it the customer's.
#
# It exits 0. Wings treats a non-zero exit as a crash and will restart the
# container on a crash-restart policy, which would download-and-exit in a loop.
if [[ ${A3M_SYNC_ONLY} == "1" ]]; then
    A3M_MonitorStop

    failed=$(jq -r '.totals.failed // 0' "${A3M_STATUS}" 2>/dev/null)
    [[ $failed =~ ^[0-9]+$ ]] || failed=0

    if [[ $failed -gt 0 ]]; then
        # Deliberately still a clean exit: the per-mod reasons are in status.json
        # and on screen, and the panel is the thing that should decide what a
        # partial sync means. A crash here would bury them behind a restart.
        A3M_Phase "synced_with_errors"
        echo -e "\n${YELLOW}[A3M]: Mod sync finished with ${CYAN}${failed}${YELLOW} mod(s) unaccounted for.${NC}"
        echo -e "\tThe panel's Mods page names them. Starting the server again retries only those."
    else
        A3M_Phase "synced"
        echo -e "\n${GREEN}[A3M]: Mod sync complete.${NC} The server was not started, because A3M_SYNC_ONLY is set."
    fi

    echo -e "${GREEN}[A3M]:${NC} Clear that variable to boot normally.\n"
    exit 0
fi

# Check if specified server binary exists.
if [[ ! -f ${SERVER_BINARY} ]]; then
    echo -e "\n${RED}[STARTUP_ERR]: Specified Arma 3 server binary could not be found in `$(pwd)`!${NC}"
    echo -e "${YELLOW}Please do the following to resolve this issue:${NC}"
    echo -e "\t${CYAN}- Double check your \"Server Binary\" Startup Variable is correct.${NC}"
    echo -e "\t${CYAN}- Ensure your server has properly installed/updated without errors (reinstalling/updating again may help).${NC}"
    echo -e "\t${CYAN}- Use the File Manager to check that your specified server binary file is not missing from `$(pwd)`.${NC}\n"
    exit 1
fi

# Make mods lowercase, if specified
if [[ ${MODS_LOWERCASE} == "1" ]]; then
    for modDir in $allMods; do
        ModsLowercase $modDir
    done
fi

# Define the log file path with a timestamp
logFile="${HOME}/.local/share/Arma 3/rpt/arma3server_$(date '+%m_%d_%Y_%H%M%S').rpt"
# Ensure the logs directory exists
mkdir -p "${HOME}/.local/share/Arma 3/rpt"

# Check if basic.cfg exists, and download if not (Arma really doesn't like it missing for some reason)
if [[ ! -f basic.cfg ]]; then
    echo -e "\n${YELLOW}[STARTUP_WARN]: Basic Network Configuration file \"${CYAN}basic.cfg${YELLOW}\" is missing!${NC}"
    echo -e "\t${YELLOW}Downloading default file for use instead...${NC}"
    curl -sSL ${BASIC_URL} -o ./basic.cfg
fi

# Setup NSS Wrapper for use ($NSS_WRAPPER_PASSWD and $NSS_WRAPPER_GROUP have been set by the Dockerfile)
export USER_ID=$(id -u)
export GROUP_ID=$(id -g)
envsubst < /passwd.template > ${NSS_WRAPPER_PASSWD}

if [[ ${SERVER_BINARY} == *"x64"* ]]; then # Check which libnss-wrapper architecture to run, based off the server binary name
    export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libnss_wrapper.so
else
    export LD_PRELOAD=/usr/lib/i386-linux-gnu/libnss_wrapper.so
fi

# Create server startup parameters config file
cat > ${SERVER_PARAM_FILE} << EOF
// ********************************************************************
// *                                                                  *
// *    Server Startup Parameters Config File                         *
// *                                                                  *
// *    This file is automatically generated by the panel.            *
// *    Do not edit this file. Any changes made will be discarded!    *
// *                                                                  *
// ********************************************************************
-name=server
-ip=0.0.0.0
-port=${SERVER_PORT}
-cfg=basic.cfg
-config=server.cfg
-mod=${clientMods}
-serverMod=${SERVERMODS}
$( [[ "$PARAM_LOADMISSIONTOMEMORY" == "1" ]] && echo "-loadMissionToMemory" )
$( [[ "$PARAM_AUTOINIT" == "1" ]] && echo "-autoInit" )
$( [[ "$PARAM_FILEPATCHING" == "1" ]] && echo "-filePatching" )
-limitFPS=${PARAM_LIMITFPS}
$( [[ "$PARAM_NOLOGS" == "1" ]] && echo "-noLogs" )
EOF

# Create HC startup parameters config file
cat > ${HC_PARAM_FILE} << EOF
// ********************************************************************
// *                                                                  *
// *    Headless Client Startup Parameters Config File                *
// *                                                                  *
// *    This file is automatically generated by the panel.            *
// *    Do not edit this file. Any changes made will be discarded!    *
// *                                                                  *
// ********************************************************************
-client
-ip=127.0.0.1
-port=${SERVER_PORT}
-password=${SERVER_PASSWORD}
-mod=${clientMods}
$( [[ "$PARAM_FILEPATCHING" == "1" ]] && echo "-filePatching" )
-limitFPS=${PARAM_LIMITFPS}
EOF

# Start Headless Clients if applicable
if [[ ${HC_NUM} > 0 ]]; then
    echo -e "\n${GREEN}[STARTUP]:${NC} Starting ${CYAN}${HC_NUM}${NC} Headless Client(s)."
    for i in $(seq ${HC_NUM}); do
        if [[ ${HC_HIDE} == "1" ]]; then
            ./${SERVER_BINARY} -par=${HC_PARAM_FILE} > /dev/null 2>&1 &
        else
            ./${SERVER_BINARY} -par=${HC_PARAM_FILE} &
        fi
        echo -e "${GREEN}[STARTUP]:${CYAN} Headless Client $i${NC} launched."
    done
fi

# Replace Startup Command variables
modifiedStartup=`eval echo $(echo ${STARTUP} | sed -e 's/{{/${/g' -e 's/}}/}/g')`
# Convert PAR file to single-line string
serverParams=$(sed '/^\/\//d' ${SERVER_PARAM_FILE} | tr '\n' ' ' | tr -s ' ')

## A3M: the last write before the game takes over the process. A panel polling
## status.json now sees `running`, which is how it tells "still downloading" from
## "downloaded, and the server is up".
A3M_Phase "running"

# Start the Server
echo -e "\n${GREEN}[STARTUP]:${NC} Starting server with the following startup parameters:"
echo -e "${CYAN}${modifiedStartup/-par=${SERVER_PARAM_FILE}/$serverParams}${NC}\n"
if [[ "$PARAM_NOLOGS" == "1" ]]; then
    ${modifiedStartup}
else
    ${modifiedStartup} 2>&1 | tee -a "$logFile"
fi

# Check server exit code for errors
exitCode=$?
if [[ $exitCode -ne 0 && $exitCode -ne 130 ]]; then # Exit code 130 is SIGTERM
    echo -e "\n${RED}[SERVER_ERR]: The server exited unexpectedly with code ${exitCode}!${NC}\n"
    exit 1
fi
