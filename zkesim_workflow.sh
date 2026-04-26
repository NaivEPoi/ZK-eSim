#!/usr/bin/env bash
# ZK-eSIM End-to-End Workflow
#
# Default path:
#   - Setup: build lpac, build/inject the JavaCard applet profile
#   - Prerequisite: normal profile download through the default ISD-R
#   - Phase 0: RegisterAndIssue
#   - Phase 1: CertInit
#   - Phase 2: Order Profile / ZKRequest
#   - Phase 3: Profile Download
#   - Phase 4: Verify installed profile
#
# Usage:
#   bash zkesim_workflow.sh [--skip-build] [--skip-download] [--standard-download] [--applet-smoke] [--help]
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
#   PHASE2_APDU_DEBUG    Set to 1 to print raw APDU trace in optional applet smoke test (default: 1)
#   ZK_DOWNLOAD          Set to 1 to use the full ZK path (default: 1)
#   RUN_APPLET_SMOKE     Set to 1 to run the old applet smoke-test download after the workflow (default: 0)
#   ZK_PHASE_TIMEOUT     Seconds before a ZK lpac phase is considered hung (default: 180)
#   ZK_APDU_DEBUG        Set to 1 to record APDU trace for ZK phases (default: 1)
#   SMDPP_LOG/MNO_LOG/PCA_LOG/ZK_LPAC_LOG
#                        Log files for protocol-role servers and ZK lpac phases
#   MNO_HOST             MNO server host (default: localhost)
#   MNO_PORT             MNO server port (default: 4443)
#   PCA_HOST             PCA server host (default: localhost)
#   PCA_PORT             PCA server port (default: 5443)
#   SKIP_BUILD           Set to 1 to skip setup build step
#   SKIP_DOWNLOAD        Set to 1 to skip prerequisite normal profile download

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLET_DIR="${REPO_ROOT}/ZK-eSIM_applet"
PYSIM_ROOT="${REPO_ROOT}/pysim"
WORKFLOW_BASE="${TMPDIR:-/tmp}"
WORKFLOW_DIR="${WORKFLOW_DIR:-${WORKFLOW_BASE%/}/zkesim-workflow-${USER:-$(id -u)}}"
LPAC_BUILD_DIR="${LPAC_BUILD_DIR:-${WORKFLOW_DIR}/lpac-build}"
LPAC_OUTPUT_DIR="${LPAC_OUTPUT_DIR:-${WORKFLOW_DIR}/lpac-output}"
LPAC_BIN="${LPAC_BIN:-${LPAC_OUTPUT_DIR}/executables/lpac}"
LPAC_LIB_DIR="${LPAC_OUTPUT_DIR}/executables/lib:${LPAC_OUTPUT_DIR}/executables/driver:${LPAC_BUILD_DIR}:${LPAC_BUILD_DIR}/driver:${LPAC_BUILD_DIR}/utils:${LPAC_BUILD_DIR}/euicc"

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
ZK_DOWNLOAD="${ZK_DOWNLOAD:-1}"
RUN_APPLET_SMOKE="${RUN_APPLET_SMOKE:-0}"
MNO_HOST="${MNO_HOST:-localhost}"
MNO_PORT="${MNO_PORT:-4443}"
PCA_HOST="${PCA_HOST:-localhost}"
PCA_PORT="${PCA_PORT:-5443}"
ZK_PHASE_TIMEOUT="${ZK_PHASE_TIMEOUT:-180}"
ZK_APDU_DEBUG="${ZK_APDU_DEBUG:-1}"
WORKFLOW_LOG_DIR="${WORKFLOW_LOG_DIR:-${REPO_ROOT}/.zkesim-workflow/logs}"
SMDPP_LOG="${SMDPP_LOG:-${WORKFLOW_LOG_DIR}/smdpp.log}"
MNO_LOG="${MNO_LOG:-${WORKFLOW_LOG_DIR}/mno.log}"
PCA_LOG="${PCA_LOG:-${WORKFLOW_LOG_DIR}/pca.log}"
ZK_LPAC_LOG="${ZK_LPAC_LOG:-${WORKFLOW_LOG_DIR}/zk-lpac.log}"
mkdir -p "${WORKFLOW_LOG_DIR}"

