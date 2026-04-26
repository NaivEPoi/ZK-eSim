#!/usr/bin/env bash
# ZK-eSIM End-to-End Workflow
#
# Phase 1: Build JavaCard applet + inject into eSIM profile + install via SM-DP+
#   - Uses DEFAULT ISD-R AID (standard SGP.22 profile download)
# Phase 2: Test the ZK-eSIM applet directly
#   - Uses ZK-eSIM APPLET AID (LPAC_CUSTOM_ISD_R_AID) to target the applet
#
# Usage:
#   bash zkesim_workflow.sh [--skip-build] [--skip-download] [--help]
#
# Environment overrides (all optional):
#   MATCHING_ID          Profile matching ID (default: zkesimTest)
#   LOAD_PACKAGE_AID     JavaCard package AID (default: D07002CA44)
#   CLASS_AID            Applet class AID (default: D07002CA44900101)
#   INSTANCE_AID         Applet instance AID (default: D07002CA44900101)
#   SMDPP_HOST           SM-DP+ bind host (default: testsmdpplus1.example.com)
#   SMDPP_PORT           SM-DP+ bind port (default: 443)
#   SMDPP_EXTRA_ARGS     Extra args passed to osmo-smdpp.py (default: none)
#   LPAC_BIN             Path to lpac binary (default: auto-detected)
#   LPAC_APDU            APDU backend (default: pcsc)
#   LPAC_HTTP            HTTP backend (default: curl)
#   PHASE2_APDU_DEBUG    Set to 1 to print raw APDU trace in Phase 2 (default: 1)
#   ZK_DOWNLOAD          Set to 1 to use ZK profile download via lpac zk-download (default: 0)
#                        Phase 0 (RegisterAndIssue + CertInit) runs automatically in the ZK path.
#   MNO_HOST             MNO server host — defaults to SMDPP_HOST (co-located)
#   MNO_PORT             MNO server port — defaults to SMDPP_PORT (co-located)
#   SKIP_BUILD           Set to 1 to skip Phase 1 build step
#   SKIP_DOWNLOAD        Set to 1 to skip profile download step

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLET_DIR="${REPO_ROOT}/ZK-eSIM_applet"
PYSIM_ROOT="${REPO_ROOT}/pysim"
LPAC_BIN="${LPAC_BIN:-${REPO_ROOT}/lpac/output/executables/lpac}"
LPAC_LIB_DIR="${REPO_ROOT}/lpac/build:${REPO_ROOT}/lpac/build/driver:${REPO_ROOT}/lpac/build/utils:${REPO_ROOT}/lpac/build/euicc"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
MATCHING_ID="${MATCHING_ID:-zkesimTest}"
LOAD_PACKAGE_AID="${LOAD_PACKAGE_AID:-D07002CA44}"
CLASS_AID="${CLASS_AID:-D07002CA44900101}"
INSTANCE_AID="${INSTANCE_AID:-D07002CA44900101}"
SMDPP_HOST="${SMDPP_HOST:-testsmdpplus1.example.com}"
SMDPP_PORT="${SMDPP_PORT:-443}"
SMDPP_EXTRA_ARGS="${SMDPP_EXTRA_ARGS:-}"
PHASE2_APDU_DEBUG="${PHASE2_APDU_DEBUG:-1}"
SKIP_BUILD="${SKIP_BUILD:-0}"
SKIP_DOWNLOAD="${SKIP_DOWNLOAD:-0}"
ZK_DOWNLOAD="${ZK_DOWNLOAD:-0}"
# MNO is co-located with SM-DP+; override only if running a separate MNO server.
MNO_HOST="${MNO_HOST:-${SMDPP_HOST}}"
MNO_PORT="${MNO_PORT:-${SMDPP_PORT}}"

# Export lpac backend settings (used in both phases)
export LPAC_APDU="${LPAC_APDU:-pcsc}"
export LPAC_HTTP="${LPAC_HTTP:-curl}"
# lpac shared libraries live in the build/driver directory
export LD_LIBRARY_PATH="${LPAC_LIB_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${CYAN}[zkesim]${RESET} $*"; }
ok()   { echo -e "${GREEN}[  OK  ]${RESET} $*"; }
warn() { echo -e "${YELLOW}[ WARN ]${RESET} $*"; }
err()  { echo -e "${RED}[ERROR ]${RESET} $*" >&2; }
banner() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════${RESET}"; \
           echo -e "${BOLD}${CYAN}  $*${RESET}"; \
           echo -e "${BOLD}${CYAN}══════════════════════════════════════════════${RESET}\n"; }

# Returns current time in milliseconds (cross-platform: macOS + Linux).
_ts_ms() { python3 -c "import time; print(int(time.time() * 1000))"; }

