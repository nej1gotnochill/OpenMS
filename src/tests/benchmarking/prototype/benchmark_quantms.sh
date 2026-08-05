#!/usr/bin/env bash
# benchmark_quantms.sh — standalone quantms benchmark prototype (Day 8)
#
# Runs the ProteoBench LFQ dataset through bigbio/quantms and collects the
# key outputs. Still a prototype: it checks the environment, validates the
# inputs, builds (and optionally runs) the nextflow command, then copies the
# interesting files out. Dataset bootstrap comes in a later milestone.
#
# Usage:     bash benchmark_quantms.sh [path/to/config.env]
#            (defaults to config.env next to this script)
#
# Exit codes:
#   0  success (or dry-run)
#   1  configuration / usage error
#   2  missing dependency
#   3  input validation failed
#   4  pipeline execution failed
set -euo pipefail

# Fail hard on any error, unset variable, or failed pipe member — a silent
# partial run is worse than no run at all.

# Wherever this script lives is where config.env lives by default
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-${SCRIPT_DIR}/config.env}"

# Defaults before config.env is sourced; the file only overrides what it sets
QUANTMS_DIR=""
DATASET_DIR=""
MZML_DIR=""
FASTA=""
SDRF=""
OUTDIR=""
PROFILE="dev,docker"
SEARCH_ENGINE="comet"
ENABLE_RESCORING="false"
ID_PARAMETERS=""
QUANT_PARAMETERS=""
DRY_RUN="true"
NEXTFLOW_EXTRA_ARGS=""
LOG_DIR="${SCRIPT_DIR}/logs"
OUTPUTS_DIR="${SCRIPT_DIR}/outputs"
CHECK_DISK_SPACE="false"
MIN_DISK_SPACE_GB="50"
CHECK_INTERNET="false"
SKIP_DEPENDENCY_CHECK="false"

# load_config — pull in the config file. Anything essential that's still
# empty afterwards is a problem we want to know about now, not mid-run.
load_config() {
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: config file not found: ${CONFIG_FILE}" >&2
    echo "       usage: bash benchmark_quantms.sh [path/to/config.env]" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"

  local required=(QUANTMS_DIR DATASET_DIR FASTA SDRF OUTDIR)
  local missing=()
  for var in "${required[@]}"; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("${var}")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: required config values missing: ${missing[*]}" >&2
    exit 1
  fi

  # optional values default to something sensible if left empty
  MZML_DIR="${MZML_DIR:-${DATASET_DIR}}"
  LOG_DIR="${LOG_DIR:-${SCRIPT_DIR}/logs}"
  OUTPUTS_DIR="${OUTPUTS_DIR:-${SCRIPT_DIR}/outputs}"
}

# to_posix — config.env paths can be Windows-style (C:\...) or POSIX (/c/...).
# If cygpath exists, convert the Windows ones so everything downstream sees
# the same format. (I edit config.env on Windows but run in Git Bash, so
# this saves me from path headaches.)
to_posix() {
  if command -v cygpath >/dev/null 2>&1 && [[ "$1" == *:* ]]; then
    cygpath -u "$1"
  else
    printf '%s' "$1"
  fi
}

# Log files live in LOG_DIR. These are assigned in setup_logging() (after
# config load) so a custom LOG_DIR in config.env is actually respected —
# that was a bug I hit where logs went to the wrong place.
RUN_LOG=""
QUANTMS_LOG=""
SUMMARY_LOG=""

