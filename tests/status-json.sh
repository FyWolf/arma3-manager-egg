#!/bin/bash

# Arma 3 Manager Egg — status.json tests
#
# Exercises the A3M functions from image/a3m-common.sh against a fake server
# directory, with no container, no SteamCMD and no panel.
#
# ## Why these exist
#
# The status file is the *only* thing the panel reads to decide what a customer
# sees on the Mods page. A wrong percentage, a missed state transition or a
# malformed document are all silent: the entrypoint carries on downloading
# perfectly and the page reports nonsense. There is no error anywhere to notice.
#
# So the assertions below are about the two things that cannot be checked by
# reading the code — that the jq actually parses, and that the arithmetic comes
# out where it should at the boundaries (zero, exact, over-100, unknown size).
#
# Run: bash tests/status-json.sh

set -u

pass=0
fail=0

function check { #[Input: string label; string actual; string expected]
    if [[ "$2" == "$3" ]]; then
        echo "  ok   $1"
        pass=$((pass + 1))
    else
        echo "  FAIL $1"
        echo "       expected: $3"
        echo "       actual:   $2"
        fail=$((fail + 1))
    fi
}

# --- Load the functions under test -------------------------------------------
#
# Sourced directly. These used to be carved out of entrypoint.sh with sed, which
# worked but pinned the test to a comment header; now they live in a library
# precisely so both the entrypoint and the sync daemon can share them, and a
# library is a thing a test can just source.

FUNCS="$(cd "$(dirname "$0")/../image" && pwd)/a3m-common.sh"

if [[ ! -f ${FUNCS} ]]; then
    echo "Cannot find ${FUNCS}"
    exit 1
fi

if ! command -v jq > /dev/null 2>&1; then
    echo "jq is required to run these tests (the entrypoint depends on it too)."
    exit 1
fi

# --- Fake server root ---------------------------------------------------------

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
cd "${WORK}" || exit 1

# The constants the functions close over, matching the entrypoint's own.
A3M_DIR="./.arma3-manager"
A3M_STATUS="${A3M_DIR}/status.json"
A3M_MODS="${A3M_DIR}/mods"
A3M_WANTED="${A3M_DIR}/wanted.json"
A3M_POLL=5
A3M_MONITOR_PID=""
A3M_DISABLE=""
A3M_SYNC_ONLY=""
WORKSHOP_DIR="./Steam/steamapps/workshop"
GAME_ID=107410

# shellcheck disable=SC1090
source "${FUNCS}"

# A mod whose files are fully downloaded: 2000 bytes of content.
mkdir -p "${WORKSHOP_DIR}/content/${GAME_ID}/111"
head -c 2000 /dev/zero > "${WORKSHOP_DIR}/content/${GAME_ID}/111/addon.pbo"

# A mod halfway through: 1000 of an expected 2000 bytes, still staged.
mkdir -p "${WORKSHOP_DIR}/downloads/${GAME_ID}/222"
head -c 1000 /dev/zero > "${WORKSHOP_DIR}/downloads/${GAME_ID}/222/part.pbo"

echo "du -sb sanity:"
duBytes="$(du -sb "${WORKSHOP_DIR}/downloads/${GAME_ID}/222" 2>/dev/null | cut -f1)"
if [[ ! ${duBytes} =~ ^[0-9]+$ ]]; then
    echo "  SKIP: du -sb unavailable here, so byte counts cannot be checked."
    echo "        (The container image is Debian, where it is present.)"
    duBytes=0
fi
echo "  ok   du reported ${duBytes} bytes for the staged mod"

# --- Seed --------------------------------------------------------------------

A3M_Init "@111;@222;@333;vn;@mymod"

echo ""
echo "Seeding:"
check 'only numeric ids get a state file' \
    "$(find "${A3M_MODS}" -name '*.state' | wc -l | tr -d ' ')" '3'
check 'a CDLC code is not tracked as a download' \
    "$(test -f "${A3M_MODS}/vn.state" && echo yes || echo no)" 'no'
check 'every seeded mod starts as waiting' \
    "$(jq -r '[.mods[].state] | unique | join(",")' "${A3M_STATUS}")" 'waiting'
check 'phase is starting' "$(jq -r '.phase' "${A3M_STATUS}")" 'starting'
check 'the document declares its version' \
    "$(jq -r '.version' "${A3M_STATUS}")" '1'

# --- The panel supplies names and sizes ---------------------------------------

cat > "${A3M_WANTED}" <<'WANTEDEOF'
{
  "mods": {
    "111": { "name": "CBA_A3", "bytes": 2000 },
    "222": { "name": "ACE3", "bytes": 2000 }
  }
}
WANTEDEOF

A3M_SetState 111 done
A3M_SetState 222 downloading

echo ""
echo "Progress:"
check 'a finished mod reports 100 percent' \
    "$(jq -r '.mods[] | select(.id=="111") | .percent' "${A3M_STATUS}")" '100'