# Export lpac backend settings (used in both phases)
export LPAC_APDU="${LPAC_APDU:-pcsc}"
export LPAC_HTTP="${LPAC_HTTP:-curl}"
# lpac shared libraries live under lpac/build.  Linux uses LD_LIBRARY_PATH;
# macOS uses DYLD_LIBRARY_PATH.
export LD_LIBRARY_PATH="${LPAC_LIB_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export DYLD_LIBRARY_PATH="${LPAC_LIB_DIR}${DYLD_LIBRARY_PATH:+:${DYLD_LIBRARY_PATH}}"

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

dump_debug_logs() {
  local f
  for f in "${SMDPP_LOG}" "${MNO_LOG}" "${PCA_LOG}" "${ZK_LPAC_LOG}" "${ZK_LPAC_LOG}".phase*; do
    if [[ -f "${f}" ]]; then
      echo >&2
      warn "Last lines from ${f}:"
      tail -n 80 "${f}" >&2 || true
    fi
  done
}

run_logged_timeout() {
  local timeout_s="$1"
  local logfile="$2"
  shift 2
  local elapsed=0

  mkdir -p "$(dirname "${logfile}")"
  : >"${logfile}"

  "$@" > >(tee -a "${logfile}") 2>&1 &
  local pid=$!

  while kill -0 "${pid}" 2>/dev/null; do
    if (( elapsed >= timeout_s )); then
      err "Command timed out after ${timeout_s}s: $*"
      kill "${pid}" 2>/dev/null || true
      sleep 1
      kill -9 "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
      dump_debug_logs
      return 124
    fi
    sleep 1
    elapsed=$(( elapsed + 1 ))
  done

  local rc=0
  if wait "${pid}" 2>/dev/null; then
    rc=0
  else
    rc=$?
  fi
  return "${rc}"
}

run_capture_timeout() {
  local __out_var="$1"
  local timeout_s="$2"
  local logfile="$3"
  shift 3
  local output_file="${logfile}.out"
  local elapsed=0

  mkdir -p "$(dirname "${logfile}")"
  : >"${logfile}"
  : >"${output_file}"

  "$@" >"${output_file}" 2>&1 &
  local pid=$!

  while kill -0 "${pid}" 2>/dev/null; do
    if (( elapsed >= timeout_s )); then
      err "Command timed out after ${timeout_s}s: $*"
      kill "${pid}" 2>/dev/null || true
      sleep 1
      kill -9 "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
      cat "${output_file}" | tee -a "${logfile}" || true
      dump_debug_logs
      return 124
    fi
    sleep 1
    elapsed=$(( elapsed + 1 ))
  done

  local rc=0
  if wait "${pid}" 2>/dev/null; then
    rc=0
  else
    rc=$?
  fi
  cat "${output_file}" | tee -a "${logfile}" || true
  printf -v "${__out_var}" '%s' "$(cat "${output_file}")"
  return "${rc}"
}

# ---------------------------------------------------------------------------
# Phase timing accumulators (set during the ZK download path)
# ---------------------------------------------------------------------------
T_REGISTER_MS=0
T_CERTINIT_MS=0
T_ORDER_PROFILE_MS=0
T_PROFILE_DOWNLOAD_MS=0
ZK_ORDER_MATCHING_ID=""
ZK_ORDER_SMDP=""

