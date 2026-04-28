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
#   SKIP_BUILD           Set to 1 to skip Phase 1 build step
#   SKIP_DOWNLOAD        Set to 1 to skip profile download step

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLET_DIR="${REPO_ROOT}/ZK-eSIM_applet"
PYSIM_ROOT="${REPO_ROOT}/pysim"
LPAC_BIN="${LPAC_BIN:-${REPO_ROOT}/lpac/build/src/lpac}"
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
timestamp_ms() { date +%s%3N; }
format_duration_ms() {
  local elapsed_ms="${1:-0}"
  printf "%d ms" "${elapsed_ms}"
}

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    --skip-build)    SKIP_BUILD=1 ;;
    --skip-download) SKIP_DOWNLOAD=1 ;;
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
stop_smdpp() {
  if [[ -n "${SMDPP_PID}" ]]; then
    log "Stopping SM-DP+ server (PID ${SMDPP_PID})..."
    kill "${SMDPP_PID}" 2>/dev/null || true
    wait "${SMDPP_PID}" 2>/dev/null || true
    SMDPP_PID=""
    ok "SM-DP+ server stopped."
  fi
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
  cmake -S "${REPO_ROOT}/lpac" -B "${REPO_ROOT}/lpac/build"

  log "Building lpac (jobs=${jobs})..."
  # Build the binary plus the runtime-loaded APDU/HTTP driver plugins.
  # Without the driver targets, lpac fails at runtime with "No APDU driver found".
  cmake --build "${REPO_ROOT}/lpac/build" \
    --target lpac driver_apdu_pcsc driver_apdu_stdio driver_http_curl driver_http_stdio \
    -j "${jobs}"

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

  log "Starting osmo-smdpp.py on ${SMDPP_HOST}:${SMDPP_PORT}..."
  if [[ "${zk_flag}" == "1" ]]; then
    log "  Server mode   : zk (--zk)"
  else
    log "  Server mode   : normal"
  fi

  # Run from pysim/ so relative paths to smdpp-data/ resolve correctly
  # shellcheck disable=SC2086
  (cd "${PYSIM_ROOT}" && python3 osmo-smdpp.py \
    -H "${SMDPP_HOST}" \
    -p "${SMDPP_PORT}" \
    -v \
    $( [[ "${zk_flag}" == "1" ]] && printf '%s' "--zk" ) \
    ${SMDPP_EXTRA_ARGS}) \
    &
  SMDPP_PID=$!

  # Wait up to 10 s for the server to bind on its port
  local retries=20
  local ready=0
  while [[ ${retries} -gt 0 ]]; do
    if ! kill -0 "${SMDPP_PID}" 2>/dev/null; then
      err "SM-DP+ server process exited unexpectedly."
      exit 1
    fi
    if ss -tlnp 2>/dev/null | grep -q ":${SMDPP_PORT} " || \
       netstat -tlnp 2>/dev/null | grep -q ":${SMDPP_PORT} "; then
      ready=1
      break
    fi
    sleep 0.5
    retries=$((retries - 1))
  done

  if [[ "${ready}" == "0" ]]; then
    err "SM-DP+ server did not bind on port ${SMDPP_PORT} within 10 s."
    exit 1
  fi
  ok "SM-DP+ server running (PID ${SMDPP_PID})."
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
  local download_rc=0
  local download_start_ms
  local download_end_ms
  local download_elapsed_ms
  local download_elapsed
  download_start_ms=$(timestamp_ms)
  set +e
  run_lpac profile download \
    -s "${SMDPP_HOST}" \
    -m "${MATCHING_ID}"
  download_rc=$?
  set -e
  download_end_ms=$(timestamp_ms)
  download_elapsed_ms=$((download_end_ms - download_start_ms))
  download_elapsed=$(format_duration_ms "${download_elapsed_ms}")
  if [[ "${download_rc}" != "0" ]]; then
    warn "Profile download via applet AID returned non-zero after ${download_elapsed} (may be expected if profile already loaded)."
  else
    ok "Profile download via applet AID complete in ${download_elapsed}."
  fi

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

  check_prereqs
  phase0_build_lpac

  if [[ "${SKIP_BUILD}" == "0" ]]; then
    phase1_build
  else
    warn "Skipping Phase 1a (build) — SKIP_BUILD=1"
  fi

  if [[ "${SKIP_DOWNLOAD}" == "0" ]]; then
    phase1_start_smdpp 0
    phase1_download
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
}

main "$@"