check 'a mod in flight reports its real fraction' \
    "$(jq -r '.mods[] | select(.id=="222") | .percent' "${A3M_STATUS}")" \
    "$( [[ ${duBytes} == 0 ]] && echo 0 || echo 50 )"
check 'an unknown size reports null rather than zero percent' \
    "$(jq -r '.mods[] | select(.id=="333") | .percent' "${A3M_STATUS}")" 'null'
check 'names come from the panel' \
    "$(jq -r '.mods[] | select(.id=="111") | .name' "${A3M_STATUS}")" 'CBA_A3'
check 'an unnamed mod is null, not an empty string' \
    "$(jq -r '.mods[] | select(.id=="333") | .name' "${A3M_STATUS}")" 'null'

# --- The entrypoint's own scraped name fills the gap --------------------------

printf '%s' 'Hand Added Mod' > "${A3M_MODS}/333.name"
A3M_Render

check 'a name scraped by the entrypoint is used when the panel had none' \
    "$(jq -r '.mods[] | select(.id=="333") | .name' "${A3M_STATUS}")" 'Hand Added Mod'
check 'the panel still wins where it has one' \
    "$(jq -r '.mods[] | select(.id=="111") | .name' "${A3M_STATUS}")" 'CBA_A3'

# --- Totals -------------------------------------------------------------------

echo ""
echo "Totals:"
check 'total counts every tracked mod' "$(jq -r '.totals.total' "${A3M_STATUS}")" '3'
check 'done is counted' "$(jq -r '.totals.done' "${A3M_STATUS}")" '1'
check 'downloading is counted' "$(jq -r '.totals.downloading' "${A3M_STATUS}")" '1'
check 'waiting is counted' "$(jq -r '.totals.waiting' "${A3M_STATUS}")" '1'
check 'failed starts at zero' "$(jq -r '.totals.failed' "${A3M_STATUS}")" '0'

# --- Failure carries a reason -------------------------------------------------

A3M_SetState 333 failed "SteamCMD did not produce @333."

echo ""
echo "Failure:"
check 'a failure is counted' "$(jq -r '.totals.failed' "${A3M_STATUS}")" '1'
check 'a failure carries its reason' \
    "$(jq -r '.mods[] | select(.id=="333") | .error' "${A3M_STATUS}")" \
    'SteamCMD did not produce @333.'
check 'a healthy mod has a null error' \
    "$(jq -r '.mods[] | select(.id=="111") | .error' "${A3M_STATUS}")" 'null'

A3M_SetState 333 waiting
check 'clearing a state clears its error' \
    "$(jq -r '.mods[] | select(.id=="333") | .error' "${A3M_STATUS}")" 'null'

# --- A percentage can never exceed 100 ----------------------------------------
#
# It genuinely can overshoot: `bytes` is what is on disk and `expected_bytes` is
# what Steam reported when the panel last looked. A mod updated since then is
# larger than its recorded size, and an uncapped bar would render past its track.

cat > "${A3M_WANTED}" <<'SMALLEOF'
{ "mods": { "111": { "name": "CBA_A3", "bytes": 10 } } }
SMALLEOF
A3M_Render

echo ""
echo "Clamping:"
check 'an oversized download clamps to 100' \
    "$(jq -r '.mods[] | select(.id=="111") | .percent' "${A3M_STATUS}")" '100'
check 'the raw byte count is still reported honestly' \
    "$(jq -r '.mods[] | select(.id=="111") | .bytes' "${A3M_STATUS}")" \
    "$( [[ ${duBytes} == 0 ]] && echo 0 || echo 2000 )"

# --- Phases -------------------------------------------------------------------

A3M_Phase "running"
echo ""
echo "Phases:"
check 'phase is written through' "$(jq -r '.phase' "${A3M_STATUS}")" 'running'
check 'sync_only is false when unset' "$(jq -r '.sync_only' "${A3M_STATUS}")" 'false'

A3M_SYNC_ONLY=1
A3M_Phase "synced"
check 'sync_only is reported when set' "$(jq -r '.sync_only' "${A3M_STATUS}")" 'true'

# --- Re-init does not lose what the panel wrote -------------------------------

A3M_Init "@111"
echo ""
echo "Re-init:"
check 'wanted.json survives a restart' \
    "$(test -f "${A3M_WANTED}" && echo yes || echo no)" 'yes'
check 'the previous run is forgotten' \
    "$(jq -r '.totals.total' "${A3M_STATUS}")" '1'
check 'a stale monitor flag is cleared' \
    "$(test -f "${A3M_DIR}/monitor" && echo yes || echo no)" 'no'

# --- Opting out ---------------------------------------------------------------

A3M_DISABLE=1
before="$(jq -r '.updated_at' "${A3M_STATUS}")"
A3M_SetState 111 done
echo ""
echo "Disabled:"
check 'A3M_DISABLE stops all writing' \
    "$(jq -r '.updated_at' "${A3M_STATUS}")" "${before}"

# --- Result -------------------------------------------------------------------

echo ""
echo "----------------------------------------"
echo "${pass} passed, ${fail} failed"

exit $(( fail > 0 ? 1 : 0 ))