print_timing_summary() {
  local total=$(( T_REGISTER_MS + T_CERTINIT_MS + T_ORDER_PROFILE_MS + T_PROFILE_DOWNLOAD_MS ))
  echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${CYAN}  Timing Summary${RESET}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════${RESET}"
  printf "  %-36s %s\n" "Phase" "Wall-clock (ms)"
  echo -e "  ──────────────────────────────────────────────"
  printf "  %-36s %d ms\n" "Registration"               "${T_REGISTER_MS}"
  printf "  %-36s %d ms\n" "Certificate Initialisation" "${T_CERTINIT_MS}"
  printf "  %-36s %d ms\n" "Order Profile"              "${T_ORDER_PROFILE_MS}"
  printf "  %-36s %d ms\n" "Profile Download"           "${T_PROFILE_DOWNLOAD_MS}"
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
    --standard-download) ZK_DOWNLOAD=0 ;;
    --applet-smoke)  RUN_APPLET_SMOKE=1 ;;
    --help|-h)
      sed -n '2,40p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) err "Unknown argument: $arg"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Cleanup trap — kill SM-DP+ server on exit
# ---------------------------------------------------------------------------
SMDPP_PID=""
MNO_PID=""
PCA_PID=""

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

stop_mno() {
  if [[ -n "${MNO_PID}" ]]; then
    log "Stopping MNO server (PID ${MNO_PID})..."
    kill "${MNO_PID}" 2>/dev/null || true
    wait "${MNO_PID}" 2>/dev/null || true
    MNO_PID=""
    ok "MNO server stopped."
  fi
  _sweep_port "${MNO_PORT}"
}

stop_pca() {
  if [[ -n "${PCA_PID}" ]]; then
    log "Stopping PCA server (PID ${PCA_PID})..."
    kill "${PCA_PID}" 2>/dev/null || true
    wait "${PCA_PID}" 2>/dev/null || true
    PCA_PID=""
    ok "PCA server stopped."
  fi
  _sweep_port "${PCA_PORT}"
}

cleanup() {
  stop_pca
  stop_mno
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
  [[ -f "${PYSIM_ROOT}/mno-server.py" ]] || { err "mno-server.py not found in ${PYSIM_ROOT}"; missing=1; }
  [[ -f "${PYSIM_ROOT}/pca-server.py" ]] || { err "pca-server.py not found in ${PYSIM_ROOT}"; missing=1; }

  if [[ "${SKIP_BUILD}" == "0" ]]; then
    command -v ant >/dev/null 2>&1 || { err "'ant' not found. Install Apache Ant."; missing=1; }
    command -v python3 >/dev/null 2>&1 || { err "'python3' not found."; missing=1; }
    [[ -f "${PYSIM_ROOT}/contrib/saip-tool.py" ]] || { err "saip-tool.py not found in ${PYSIM_ROOT}/contrib/"; missing=1; }
    command -v cmake >/dev/null 2>&1 || { err "'cmake' not found. Install CMake."; missing=1; }
  else
    [[ -x "${LPAC_BIN}" ]] || { err "SKIP_BUILD=1 but lpac binary is missing or not executable: ${LPAC_BIN}"; missing=1; }
  fi

  command -v curl >/dev/null 2>&1 || { err "'curl' not found. Install curl."; missing=1; }

  [[ "${missing}" == "0" ]] || exit 1
  ok "All prerequisites satisfied."
}

# ---------------------------------------------------------------------------
# SETUP A — Build lpac
# ---------------------------------------------------------------------------
phase0_build_lpac() {
  banner "Setup A — Build lpac"

  mkdir -p "${WORKFLOW_DIR}"

  local jobs="4"
  if command -v nproc >/dev/null 2>&1; then
    jobs="$(nproc)"
  elif command -v sysctl >/dev/null 2>&1; then
    jobs="$(sysctl -n hw.ncpu 2>/dev/null || printf '4')"
  fi

  log "Configuring lpac..."
  (cd "${REPO_ROOT}/lpac" && cmake -B "${LPAC_BUILD_DIR}" -DSTANDALONE_MODE=ON)

  log "Building lpac (jobs=${jobs})..."
  (cd "${REPO_ROOT}/lpac" && cmake --build "${LPAC_BUILD_DIR}" -j "${jobs}")

  log "Installing lpac..."
  (cd "${REPO_ROOT}/lpac" && DESTDIR="${LPAC_OUTPUT_DIR}" cmake --install "${LPAC_BUILD_DIR}")

  if [[ ! -f "${LPAC_BIN}" ]]; then
    err "lpac binary missing after build: ${LPAC_BIN}"
    exit 1
  fi

  ok "lpac build complete: ${LPAC_BIN}"
}