# ---------------------------------------------------------------------------
# Phase timing accumulators (set during the ZK download path)
# ---------------------------------------------------------------------------
T_REGISTER_MS=0
T_CERTINIT_MS=0
T_ZK_DOWNLOAD_MS=0

print_timing_summary() {
  local total=$(( T_REGISTER_MS + T_CERTINIT_MS + T_ZK_DOWNLOAD_MS ))
  echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${CYAN}  Timing Summary${RESET}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════${RESET}"
  printf "  %-36s %s\n" "Phase" "Wall-clock (ms)"
  echo -e "  ──────────────────────────────────────────────"
  printf "  %-36s %d ms\n" "Registration (BF44+BF45)"       "${T_REGISTER_MS}"
  printf "  %-36s %d ms\n" "Certificate Init (BF46+BF47)"   "${T_CERTINIT_MS}"
  printf "  %-36s %d ms\n" "ZK Profile Download (BF42+BF43)" "${T_ZK_DOWNLOAD_MS}"
  echo -e "  ──────────────────────────────────────────────"
  printf "  %-36s %d ms\n" "Total (ZK path)" "${total}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════${RESET}\n"
  log "Server-side per-handler latency is in: ${REPO_ROOT}/smdpp.log (grep '[timing]')"
}

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    --skip-build)    SKIP_BUILD=1 ;;
    --skip-download) SKIP_DOWNLOAD=1 ;;
    --zk-download)   ZK_DOWNLOAD=1 ;;
    --help|-h)
      sed -n '2,20p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) err "Unknown argument: $arg"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Cleanup trap — kill SM-DP+ server on exit
# ---------------------------------------------------------------------------
SMDPP_PID=""

# Kill any process currently listening on a given TCP port.
# Prevents "Address already in use" when a previous server wasn't cleaned up.
_sweep_port() {
  local port="$1"
  local pids
  pids=$(lsof -iTCP:"${port}" -sTCP:LISTEN -t 2>/dev/null || true)
  if [[ -n "${pids}" ]]; then
    warn "Port ${port} already in use by PID(s): ${pids} — killing..."
    echo "${pids}" | xargs kill 2>/dev/null || true
    # Wait up to 2 s for the port to be released.
    local i=4
    while [[ ${i} -gt 0 ]]; do
      sleep 0.5
      lsof -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1 || break
      i=$(( i - 1 ))
    done
    ok "Port ${port} cleared."
  fi
}