setup_logging() {
  mkdir -p "${LOG_DIR}"
  RUN_LOG="${LOG_DIR}/run.log"
  QUANTMS_LOG="${LOG_DIR}/quantms.log"
  SUMMARY_LOG="${LOG_DIR}/summary.log"
  : > "${RUN_LOG}"          # fresh logs per invocation
  : > "${QUANTMS_LOG}"
  : > "${SUMMARY_LOG}"
}

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "${RUN_LOG}"; }
warn() { printf '%s  [WARN] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "${RUN_LOG}" >&2; }
fail() { printf '%s  [ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "${RUN_LOG}" >&2; }

# check_dependencies — make sure the tools we're about to call actually
# exist. Much nicer to find out now than to watch nextflow fail 10 minutes in.
check_dependencies() {
  log "== [1/5] Dependency check =="
  if [[ "${SKIP_DEPENDENCY_CHECK}" == "true" ]]; then
    log "  skipped (SKIP_DEPENDENCY_CHECK=true)"
    return 0
  fi

  local missing=0
  check_tool() {
    local name="$1" cmd="$2"
    if command -v "${cmd}" >/dev/null 2>&1; then
      log "  [OK]   ${name}: $(command -v "${cmd}")"
    else
      log "  [FAIL] ${name}: '${cmd}' not found in PATH"
      missing=1
    fi
  }

  check_tool "Nextflow"  nextflow
  check_tool "Docker"    docker
  check_tool "Podman"    podman    # fallback if docker isn't around
  check_tool "Java"      java
  check_tool "Python"    python3
  check_tool "Git"       git

  # the docker profile needs a container engine, so one of these two is required
  if ! command -v docker >/dev/null 2>&1 && ! command -v podman >/dev/null 2>&1; then
    log "  [FAIL] no container engine: install Docker or Podman (required by -profile docker)"
    missing=1
  fi

  # optional: don't start a run we can't finish for lack of space
  if [[ "${CHECK_DISK_SPACE}" == "true" ]]; then
    local avail_gb
    avail_gb="$(df -B1 --output=avail "$(to_posix "${OUTDIR}")" 2>/dev/null | tail -1 | awk '{printf "%.0f", $1/1024/1024/1024}' || true)"
    if [[ -n "${avail_gb}" ]] && (( avail_gb < MIN_DISK_SPACE_GB )); then
      log "  [FAIL] disk space: only ~${avail_gb} GB free (need >= ${MIN_DISK_SPACE_GB} GB)"
      missing=1
    else
      log "  [OK]   disk space: ~${avail_gb:-?} GB free on output volume"
    fi
  fi

  # only relevant once downloads are implemented, but cheap to have
  if [[ "${CHECK_INTERNET}" == "true" ]]; then
    if command -v curl >/dev/null 2>&1 && curl -s --max-time 5 -o /dev/null https://proteobench.cubimed.rub.de/ ; then
      log "  [OK]   internet reachable"
    else
      log "  [FAIL] internet unreachable (needed for dataset downloads)"
      missing=1
    fi
  fi

  if (( missing )); then
    fail "Missing required dependencies. Install them and re-run."
    exit 2
  fi
  log "  All dependencies present."
}

# validate_inputs — everything we hand to nextflow must exist, and OUTDIR
# must be writable. Fail fast with a clear message instead of a confusing
# error deep inside the pipeline.
validate_inputs() {
  log "== [2/5] Input validation =="
  local ok=1

  if [[ -f "$(to_posix "${SDRF}")" ]]; then
    log "  [OK]   SDRF:            ${SDRF}"
  else
    log "  [FAIL] SDRF not found:  ${SDRF}"
    ok=0
  fi

  if [[ -f "$(to_posix "${FASTA}")" ]]; then
    log "  [OK]   FASTA:           ${FASTA}"
  else
    log "  [FAIL] FASTA not found: ${FASTA}"
    ok=0
  fi

  local mzml_dir; mzml_dir="$(to_posix "${MZML_DIR}")"
  if [[ -d "${mzml_dir}" ]]; then
    local n_mzml
    n_mzml="$(find "${mzml_dir}" -maxdepth 1 -iname '*.mzml' 2>/dev/null | wc -l)"
    if (( n_mzml > 0 )); then
      log "  [OK]   mzML directory:  ${MZML_DIR} (${n_mzml} files)"
    else
      log "  [WARN] mzML directory contains no .mzML files: ${MZML_DIR}"
      log "        (RAW->mzML conversion is a bootstrap step, not yet implemented)"
      ok=0
    fi
  else
    log "  [FAIL] mzML directory not found: ${MZML_DIR}"
    ok=0
  fi

  # create the output dir if needed, then check we can actually write to it
  local outdir; outdir="$(to_posix "${OUTDIR}")"
  mkdir -p "${outdir}" 2>/dev/null || true
  if [[ -d "${outdir}" && -w "${outdir}" ]]; then
    log "  [OK]   output dir writable: ${OUTDIR}"
  else
    log "  [FAIL] output dir not writable: ${OUTDIR}"
    ok=0
  fi

  if (( ! ok )); then
    fail "Input validation failed — fix the issues above before running."
    exit 3
  fi
}

# Build the nextflow command as an ARRAY, not a string. Why? Our paths have
# spaces in them ("GSOC NOTES", "OneDrive/...") and a plain string would get
# split apart when executed. CMD_ARRAY is filled here; command_line() below
# just gives a pretty printed version for display/logging.
CMD_ARRAY=()

build_command_array() {
  CMD_ARRAY=(nextflow run "$(to_posix "${QUANTMS_DIR}")")
  CMD_ARRAY+=(-profile "${PROFILE}")
  CMD_ARRAY+=(--input "$(to_posix "${SDRF}")")
  CMD_ARRAY+=(--database "$(to_posix "${FASTA}")")
  CMD_ARRAY+=(--outdir "$(to_posix "${OUTDIR}")")
  CMD_ARRAY+=(--search_engines "${SEARCH_ENGINE}")

  # The whole point of Timo's experiment — one flag flips between
  # Comet + Percolator (false) and Comet + MS2Rescore + Percolator (true)
  if [[ "${ENABLE_RESCORING}" == "true" ]]; then
    CMD_ARRAY+=(--ms2features_enable true)
  else
    CMD_ARRAY+=(--ms2features_enable false)
  fi

  if [[ -n "${ID_PARAMETERS}" ]]; then
    CMD_ARRAY+=(--id_parameters "$(to_posix "${ID_PARAMETERS}")")
  fi
  if [[ -n "${QUANT_PARAMETERS}" ]]; then
    CMD_ARRAY+=(--quant_parameters "$(to_posix "${QUANT_PARAMETERS}")")
  fi
  if [[ -n "${NEXTFLOW_EXTRA_ARGS}" ]]; then
    # split on purpose so things like "-resume" slot in naturally
    # shellcheck disable=SC2206
    CMD_ARRAY+=(${NEXTFLOW_EXTRA_ARGS})
  fi
}

command_line() {
  build_command_array
  printf '%s\n' "${CMD_ARRAY[*]}"
}

# run_pipeline — dry run just prints the command, which is perfect while the
# dataset is still being prepared. Flip DRY_RUN=false once everything is
# actually on disk and you're ready to burn a few hours.
run_pipeline() {
  log "== [3/5] Pipeline execution =="
  build_command_array
  local display_line="${CMD_ARRAY[*]}"

  if [[ "${ENABLE_RESCORING}" == "true" ]]; then
    log "  Rescoring: ON  (--ms2features_enable true)  -> Comet + MS2Rescore + Percolator"
  else
    log "  Rescoring: OFF (--ms2features_enable false) -> Comet + Percolator"
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "  Dry run (DRY_RUN=true) — command generated but NOT executed:"
    log ""
    log "  $ ${display_line}"
    log ""
    log "  Set DRY_RUN=false in config.env to execute this command."
    return 0
  fi

  log "  Executing:"
  log "  $ ${display_line}"
  log "  (stdout/stderr -> ${QUANTMS_LOG})"
  if "${CMD_ARRAY[@]}" > "${QUANTMS_LOG}" 2>&1; then
    log "  Pipeline finished OK (exit 0)"
  else
    local rc=$?
    fail "Pipeline failed with exit code ${rc}. See ${QUANTMS_LOG}"
    exit 4
  fi
}

# collect_outputs — grab the deliverables we care about (msstats CSV, mzTab,
# execution trace) and drop copies into outputs/ so we don't have to dig
# through the whole results dir every time.
collect_outputs() {
  log "== [4/5] Collecting outputs =="
  local outdir; outdir="$(to_posix "${OUTDIR}")"
  mkdir -p "${OUTPUTS_DIR}"

  local found=0 f
  local -a files=()

  # mapfile + '|| true': the naive `while read < <(find ...)` exits non-zero
  # when find finds nothing and trips set -e. That one bit me — don't redo it.
  mapfile -t files < <(find "${outdir}/quant_tables" -maxdepth 1 \
    \( -name '*_msstats_in.csv' -o -name '*.mzTab' \) 2>/dev/null || true)
  for f in "${files[@]}"; do
    cp "${f}" "${OUTPUTS_DIR}/"
    log "  [OK] copied $(basename "${f}")"
    found=1
  done

  local trace_file
  trace_file="$(find "${outdir}/pipeline_info" -maxdepth 1 -name 'execution_trace_*.txt' 2>/dev/null | head -1 || true)"
  if [[ -n "${trace_file}" ]]; then
    cp "${trace_file}" "${OUTPUTS_DIR}/"
    log "  [OK] copied $(basename "${trace_file}")"
    found=1
  fi

  if (( ! found )); then
    warn "No outputs found under ${OUTDIR} — nothing copied."
    warn "This is expected for a dry run; re-run with DRY_RUN=false after the dataset is ready."
  fi
}

# generate_summary — a small record of what we ran and with which settings.
# Handy when comparing two runs later (that's the whole benchmark idea).
generate_summary() {
  log "== [5/5] Summary =="
  {
    echo "quantms benchmark — run summary"
    echo "generated:  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "config:     ${CONFIG_FILE}"
    echo "quantms:    ${QUANTMS_DIR}"
    echo "profile:    ${PROFILE}"
    echo "engine:     ${SEARCH_ENGINE}"
    echo "rescoring:  ${ENABLE_RESCORING}"
    echo "dataset:    ${DATASET_DIR}"
    echo "sdrf:       ${SDRF}"
    echo "fasta:      ${FASTA}"
    echo "outdir:     ${OUTDIR}"
    echo "dry run:    ${DRY_RUN}"
    echo "command:    $(command_line)"
    echo "exit:       0"
  } | tee "${SUMMARY_LOG}"
  log "  Summary written to ${SUMMARY_LOG}"
}

show_help() {
  cat <<'EOF'
benchmark_quantms.sh — standalone quantms benchmark prototype (Day 8)

Usage:
  bash benchmark_quantms.sh [path/to/config.env]

Steps performed:
  1. Dependency check  (nextflow, docker/podman, java, python, git)
  2. Input validation  (SDRF, FASTA, mzML dir, writable output dir)
  3. Pipeline          (generates the nextflow command; executes if DRY_RUN=false)
  4. Collect outputs   (copies *_msstats_in.csv, mzTab, trace into outputs/)
  5. Summary           (writes logs/summary.log)

Logs:   logs/run.log, logs/quantms.log, logs/summary.log
Exit:   0 ok | 1 config | 2 dependencies | 3 validation | 4 pipeline
EOF
}

# main — wire the steps together in order.
main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    show_help
    exit 0
  fi

  echo "=== quantms benchmark prototype ==="
  echo "config: ${CONFIG_FILE}"
  load_config
  setup_logging
  log "Run started (config: ${CONFIG_FILE})"
  log "quantms:   ${QUANTMS_DIR}"
  log "profile:   ${PROFILE} | engine: ${SEARCH_ENGINE} | rescoring: ${ENABLE_RESCORING}"

  check_dependencies
  validate_inputs
  run_pipeline
  collect_outputs
  generate_summary

  log "Run finished — all steps completed."
  echo ""
  echo "Done. Logs in ${LOG_DIR}, collected outputs in ${OUTPUTS_DIR}."
}

main "$@"
