#!/bin/bash

# Arma 3 Manager Egg — background sync tests
#
# Runs the real `ProcessRequest` against a fake server directory and a **fake
# SteamCMD**, so the whole request → download → status flow is exercised without
# a container, a Steam account or a network.
#
# ## Why a fake SteamCMD rather than mocked functions
#
# The interesting failures are in the wiring, not the arithmetic: a request that
# is claimed but never released, a lock that outlives its process, a download
# that "succeeds" while fetching nothing. Stubbing `DownloadOne` would test none
# of those. A stub binary that creates (or refuses to create) the content
# directory reproduces every one of them, because the code under test decides
# success by looking at the disk — which is the behaviour that matters, since
# SteamCMD exits 0 on plenty of things that fetched nothing.
#
# Run: bash tests/sync.sh

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

IMAGE="$(cd "$(dirname "$0")/../image" && pwd)"

if ! command -v jq > /dev/null 2>&1; then
    echo "jq is required to run these tests."
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
cd "${WORK}" || exit 1

# --- Fake server root ---------------------------------------------------------

WORKSHOP_DIR="./Steam/steamapps/workshop"
GAME_ID=107410
STEAMCMD_DIR="./steamcmd"
STEAMCMD_ATTEMPTS=2
STEAM_USER="someone"
STEAM_PASS="secret"
MODIFICATIONS=""
SERVERMODS=""
OPTIONALMODS=""
A3M_DISABLE=""
A3M_SYNC_ONLY=""
A3M_SYNC_POLL=1
A3M_SYNC_NICE=0

mkdir -p "${STEAMCMD_DIR}" "${WORKSHOP_DIR}/content/${GAME_ID}"

# A fake SteamCMD. It creates the content directory for any id NOT listed in
# `steamcmd/refuse`, which is how a failing download is simulated.
cat > "${STEAMCMD_DIR}/steamcmd.sh" <<'STUB'
#!/bin/bash
id=""
prev=""
for arg in "$@"; do
    [[ $prev == "+workshop_download_item" ]] && appid="$arg"
    [[ $prev == "$appid" && -n ${appid:-} ]] && id="$arg"
    prev="$arg"
done
# Simpler: the last numeric argument before +quit is the item id.
for arg in "$@"; do
    [[ $arg =~ ^[0-9]+$ ]] && last="$arg"
done
id="${last:-}"
if [[ -n $id ]] && ! grep -qx "$id" ./steamcmd/refuse 2>/dev/null; then
    mkdir -p "./Steam/steamapps/workshop/content/107410/$id"
    echo "fake" > "./Steam/steamapps/workshop/content/107410/$id/addon.pbo"
fi
echo "Success. Downloaded item $id"
exit 0
STUB
chmod +x "${STEAMCMD_DIR}/steamcmd.sh"

# Load the daemon's functions without its dispatch loop.
export A3M_COMMON="${IMAGE}/a3m-common.sh"
export A3M_SYNC_LIB_ONLY=1
# shellcheck disable=SC1090
source "${IMAGE}/a3m-sync.sh"

mkdir -p "${A3M_MODS}"

function Request { #[Input: json array body]
    echo "{\"version\":1,\"requested_at\":$(date +%s),\"mods\":$1}" > "${A3M_REQUEST}"
}

# --- Reading a request --------------------------------------------------------

echo "Reading a request:"
Request '["450814997","463939057"]'
check 'ids come from the request file' \
    "$(RequestedIds "${A3M_REQUEST}" | xargs)" '450814997 463939057'

echo '{"version":1,"mods":[]}' > "${A3M_REQUEST}"
MODIFICATIONS="@111;@222;"
check 'an empty request falls back to the load order' \
    "$(RequestedIds "${A3M_REQUEST}" | xargs)" '111 222'
MODIFICATIONS=""

check 'a missing file falls back too' \
    "$(RequestedIds "/nonexistent" | xargs)" ''

# --- The lock -----------------------------------------------------------------

echo ""
echo "The lock:"
rm -f "${A3M_REQUEST}"
check 'a free lock is taken' "$( { Lock >/dev/null 2>&1; } && echo yes || echo no)" 'yes'
check 'a held lock is refused' "$( { Lock >/dev/null 2>&1; } && echo yes || echo no)" 'no'
Unlock
check 'and released' "$( { Lock >/dev/null 2>&1; } && echo yes || echo no)" 'yes'
Unlock

# A container killed mid-download must not disable sync forever.
mkdir -p "${A3M_LOCK}"
touch -d '3 hours ago' "${A3M_LOCK}" 2>/dev/null || touch -t 200001010000 "${A3M_LOCK}"
check 'a stale lock is broken open' "$( { Lock >/dev/null 2>&1; } && echo yes || echo no)" 'yes'
Unlock

# --- A successful sync --------------------------------------------------------

echo ""
echo "A successful sync:"
Request '["450814997","463939057"]'
ProcessRequest > /dev/null 2>&1

check 'both mods are in the cache' \
    "$(ls "${WORKSHOP_DIR}/content/${GAME_ID}" | sort | tr '\n' ' ')" '450814997 463939057 '