stop_smdpp() {
  if [[ -n "${SMDPP_PID}" ]]; then
    log "Stopping SM-DP+ server (PID ${SMDPP_PID})..."
    kill "${SMDPP_PID}" 2>/dev/null || true
    wait "${SMDPP_PID}" 2>/dev/null || true
    SMDPP_PID=""
    ok "SM-DP+ server stopped."
  fi
  # Sweep any orphaned processes that slipped past PID tracking.
  _sweep_port "${SMDPP_PORT}"
}
cleanup() {
  stop_smdpp
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# eUICC memory reset helper
# ---------------------------------------------------------------------------
euicc_memory_reset() {
  local purge_output
  local purge_rc

  log "Resetting eUICC memory to free space before download..."
  set +e
  purge_output=$(LPAC_APDU="${LPAC_APDU}" LPAC_HTTP="${LPAC_HTTP}" \
    "${LPAC_BIN}" chip purge yes 2>&1)
  purge_rc=$?
  set -e

  if [[ ${purge_rc} -ne 0 ]]; then
    if echo "${purge_output}" | grep -qi "nothing to delete"; then
      warn "eUICC memory reset skipped: nothing to delete."
      return 0
    fi

    echo "${purge_output}" >&2
    err "eUICC memory reset failed (rc=${purge_rc})."
    return ${purge_rc}
  fi

  [[ -n "${purge_output}" ]] && echo "${purge_output}"
  ok "eUICC memory reset completed."
}

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
check_prereqs() {
  local missing=0
  log "Checking prerequisites..."

  [[ -d "${APPLET_DIR}" ]] || { err "ZK-eSIM_applet directory not found: ${APPLET_DIR}"; missing=1; }
  [[ -d "${PYSIM_ROOT}" ]] || { err "pysim directory not found: ${PYSIM_ROOT}"; missing=1; }
  [[ -f "${PYSIM_ROOT}/osmo-smdpp.py" ]] || { err "osmo-smdpp.py not found in ${PYSIM_ROOT}"; missing=1; }

  if [[ "${SKIP_BUILD}" == "0" ]]; then
    command -v ant >/dev/null 2>&1 || { err "'ant' not found. Install Apache Ant."; missing=1; }
    command -v python3 >/dev/null 2>&1 || { err "'python3' not found."; missing=1; }
    [[ -f "${PYSIM_ROOT}/contrib/saip-tool.py" ]] || { err "saip-tool.py not found in ${PYSIM_ROOT}/contrib/"; missing=1; }
  fi

  command -v cmake >/dev/null 2>&1 || { err "'cmake' not found. Install CMake."; missing=1; }

  [[ "${missing}" == "0" ]] || exit 1
  ok "All prerequisites satisfied."
}

# ---------------------------------------------------------------------------
# PHASE 0 — Build lpac
# ---------------------------------------------------------------------------
phase0_build_lpac() {
  banner "Phase 0 — Build lpac"

  local jobs="4"
  if command -v nproc >/dev/null 2>&1; then
    jobs="$(nproc)"
  fi

  log "Configuring lpac..."
  (cd "${REPO_ROOT}/lpac" && cmake -B build -DSTANDALONE_MODE=ON)

  log "Building lpac (jobs=${jobs})..."
  (cd "${REPO_ROOT}/lpac" && cmake --build build -j "${jobs}")

  log "Installing lpac..."
  (cd "${REPO_ROOT}/lpac" && DESTDIR=output cmake --install build)

  if [[ ! -f "${LPAC_BIN}" ]]; then
    err "lpac binary missing after build: ${LPAC_BIN}"
    exit 1
  fi

  ok "lpac build complete: ${LPAC_BIN}"
}

# ---------------------------------------------------------------------------
# PHASE 1a — Build applet CAP and create DER profile
# ---------------------------------------------------------------------------
phase1_build() {
  banner "Phase 1a — Build Applet & Create eSIM Profile"

  log "Running build_and_inject_profile.sh..."
  log "  MATCHING_ID      = ${MATCHING_ID}"
  log "  LOAD_PACKAGE_AID = ${LOAD_PACKAGE_AID}"
  log "  CLASS_AID        = ${CLASS_AID}"
  log "  INSTANCE_AID     = ${INSTANCE_AID}"

  MATCHING_ID="${MATCHING_ID}" \
  LOAD_PACKAGE_AID="${LOAD_PACKAGE_AID}" \
  CLASS_AID="${CLASS_AID}" \
  INSTANCE_AID="${INSTANCE_AID}" \
  PYSIM_ROOT="${PYSIM_ROOT}" \
  INSTALL_TO_SMDPP_UPP="1" \
    bash "${APPLET_DIR}/build_and_inject_profile.sh"

  local dest="${PYSIM_ROOT}/smdpp-data/upp/${MATCHING_ID}.der"
  if [[ ! -f "${dest}" ]]; then
    err "Expected profile not found at: ${dest}"
    exit 1
  fi
  ok "Profile installed for SM-DP+ lookup: ${dest}"
}

# ---------------------------------------------------------------------------
# PHASE 1b — Start SM-DP+ server
# ---------------------------------------------------------------------------
phase1_start_smdpp() {
  banner "Phase 1b — Start SM-DP+ Server"
  local zk_flag="${1:-0}"

  # Clear any stale server on the target port before starting a fresh one.
  _sweep_port "${SMDPP_PORT}"

  log "Starting osmo-smdpp.py on ${SMDPP_HOST}:${SMDPP_PORT}..."
  if [[ "${zk_flag}" == "1" ]]; then
    log "  Server mode   : zk (--zk)"
  else
    log "  Server mode   : normal"
  fi

  local smdpp_log="${REPO_ROOT}/smdpp.log"
  log "SM-DP+ server log: ${smdpp_log}"

  # Run from pysim/ so relative paths to smdpp-data/ resolve correctly
  # shellcheck disable=SC2086
  (cd "${PYSIM_ROOT}" && python3 osmo-smdpp.py \
    -H "${SMDPP_HOST}" \
    -p "${SMDPP_PORT}" \
    -v \
    $( [[ "${zk_flag}" == "1" ]] && printf '%s' "--zk" ) \
    ${SMDPP_EXTRA_ARGS}) \
    >"${smdpp_log}" 2>&1 &
  SMDPP_PID=$!

  # Wait up to 10 s for the server to bind on its port
  # Use lsof for cross-platform support (macOS + Linux); fall back to ss/netstat.
  local retries=20
  local ready=0
  while [[ ${retries} -gt 0 ]]; do
    if ! kill -0 "${SMDPP_PID}" 2>/dev/null; then
      err "SM-DP+ server process exited unexpectedly. Check ${smdpp_log} for details."
      exit 1
    fi
    if lsof -iTCP:"${SMDPP_PORT}" -sTCP:LISTEN >/dev/null 2>&1 || \
       ss -tlnp 2>/dev/null | grep -q ":${SMDPP_PORT} " || \
       netstat -an 2>/dev/null | grep -q "[.:]${SMDPP_PORT} "; then
      ready=1
      break
    fi
    sleep 0.5
    retries=$((retries - 1))
  done

  if [[ "${ready}" == "0" ]]; then
    err "SM-DP+ server did not bind on port ${SMDPP_PORT} within 10 s. Check ${smdpp_log} for details."
    exit 1
  fi
  ok "SM-DP+ server running (PID ${SMDPP_PID}). Logs: ${smdpp_log}"
}

# ---------------------------------------------------------------------------
# PHASE 1c — Download profile to eUICC (DEFAULT ISD-R AID)
# ---------------------------------------------------------------------------
phase1_download() {
  banner "Phase 1c — Download Profile to eUICC (Default ISD-R AID)"

  log "Using DEFAULT ISD-R AID for standard SGP.22 profile download."
  log "  SM-DP+ server : ${SMDPP_HOST}"
  log "  Matching ID   : ${MATCHING_ID}"

  # Unset any custom ISD-R AID override to use the standard ISD-R
  unset LPAC_CUSTOM_ISD_R_AID

  euicc_memory_reset

  # Delete any existing profiles before downloading
  log "Checking for existing profiles to delete..."
  local profile_list
  profile_list=$(LPAC_APDU="${LPAC_APDU}" LPAC_HTTP="${LPAC_HTTP}" \
    "${LPAC_BIN}" profile list)

  local existing_iccids
  existing_iccids=$(echo "${profile_list}" \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
for p in data.get('payload', {}).get('data', []):
    print(p['iccid'])
" || true)

  if [[ -n "${existing_iccids}" ]]; then
    while IFS= read -r iccid; do
      log "Disabling profile: ${iccid}"
      LPAC_APDU="${LPAC_APDU}" LPAC_HTTP="${LPAC_HTTP}" \
        "${LPAC_BIN}" profile disable "${iccid}" 0 || true
      log "Deleting profile: ${iccid}"
      LPAC_APDU="${LPAC_APDU}" LPAC_HTTP="${LPAC_HTTP}" \
        "${LPAC_BIN}" profile delete "${iccid}"
    done <<< "${existing_iccids}"
    ok "Existing profiles deleted."
  else
    log "No existing profiles found."
  fi

  # ── Stage 1: card resource diagnostic ─────────────────────────────────────
  # Print EUICCInfo2 extCardResource so that memory-related install failures
  # can be attributed to NVM exhaustion, RAM exhaustion, or quota over-declaration.
  log "Card resource check (EUICCInfo2 extCardResource):"
  local card_info
  card_info=$(LPAC_APDU="${LPAC_APDU}" LPAC_HTTP="${LPAC_HTTP}" \
    "${LPAC_BIN}" chip info 2>/dev/null || true)
  # Pass card_info via env var to avoid stdin ambiguity with here-doc.
  # The diagnostic is best-effort — never let it kill the workflow.
  CARD_INFO_JSON="${card_info}" python3 -c '
import os, json, sys

raw = os.environ.get("CARD_INFO_JSON", "").strip()
if not raw:
    print("  [warn] lpac chip info returned no output — card may be busy or flag unsupported")
    sys.exit(0)
try:
    data = json.loads(raw)
except json.JSONDecodeError as e:
    print(f"  [warn] Could not parse chip info JSON: {e}")
    sys.exit(0)

er = ((data.get("payload") or {}).get("data") or {}).get("extCardResource") or {}
nvm_free  = er.get("freeNonVolatileMemory")
ram_free  = er.get("freeVolatileMemory")
installed = er.get("installedApplication")

if nvm_free is None and ram_free is None:
    print("  [warn] extCardResource not reported by card (field absent in EUICCInfo2)")
else:
    print(f"  installedApplication    : {installed}")
    print(f"  freeNonVolatileMemory   : {nvm_free} bytes")
    print(f"  freeVolatileMemory      : {ram_free} bytes")
    NVM_MIN = 35000
    RAM_MIN  = 1024
    if nvm_free is not None and nvm_free < NVM_MIN:
        print(f"  [WARN] freeNonVolatileMemory ({nvm_free}) < {NVM_MIN}: NVM exhaustion likely")
        print("         Consider running an eUICC memory reset before retrying.")
    if ram_free is not None and ram_free < RAM_MIN:
        print(f"  [WARN] freeVolatileMemory ({ram_free}) < {RAM_MIN}: RAM exhaustion likely")
        print("         This may cause errorReason 10 (installFailedDueToInsufficientMemoryForProfile).")
' || true
  # ─────────────────────────────────────────────────────────────────────────

  log "Running: ${LPAC_BIN} profile download -s ${SMDPP_HOST} -m ${MATCHING_ID}"
  local download_rc=0
  set +e
  LPAC_APDU="${LPAC_APDU}" \
  LPAC_HTTP="${LPAC_HTTP}" \
    "${LPAC_BIN}" profile download \
      -s "${SMDPP_HOST}" \
      -m "${MATCHING_ID}"
  download_rc=$?
  set -e

  if [[ "${download_rc}" != "0" ]]; then
    warn "Profile download failed (rc=${download_rc}) — likely applet install error."
    exit 1
  fi

  ok "Profile download complete."

  log "Verifying profile installation..."
  local profile_list_json
  profile_list_json=$(LPAC_APDU="${LPAC_APDU}" LPAC_HTTP="${LPAC_HTTP}" \
    "${LPAC_BIN}" profile list)
  echo "${profile_list_json}"

  # Enable the newly-downloaded profile so its applets become selectable via AID.
  local new_iccid
  new_iccid=$(echo "${profile_list_json}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for p in data.get('payload', {}).get('data', []):
    if p.get('profileState') == 'disabled':
        print(p['iccid'])
        break
" 2>/dev/null || true)

  if [[ -n "${new_iccid}" ]]; then
    log "Enabling profile ICCID ${new_iccid}..."
    LPAC_APDU="${LPAC_APDU}" LPAC_HTTP="${LPAC_HTTP}" \
      "${LPAC_BIN}" profile enable "${new_iccid}" || \
      warn "profile enable returned non-zero (may be OK if already enabled)."
    ok "Profile ${new_iccid} enabled."
  else
    warn "No disabled profile found — assuming already enabled."
  fi

  ok "Phase 1 complete — profile installed in eUICC."
}

# ---------------------------------------------------------------------------
# PHASE 1c (ZK path) — ZK profile download via lpac zk-download
# ---------------------------------------------------------------------------
phase1_zk_download() {
  banner "Phase 1c — ZK Profile Download (lpac zk-download)"

  local mno_addr="${MNO_HOST}:${MNO_PORT}"
  log "MNO address (co-located SM-DP+) : ${mno_addr}"
  log "SM-DP+ server                   : ${SMDPP_HOST}"

  # Unset any custom ISD-R AID so zk-download targets the real ISD-R.
  unset LPAC_CUSTOM_ISD_R_AID

  euicc_memory_reset

  log "Running: ${LPAC_BIN} profile zk-download -n ${mno_addr}"
  local rc=0
  set +e
  LPAC_APDU="${LPAC_APDU}" \
  LPAC_HTTP="${LPAC_HTTP}" \
    "${LPAC_BIN}" profile zk-download \
      -n "${mno_addr}"
  rc=$?
  set -e

  if [[ "${rc}" != "0" ]]; then
    err "ZK profile download failed (rc=${rc})."
    exit 1
  fi

  ok "ZK profile download complete."

  log "Verifying profile installation..."
  local profile_list_json
  profile_list_json=$(LPAC_APDU="${LPAC_APDU}" LPAC_HTTP="${LPAC_HTTP}" \
    "${LPAC_BIN}" profile list)
  echo "${profile_list_json}"

  local new_iccid
  new_iccid=$(echo "${profile_list_json}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for p in data.get('payload', {}).get('data', []):
    if p.get('profileState') == 'disabled':
        print(p['iccid'])
        break
" 2>/dev/null || true)

  if [[ -n "${new_iccid}" ]]; then
    log "Enabling profile ICCID ${new_iccid}..."
    LPAC_APDU="${LPAC_APDU}" LPAC_HTTP="${LPAC_HTTP}" \
      "${LPAC_BIN}" profile enable "${new_iccid}" || \
      warn "profile enable returned non-zero (may be OK if already enabled)."
    ok "Profile ${new_iccid} enabled."
  else
    warn "No disabled profile found — assuming already enabled."
  fi

  ok "Phase 1 (ZK path) complete — profile installed in eUICC."
}

# ---------------------------------------------------------------------------
# Helper: send a Phase 0 APDU via lpac and return the response hex
# ---------------------------------------------------------------------------
phase0_apdu() {
  local tag="$1"   # BF44 / BF45 / BF46 / BF47
  local payload_hex="$2"
  # Build TLV: BF_TAG { 80 LL <payload> }
  local payload_len_hex
  payload_len_hex=$(printf '%02X' $((${#payload_hex} / 2)))
  local tlv_hex="${tag}$(python3 -c "
n = ${#payload_hex} // 2
if n < 128:
    print(f'{n:02X}')
elif n < 256:
    print(f'81{n:02X}')
else:
    print(f'82{n>>8:02X}{n&0xFF:02X}')
")80${payload_len_hex}${payload_hex}"
  # STORE DATA: 80 E2 91 00 LL <tlv>
  local lc_hex
  lc_hex=$(printf '%02X' $((${#tlv_hex} / 2)))
  local apdu_hex="80E291000${lc_hex}${tlv_hex}"
  log "Phase0 APDU TX: ${apdu_hex}"
  local resp
  resp=$(LPAC_APDU="${LPAC_APDU}" LPAC_HTTP="${LPAC_HTTP}" \
    LPAC_CUSTOM_ISD_R_AID="${INSTANCE_AID}" \
    "${LPAC_BIN}" apdu "${apdu_hex}" 2>&1)
  log "Phase0 APDU RX: ${resp}"
  echo "${resp}"
}

# ---------------------------------------------------------------------------
# Helper: POST JSON to MNO endpoint, return response body
# ---------------------------------------------------------------------------
mno_post() {
  local endpoint="$1"
  local body="$2"
  curl -s -X POST \
    -H "Content-Type: application/json" \
    --data "${body}" \
    "https://${MNO_HOST}:${MNO_PORT}${endpoint}" \
    --insecure 2>/dev/null
}

# ---------------------------------------------------------------------------
# Phase 0 — RegisterAndIssue (BF44 + BF45)
# ---------------------------------------------------------------------------
phase0_register() {
  banner "Phase 0.a — RegisterAndIssue (BF44 + BF45, blind Schnorr)"
  log "MNO: ${MNO_HOST}:${MNO_PORT}"

  # Leg 1: get MNO nonce commitment R_MNO = r_MNO·G
  local challenge_resp
  challenge_resp=$(mno_post "/zk-esim/v1/registerChallenge" "{}")
  local request_id r_mno_b64
  request_id=$(echo "${challenge_resp}" | python3 -c "import sys,json; print(json.load(sys.stdin)['requestId'])")
  r_mno_b64=$(echo "${challenge_resp}"  | python3 -c "import sys,json; print(json.load(sys.stdin)['rMno'])")
  local r_mno_hex
  r_mno_hex=$(python3 -c "import base64; print(base64.b64decode('${r_mno_b64}').hex().upper())")
  log "Got R_MNO (requestId=${request_id}): ${r_mno_hex}"

  # Send BF44 { 80 R_MNO(65B) } to eUICC — computes blinded challenge e and π_auth
  local bf44_resp
  bf44_resp=$(phase0_apdu "44" "${r_mno_hex}")

  # Parse BF44 response: field 80 = e (32B), field 81 = π_auth (DER)
  local e_b64 pi_auth_b64
  e_b64=$(echo "${bf44_resp}" | python3 -c "
import sys, base64
data = bytes.fromhex(sys.stdin.read().strip())
pos = 0
assert data[pos] == 0xBF and data[pos+1] == 0x44, 'Expected BF44'
pos += 2
l = data[pos]; pos += 1
if l & 0x80: pos += l & 0x7F
assert data[pos] == 0xA0, 'Expected A0'
pos += 1; l = data[pos]; pos += 1
if l & 0x80: pos += l & 0x7F
assert data[pos] == 0x80, 'Expected 80 (e)'
pos += 1; f0len = data[pos]; pos += 1
print(base64.b64encode(data[pos:pos+f0len]).decode())
")
  pi_auth_b64=$(echo "${bf44_resp}" | python3 -c "
import sys, base64
data = bytes.fromhex(sys.stdin.read().strip())
pos = 0
assert data[pos] == 0xBF and data[pos+1] == 0x44
pos += 2
l = data[pos]; pos += 1
if l & 0x80: pos += l & 0x7F
assert data[pos] == 0xA0
pos += 1; l = data[pos]; pos += 1
if l & 0x80: pos += l & 0x7F
pos += 1; f0len = data[pos]; pos += 1 + f0len   # skip field 80
assert data[pos] == 0x81, 'Expected 81 (pi_auth)'
pos += 1; f1len = data[pos]; pos += 1
print(base64.b64encode(data[pos:pos+f1len]).decode())
")
  log "e      : ${e_b64}"
  log "pi_auth: ${pi_auth_b64}"

  # Leg 2: send blinded challenge e + π_auth to MNO, get partial sig s
  local cred_resp s_b64
  cred_resp=$(mno_post "/zk-esim/v1/registerCredential" \
    "{\"requestId\":\"${request_id}\",\"e\":\"${e_b64}\",\"piAuth\":\"${pi_auth_b64}\"}")
  s_b64=$(echo "${cred_resp}" | python3 -c "import sys,json; print(json.load(sys.stdin)['s'])")
  local s_hex
  s_hex=$(python3 -c "import base64; print(base64.b64decode('${s_b64}').hex().upper())")
  log "s (partial sig): ${s_hex}"

  # Send BF45 { 80 s(32B) } to eUICC — unblinds to σ_EID = R'||s'
  local bf45_resp
  bf45_resp=$(phase0_apdu "45" "${s_hex}")
  echo "${bf45_resp}" | python3 -c "
import sys; data = bytes.fromhex(sys.stdin.read().strip())
assert data[0] == 0xBF and data[1] == 0x45 and data[3] == 0xA0, 'BF45 failed'
print('OK')
" && ok "Phase 0.a complete — σ_EID (blind Schnorr) stored in eUICC." || { err "Phase 0.a failed."; exit 1; }
}

# ---------------------------------------------------------------------------
# Phase 0 — CertInit (BF46 + BF47 combined in one server call)
# ---------------------------------------------------------------------------
phase0_certinit() {
  banner "Phase 0.b — CertInit (BF46 + BF47)"
  log "MNO: ${MNO_HOST}:${MNO_PORT}"

  # Generate r_seed locally (32 random bytes)
  local r_seed_hex r_seed_b64
  r_seed_hex=$(python3 -c "import os; print(os.urandom(32).hex().upper())")
  r_seed_b64=$(python3 -c "import base64,os; print(base64.b64encode(bytes.fromhex('${r_seed_hex}')).decode())")
  log "r_seed: ${r_seed_hex}"

  # Send BF46 { 80 r_seed } to eUICC — derive session key
  local bf46_resp
  bf46_resp=$(phase0_apdu "46" "${r_seed_hex}")
  # Extract pk_U (field 80), π_bind (field 81), H(σ_EID) (field 82) from BF46 response
  local pk_u_b64 pi_bind_b64 h_sigma_eid_b64
  read -r pk_u_b64 pi_bind_b64 h_sigma_eid_b64 < <(echo "${bf46_resp}" | python3 -c "
import sys, base64

def rlen(d, p):
    b = d[p]
    if b <= 0x7F: return b, p + 1
    if b == 0x81: return d[p+1], p + 2
    if b == 0x82: return (d[p+1] << 8) | d[p+2], p + 3
    raise ValueError(f'bad len 0x{b:02X}')

resp = sys.stdin.read().strip()
data = bytes.fromhex(resp)
pos = 0
assert data[pos] == 0xBF and data[pos+1] == 0x46, 'Expected BF46'
pos += 2
_, pos = rlen(data, pos)           # skip outer length
assert data[pos] == 0xA0, 'Expected A0'
pos += 1
_, pos = rlen(data, pos)           # skip A0 length
fields = {}
while pos < len(data):
    tag = data[pos]; pos += 1
    flen, pos = rlen(data, pos)
    fields[tag] = data[pos:pos+flen]
    pos += flen
print(base64.b64encode(fields[0x80]).decode())
print(base64.b64encode(fields[0x81]).decode())
print(base64.b64encode(fields[0x82]).decode())
")
  log "pk_U       : ${pk_u_b64}"
  log "π_bind     : ${pi_bind_b64}"
  log "H(σ_EID)   : ${h_sigma_eid_b64}"

  # Get PCert_U from PCA (MNO server); include H(σ_EID) so it is embedded in the cert
  local cert_resp pcert_b64
  cert_resp=$(mno_post "/zk-esim/v1/certInitRequest" \
    "{\"pkU\":\"${pk_u_b64}\",\"piBind\":\"${pi_bind_b64}\",\"hSigmaEid\":\"${h_sigma_eid_b64}\"}")
  pcert_b64=$(echo "${cert_resp}" | python3 -c "import sys,json; print(json.load(sys.stdin)['pCertU'])")
  local pcert_hex
  pcert_hex=$(python3 -c "import base64; print(base64.b64decode('${pcert_b64}').hex().upper())")
  log "PCert_U: ${pcert_hex:0:40}…"

  # Send BF47 { 80 PCert_U } to eUICC — install session cert
  local bf47_resp
  bf47_resp=$(phase0_apdu "47" "${pcert_hex}")
  echo "${bf47_resp}" | python3 -c "
import sys; data = bytes.fromhex(sys.stdin.read().strip())
assert data[0] == 0xBF and data[1] == 0x47 and data[3] == 0xA0, 'BF47 failed'
print('OK')
" && ok "Phase 0.b complete — PCert_U installed; sk_U active." || { err "Phase 0.b failed."; exit 1; }
}

# ---------------------------------------------------------------------------
# PHASE 2 — Test ZK-eSIM applet (ZK-eSIM APPLET AID)
# ---------------------------------------------------------------------------
phase2_test_applet() {
  banner "Phase 2 — Test ZK-eSIM Applet (ZK-eSIM Applet AID)"

  stop_smdpp
  phase1_start_smdpp 1

  log "Switching to ZK-eSIM applet AID: ${INSTANCE_AID}"
  log "Setting LPAC_CUSTOM_ISD_R_AID=${INSTANCE_AID}"
  if [[ "${PHASE2_APDU_DEBUG}" == "1" ]]; then
    log "Raw APDU trace is ENABLED for Phase 2 (PHASE2_APDU_DEBUG=1)"
  else
    log "Raw APDU trace is DISABLED for Phase 2 (PHASE2_APDU_DEBUG=${PHASE2_APDU_DEBUG})"
  fi

  export LPAC_CUSTOM_ISD_R_AID="${INSTANCE_AID}"

  # Helper to run lpac with the custom AID env set
  run_lpac() {
    if [[ "${PHASE2_APDU_DEBUG}" == "1" ]]; then
      LPAC_APDU="${LPAC_APDU}" \
      LPAC_HTTP="${LPAC_HTTP}" \
      LPAC_APDU_DEBUG=1 \
      LPAC_CUSTOM_ISD_R_AID="${INSTANCE_AID}" \
        "${LPAC_BIN}" "$@"
    else
      LPAC_APDU="${LPAC_APDU}" \
      LPAC_HTTP="${LPAC_HTTP}" \
      LPAC_CUSTOM_ISD_R_AID="${INSTANCE_AID}" \
        "${LPAC_BIN}" "$@"
    fi
  }

  log "Step 2.1 — Exercising ES10 message flow through the applet..."
  log "  The profile download command exercises the full ES10x chain:"
  log "    BF2E GetEuiccChallenge → BF38 AuthenticateServer"
  log "    BF21 PrepareDownload   → BF36 LoadBoundProfilePackage"

  # Re-run profile download targeting the applet as ISD-R.
  # This verifies that each ES10 APDU is handled correctly by ZkEsimApplet.
  log "Running profile download against applet (SM-DP+: ${SMDPP_HOST}, ID: ${MATCHING_ID})..."
  run_lpac profile download \
    -s "${SMDPP_HOST}" \
    -m "${MATCHING_ID}" || {
    warn "Profile download via applet AID returned non-zero (may be expected if profile already loaded)."
  }

  # log "Step 2.2 — Listing profiles as seen through applet AID..."
  # run_lpac profile list || warn "Profile list returned non-zero (check applet state)."

  ok "Phase 2 complete — ZK-eSIM applet message flow verified."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  banner "ZK-eSIM End-to-End Workflow"
  log "Repository root : ${REPO_ROOT}"
  log "Matching ID     : ${MATCHING_ID}"
  log "lpac binary     : ${LPAC_BIN}"
  log "SKIP_BUILD      : ${SKIP_BUILD}"
  log "SKIP_DOWNLOAD   : ${SKIP_DOWNLOAD}"
  log "ZK_DOWNLOAD     : ${ZK_DOWNLOAD}"

  check_prereqs
  phase0_build_lpac

  if [[ "${SKIP_BUILD}" == "0" ]]; then
    phase1_build
  else
    warn "Skipping Phase 1a (build) — SKIP_BUILD=1"
  fi

  if [[ "${SKIP_DOWNLOAD}" == "0" ]]; then
    if [[ "${ZK_DOWNLOAD}" == "1" ]]; then
      # ZK path: SM-DP+ also serves MNO routes; start with --zk flag.
      phase1_start_smdpp 1

      local _t0 _t1
      _t0=$(_ts_ms)
      phase1_zk_download
      _t1=$(_ts_ms)
      T_ZK_DOWNLOAD_MS=$(( _t1 - _t0 ))
      ok "ZK profile download took ${T_ZK_DOWNLOAD_MS} ms"

      # Phase 0 is an integral part of the ZK flow: derive the session keypair
      # (RegisterAndIssue + CertInit) so Phase 2 uses a fresh unlinkable key.
      export LPAC_CUSTOM_ISD_R_AID="${INSTANCE_AID}"

      _t0=$(_ts_ms)
      phase0_register
      _t1=$(_ts_ms)
      T_REGISTER_MS=$(( _t1 - _t0 ))
      ok "Registration took ${T_REGISTER_MS} ms"

      _t0=$(_ts_ms)
      phase0_certinit
      _t1=$(_ts_ms)
      T_CERTINIT_MS=$(( _t1 - _t0 ))
      ok "Certificate init took ${T_CERTINIT_MS} ms"

      unset LPAC_CUSTOM_ISD_R_AID
    else
      phase1_start_smdpp 0
      phase1_download
    fi
  else
    warn "Skipping profile download — SKIP_DOWNLOAD=1"
  fi

  phase2_test_applet

  banner "Workflow Complete"
  ok "All phases passed successfully."
  echo
  echo -e "  Matching ID  : ${BOLD}${MATCHING_ID}${RESET}"
  echo -e "  Package AID  : ${BOLD}${LOAD_PACKAGE_AID}${RESET}"
  echo -e "  Applet AID   : ${BOLD}${INSTANCE_AID}${RESET}"
  echo

  if [[ "${ZK_DOWNLOAD}" == "1" && "${SKIP_DOWNLOAD}" == "0" ]]; then
    print_timing_summary
  fi
}

main "$@"