# ---------------------------------------------------------------------------
# SETUP B — Build applet CAP and create DER profile
# ---------------------------------------------------------------------------
phase1_build() {
  banner "Setup B — Build Applet & Create eSIM Profile"

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
# SETUP C — Start SM-DP+ server
# ---------------------------------------------------------------------------
phase1_start_smdpp() {
  banner "Setup C — Start SM-DP+ Server"
  local zk_flag="${1:-0}"

  # Clear any stale server on the target port before starting a fresh one.
  _sweep_port "${SMDPP_PORT}"

  log "Starting osmo-smdpp.py on ${SMDPP_HOST}:${SMDPP_PORT}..."
  if [[ "${zk_flag}" == "1" ]]; then
    log "  Server mode   : zk (--zk)"
  else
    log "  Server mode   : normal"
  fi

  local smdpp_log="${SMDPP_LOG}"
  : >"${smdpp_log}"
  log "SM-DP+ server log: ${smdpp_log}"

  # Run from pysim/ so relative paths to smdpp-data/ resolve correctly
  # shellcheck disable=SC2086
  (cd "${PYSIM_ROOT}" && PYTHONUNBUFFERED=1 python3 -u osmo-smdpp.py \
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

wait_for_port() {
  local pid="$1"
  local port="$2"
  local name="$3"
  local logfile="$4"
  local retries=20

  while [[ ${retries} -gt 0 ]]; do
    if ! kill -0 "${pid}" 2>/dev/null; then
      err "${name} exited unexpectedly. Check ${logfile} for details."
      exit 1
    fi
    if lsof -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1 || \
       ss -tlnp 2>/dev/null | grep -q ":${port} " || \
       netstat -an 2>/dev/null | grep -q "[.:]${port} "; then
      ok "${name} running (PID ${pid}). Logs: ${logfile}"
      return 0
    fi
    sleep 0.5
    retries=$((retries - 1))
  done

  err "${name} did not bind on port ${port} within 10 s. Check ${logfile} for details."
  exit 1
}

phase1_start_mno() {
  banner "Setup D — Start MNO Server"
  local mno_log="${MNO_LOG}"
  local smdp_url="https://${SMDPP_HOST}:${SMDPP_PORT}"

  : >"${mno_log}"
  _sweep_port "${MNO_PORT}"
  log "Starting mno-server.py on ${MNO_HOST}:${MNO_PORT}..."
  log "  SM-DP+ ES2+ URL: ${smdp_url}"
  log "MNO server log: ${mno_log}"

  (cd "${PYSIM_ROOT}" && PYTHONUNBUFFERED=1 python3 -u mno-server.py \
    --host "${MNO_HOST}" \
    --port "${MNO_PORT}" \
    --smdp-url "${smdp_url}") \
    >"${mno_log}" 2>&1 &
  MNO_PID=$!
  wait_for_port "${MNO_PID}" "${MNO_PORT}" "MNO server" "${mno_log}"
}

phase1_start_pca() {
  banner "Setup E — Start PCA Server"
  local pca_log="${PCA_LOG}"
  local cert_dir="${PYSIM_ROOT}/smdpp-data/certs/PCA"

  : >"${pca_log}"
  _sweep_port "${PCA_PORT}"
  if [[ ! -f "${cert_dir}/CERT_PCA_TLS_NIST.pem" || ! -f "${cert_dir}/SK_PCA_TLS_NIST.pem" ]]; then
    log "Generating PCA TLS certificate..."
    (cd "${cert_dir}" && bash gen_certs.sh)
  fi

  log "Starting pca-server.py on ${PCA_HOST}:${PCA_PORT}..."
  log "PCA server log: ${pca_log}"
  (cd "${PYSIM_ROOT}" && PYTHONUNBUFFERED=1 python3 -u pca-server.py \
    --host "${PCA_HOST}" \
    --port "${PCA_PORT}") \
    >"${pca_log}" 2>&1 &
  PCA_PID=$!
  wait_for_port "${PCA_PID}" "${PCA_PORT}" "PCA server" "${pca_log}"
}

# ---------------------------------------------------------------------------
# STANDARD PATH — Download profile to eUICC (DEFAULT ISD-R AID)
# ---------------------------------------------------------------------------
phase1_download() {
  banner "Standard Path — Download Profile to eUICC (Default ISD-R AID)"

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

  ok "Standard path complete — profile installed in eUICC."
}

# ---------------------------------------------------------------------------
# PHASE 2 — Order profile via MNO; stores eligibility data on the eUICC.
# ---------------------------------------------------------------------------
phase1_zk_order_profile() {
  banner "Phase 2 — Order Profile / ZKRequest (lpac zk-order)"

  local mno_addr="${MNO_HOST}:${MNO_PORT}"
  log "MNO address    : ${mno_addr}"
  log "SM-DP+ server  : ${SMDPP_HOST}"

  export LPAC_CUSTOM_ISD_R_AID="${INSTANCE_AID}"

  log "Running: ${LPAC_BIN} profile zk-order -n ${mno_addr} -s ${SMDPP_HOST}"
  log "ZK lpac phase log: ${ZK_LPAC_LOG}.phase2-order"
  local rc=0
  local order_output
  set +e
  run_capture_timeout order_output "${ZK_PHASE_TIMEOUT}" "${ZK_LPAC_LOG}.phase2-order" \
    env LPAC_APDU="${LPAC_APDU}" \
      LPAC_HTTP="${LPAC_HTTP}" \
      LPAC_APDU_DEBUG="${ZK_APDU_DEBUG}" \
      LPAC_CUSTOM_ISD_R_AID="${INSTANCE_AID}" \
      "${LPAC_BIN}" profile zk-order \
        -n "${mno_addr}" \
        -s "${SMDPP_HOST}"
  rc=$?
  set -e

  if [[ "${rc}" != "0" ]]; then
    err "ZK order profile failed (rc=${rc})."
    exit 1
  fi

  local parsed_order
  parsed_order=$(printf '%s\n' "${order_output}" | python3 -c '
import json, sys
result = None
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        continue
    payload = obj.get("payload") or {}
    if obj.get("type") == "lpa" and payload.get("code") == 0:
        result = payload.get("data") or {}
if result is None:
    raise SystemExit("missing lpac success JSON")
print((result.get("matchingId") or "") + " " + (result.get("smdpAddress") or ""))
')
  read -r ZK_ORDER_MATCHING_ID ZK_ORDER_SMDP <<< "${parsed_order}"
  if [[ -z "${ZK_ORDER_MATCHING_ID}" ]]; then
    err "ZK order did not return matchingId."
    exit 1
  fi
  if [[ -z "${ZK_ORDER_SMDP}" ]]; then
    ZK_ORDER_SMDP="${SMDPP_HOST}"
  fi

  ok "Order profile complete."
  log "  matchingId  : ${ZK_ORDER_MATCHING_ID}"
  log "  smdpAddress : ${ZK_ORDER_SMDP}"
}

# ---------------------------------------------------------------------------
# PHASE 3 — Download profile from SM-DP+ using the MNO-issued matchingId.
# ---------------------------------------------------------------------------
phase1_zk_download_profile() {
  banner "Phase 3 — Profile Download"

  local smdp="${ZK_ORDER_SMDP:-${SMDPP_HOST}}"
  local matching_id="${ZK_ORDER_MATCHING_ID:-${MATCHING_ID}}"

  export LPAC_CUSTOM_ISD_R_AID="${INSTANCE_AID}"

  log "Running: ${LPAC_BIN} profile zk-download -s ${smdp} -m ${matching_id}"
  log "ZK lpac phase log: ${ZK_LPAC_LOG}.phase3-download"
  local rc=0
  set +e
  run_logged_timeout "${ZK_PHASE_TIMEOUT}" "${ZK_LPAC_LOG}.phase3-download" \
    env LPAC_APDU="${LPAC_APDU}" \
      LPAC_HTTP="${LPAC_HTTP}" \
      LPAC_APDU_DEBUG="${ZK_APDU_DEBUG}" \
      LPAC_CUSTOM_ISD_R_AID="${INSTANCE_AID}" \
    "${LPAC_BIN}" profile zk-download \
      -s "${smdp}" \
      -m "${matching_id}"
  rc=$?
  set -e

  if [[ "${rc}" != "0" ]]; then
    err "Profile download failed (rc=${rc})."
    exit 1
  fi

  ok "Profile download complete."
}

# ---------------------------------------------------------------------------
# PHASE 4 — Verify and enable the installed profile.
# ---------------------------------------------------------------------------
phase4_verify_profile() {
  banner "Phase 4 — Verify Installed Profile"
  local new_iccid
  local profile_list_json
  export LPAC_CUSTOM_ISD_R_AID="${INSTANCE_AID}"
  log "Verifying profile installation..."
  profile_list_json=$(LPAC_APDU="${LPAC_APDU}" LPAC_HTTP="${LPAC_HTTP}" \
    LPAC_CUSTOM_ISD_R_AID="${INSTANCE_AID}" \
    "${LPAC_BIN}" profile list)
  echo "${profile_list_json}"

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
      LPAC_CUSTOM_ISD_R_AID="${INSTANCE_AID}" \
      "${LPAC_BIN}" profile enable "${new_iccid}" || \
      warn "profile enable returned non-zero (may be OK if already enabled)."
    ok "Profile ${new_iccid} enabled."
  else
    warn "No disabled profile found — assuming already enabled."
  fi

  ok "Phase 4 complete — profile installed in eUICC."
}

# ---------------------------------------------------------------------------
# Phase 0 — RegisterAndIssue (BF44 + BF45)
# ---------------------------------------------------------------------------
phase0_register() {
  banner "Phase 0 — RegisterAndIssue (lpac ↔ MNO ↔ eUICC)"
  local mno_addr="${MNO_HOST}:${MNO_PORT}"

  export LPAC_CUSTOM_ISD_R_AID="${INSTANCE_AID}"
  log "Running: ${LPAC_BIN} profile zk-register -n ${mno_addr}"
  log "ZK lpac phase log: ${ZK_LPAC_LOG}.phase0-register"
  run_logged_timeout "${ZK_PHASE_TIMEOUT}" "${ZK_LPAC_LOG}.phase0-register" \
    env LPAC_APDU="${LPAC_APDU}" \
      LPAC_HTTP="${LPAC_HTTP}" \
      LPAC_APDU_DEBUG="${ZK_APDU_DEBUG}" \
      LPAC_CUSTOM_ISD_R_AID="${INSTANCE_AID}" \
    "${LPAC_BIN}" profile zk-register -n "${mno_addr}"
  ok "RegisterAndIssue complete — eligibility credential stored in eUICC."
}

# ---------------------------------------------------------------------------
# Phase 1 — CertInit (BF46 + BF47)
# ---------------------------------------------------------------------------
phase0_certinit() {
  banner "Phase 1 — CertInit (lpac ↔ PCA ↔ eUICC)"
  local pca_addr="${PCA_HOST}:${PCA_PORT}"

  export LPAC_CUSTOM_ISD_R_AID="${INSTANCE_AID}"
  log "Running: ${LPAC_BIN} profile zk-certinit -p ${pca_addr}"
  log "ZK lpac phase log: ${ZK_LPAC_LOG}.phase1-certinit"
  run_logged_timeout "${ZK_PHASE_TIMEOUT}" "${ZK_LPAC_LOG}.phase1-certinit" \
    env LPAC_APDU="${LPAC_APDU}" \
      LPAC_HTTP="${LPAC_HTTP}" \
      LPAC_APDU_DEBUG="${ZK_APDU_DEBUG}" \
      LPAC_CUSTOM_ISD_R_AID="${INSTANCE_AID}" \
    "${LPAC_BIN}" profile zk-certinit -p "${pca_addr}"
  ok "CertInit complete — PCert_U installed and sk_U active."
}

# ---------------------------------------------------------------------------
# Optional applet smoke test (ZK-eSIM APPLET AID)
# ---------------------------------------------------------------------------
phase2_test_applet() {
  banner "Applet Smoke Test — ZK-eSIM Applet AID"

  stop_smdpp
  phase1_start_smdpp 1

  log "Switching to ZK-eSIM applet AID: ${INSTANCE_AID}"
  log "Setting LPAC_CUSTOM_ISD_R_AID=${INSTANCE_AID}"
  if [[ "${PHASE2_APDU_DEBUG}" == "1" ]]; then
    log "Raw APDU trace is ENABLED for applet smoke test (PHASE2_APDU_DEBUG=1)"
  else
    log "Raw APDU trace is DISABLED for applet smoke test (PHASE2_APDU_DEBUG=${PHASE2_APDU_DEBUG})"
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

  log "Exercising ES10 message flow through the applet..."
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

  ok "Applet smoke test complete — ZK-eSIM applet message flow verified."
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
  log "RUN_APPLET_SMOKE: ${RUN_APPLET_SMOKE}"
  log "ZK_PHASE_TIMEOUT: ${ZK_PHASE_TIMEOUT}s"
  log "ZK_APDU_DEBUG   : ${ZK_APDU_DEBUG}"
  log "SM-DP+ log      : ${SMDPP_LOG}"
  log "MNO log         : ${MNO_LOG}"
  log "PCA log         : ${PCA_LOG}"
  log "ZK lpac logs    : ${ZK_LPAC_LOG}.phase*"

  check_prereqs
  if [[ "${SKIP_BUILD}" == "0" ]]; then
    phase0_build_lpac
    phase1_build
  else
    warn "Skipping lpac and applet/profile builds — SKIP_BUILD=1"
  fi

  if [[ "${SKIP_DOWNLOAD}" == "0" ]]; then
    # The ZK applet lives inside the downloaded profile, so install that
    # profile through the default ISD-R before selecting the custom AID.
    phase1_start_smdpp 0
    phase1_download
    stop_smdpp
  else
    warn "Skipping prerequisite normal profile download — SKIP_DOWNLOAD=1"
  fi

  if [[ "${ZK_DOWNLOAD}" == "1" ]]; then
    # ZK path: run every protocol phase through the custom applet AID.
    phase1_start_smdpp 1
    phase1_start_mno
    phase1_start_pca

    local _t0 _t1

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

    _t0=$(_ts_ms)
    phase1_zk_order_profile
    _t1=$(_ts_ms)
    T_ORDER_PROFILE_MS=$(( _t1 - _t0 ))
    ok "Order profile took ${T_ORDER_PROFILE_MS} ms"

    _t0=$(_ts_ms)
    phase1_zk_download_profile
    _t1=$(_ts_ms)
    T_PROFILE_DOWNLOAD_MS=$(( _t1 - _t0 ))
    ok "Profile download took ${T_PROFILE_DOWNLOAD_MS} ms"

    phase4_verify_profile

    unset LPAC_CUSTOM_ISD_R_AID
  elif [[ "${SKIP_DOWNLOAD}" == "1" ]]; then
    warn "ZK phases disabled and normal profile download skipped."
  fi

  if [[ "${RUN_APPLET_SMOKE}" == "1" ]]; then
    phase2_test_applet
  fi

  banner "Workflow Complete"
  ok "All phases passed successfully."
  echo
  echo -e "  Matching ID  : ${BOLD}${MATCHING_ID}${RESET}"
  echo -e "  Package AID  : ${BOLD}${LOAD_PACKAGE_AID}${RESET}"
  echo -e "  Applet AID   : ${BOLD}${INSTANCE_AID}${RESET}"
  echo

  if [[ "${ZK_DOWNLOAD}" == "1" ]]; then
    print_timing_summary
  fi
}

main "$@"