check 'both report done' \
    "$(jq -r '[.mods[] | select(.state=="done")] | length' "${A3M_STATUS}")" '2'
check 'nothing failed' "$(jq -r '.totals.failed' "${A3M_STATUS}")" '0'
check 'the request was consumed' \
    "$(test -f "${A3M_REQUEST}" -o -f "${A3M_ACTIVE}" && echo present || echo gone)" 'gone'
check 'the lock was released' \
    "$(test -d "${A3M_LOCK}" && echo held || echo free)" 'free'
# The daemon is not "running" here, so the phase stays terminal.
check 'the phase ends synced' "$(jq -r '.phase' "${A3M_STATUS}")" 'synced'

# --- The @<id> folders are deliberately NOT built -----------------------------
#
# They are what a live Arma has open, and the entrypoint's linking step starts
# with `rm -rf @<id>`. Building one here would do that underneath a running
# session, to activate a mod Arma could not load before a restart anyway.

echo ""
echo "Live server safety:"
check 'no @<id> folder was created' \
    "$(find . -maxdepth 1 -name '@*' | wc -l | tr -d ' ')" '0'

# --- A mod already cached is not re-fetched -----------------------------------

echo ""
echo "Already cached:"
echo "450814997" > "${STEAMCMD_DIR}/refuse"
Request '["450814997"]'
ProcessRequest > /dev/null 2>&1
# The stub would refuse it, so `done` proves the cache short-circuit ran.
check 'a cached mod is reported done without a download' \
    "$(jq -r '.mods[] | select(.id=="450814997") | .state' "${A3M_STATUS}")" 'done'
rm -f "${STEAMCMD_DIR}/refuse"

# --- A failing download -------------------------------------------------------

echo ""
echo "A failing download:"
echo "332350688" > "${STEAMCMD_DIR}/refuse"
Request '["332350688"]'
ProcessRequest > /dev/null 2>&1

check 'it is reported failed' \
    "$(jq -r '.mods[] | select(.id=="332350688") | .state' "${A3M_STATUS}")" 'failed'
check 'with a reason a customer can act on' \
    "$(jq -r '.mods[] | select(.id=="332350688") | .error' "${A3M_STATUS}" | grep -c 'sync.log')" '1'
check 'the phase says so' "$(jq -r '.phase' "${A3M_STATUS}")" 'synced_with_errors'
check 'the lock is still released after a failure' \
    "$(test -d "${A3M_LOCK}" && echo held || echo free)" 'free'
check 'the request is still consumed after a failure' \
    "$(test -f "${A3M_REQUEST}" -o -f "${A3M_ACTIVE}" && echo present || echo gone)" 'gone'
rm -f "${STEAMCMD_DIR}/refuse"

# --- Junk in a request --------------------------------------------------------

echo ""
echo "Junk in a request:"
Request '["not-an-id","../../etc/passwd",""]'
ProcessRequest > /dev/null 2>&1
check 'non-numeric ids are dropped, and nothing is created' \
    "$(find "${WORKSHOP_DIR}/content/${GAME_ID}" -maxdepth 1 -mindepth 1 ! -name '4*' ! -name '3*' | wc -l | tr -d ' ')" '0'
check 'the request is consumed rather than looping forever' \
    "$(test -f "${A3M_REQUEST}" -o -f "${A3M_ACTIVE}" && echo present || echo gone)" 'gone'

# --- No usable Steam account --------------------------------------------------
#
# Anonymous cannot fetch Arma 3 Workshop items at all, so this must fail loudly
# and once rather than retrying every mod three times forever.

echo ""
echo "No Steam account:"
STEAM_USER="anonymous"
Request '["111111111"]'
ProcessRequest > /dev/null 2>&1
check 'every mod is failed' \
    "$(jq -r '.mods[] | select(.id=="111111111") | .state' "${A3M_STATUS}")" 'failed'
check 'the reason names the variables to set' \
    "$(jq -r '.mods[] | select(.id=="111111111") | .error' "${A3M_STATUS}" | grep -c 'STEAM_USER')" '1'
check 'nothing was downloaded' \
    "$(test -d "${WORKSHOP_DIR}/content/${GAME_ID}/111111111" && echo yes || echo no)" 'no'
check 'the lock is released' "$(test -d "${A3M_LOCK}" && echo held || echo free)" 'free'
STEAM_USER="someone"

# --- A second request while one is locked -------------------------------------

echo ""
echo "Contention:"
mkdir -p "${A3M_LOCK}"
Request '["999999999"]'
ProcessRequest > /dev/null 2>&1
check 'the request is left queued, not dropped' \
    "$(test -f "${A3M_REQUEST}" && echo queued || echo gone)" 'queued'
check 'and nothing was downloaded behind the lock' \
    "$(test -d "${WORKSHOP_DIR}/content/${GAME_ID}/999999999" && echo yes || echo no)" 'no'
rmdir "${A3M_LOCK}"
rm -f "${A3M_REQUEST}"

echo ""
echo "----------------------------------------"
echo "${pass} passed, ${fail} failed"

exit $(( fail > 0 ? 1 : 0 ))
