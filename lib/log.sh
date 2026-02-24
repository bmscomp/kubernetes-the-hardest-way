#!/usr/bin/env bash
#
# Shared logging library for minikube-style output.
# Source this from any script: source "$(dirname "$0")/../lib/log.sh"

_LOG_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/logs"
_LOG_SCRIPT_NAME="$(basename "${BASH_SOURCE[1]:-unknown}" .sh)"
_LOG_FILE=""
_LOG_STEP_START=""
_LOG_STEP_MSG=""
_LOG_STEP_EMOJI=""
_LOG_TOTAL_START=$(date +%s)
_LOG_PASS=0
_LOG_FAIL=0
_LOG_IS_TTY=false
_LOG_SPINNER_PID=""

[ -t 1 ] && _LOG_IS_TTY=true

mkdir -p "$_LOG_DIR"

_LOG_FILE="$_LOG_DIR/${_LOG_SCRIPT_NAME}-$(date +%Y%m%d-%H%M%S).log"

_log_format_time() {
  local seconds=$1
  if [ "$seconds" -ge 60 ]; then
    printf "%dm%ds" $((seconds / 60)) $((seconds % 60))
  else
    printf "%ds" "$seconds"
  fi
}

_log_spinner() {
  local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  local i=0
  while true; do
    printf "\r  %s  %-42s %s" "$_LOG_STEP_EMOJI" "$_LOG_STEP_MSG" "${frames[$i]}" >&2
    i=$(( (i + 1) % ${#frames[@]} ))
    sleep 0.1
  done
}

_log_stop_spinner() {
  if [ -n "$_LOG_SPINNER_PID" ]; then
    kill "$_LOG_SPINNER_PID" 2>/dev/null
    wait "$_LOG_SPINNER_PID" 2>/dev/null
    _LOG_SPINNER_PID=""
  fi
}

log_header() {
  local title="$1"
  echo ""
  echo "  $title"
  echo ""
}

log_step() {
  local emoji="$1"
  local msg="$2"
  _LOG_STEP_EMOJI="$emoji"
  _LOG_STEP_MSG="$msg"
  _LOG_STEP_START=$(date +%s)

  if [ "$_LOG_IS_TTY" = true ] && [ "${LOG_VERBOSE:-}" != "1" ]; then
    _log_spinner &
    _LOG_SPINNER_PID=$!
    disown "$_LOG_SPINNER_PID" 2>/dev/null
  else
    printf "  %s  %-42s " "$emoji" "$msg" >&2
  fi
}

log_ok() {
  _log_stop_spinner
  local elapsed=$(( $(date +%s) - _LOG_STEP_START ))
  local time_str=""
  [ "$elapsed" -ge 2 ] && time_str=" $(_log_format_time $elapsed)"
  printf "\r  %s  %-42s \e[32m✔\e[0m%s\n" "$_LOG_STEP_EMOJI" "$_LOG_STEP_MSG" "$time_str" >&2
  ((_LOG_PASS++))
}

log_fail() {
  _log_stop_spinner
  local elapsed=$(( $(date +%s) - _LOG_STEP_START ))
  printf "\r  %s  %-42s \e[31m✘\e[0m\n" "$_LOG_STEP_EMOJI" "$_LOG_STEP_MSG" >&2
  ((_LOG_FAIL++))

  if [ -s "$_LOG_FILE" ]; then
    echo -e "     \e[90m╰─ Last output:\e[0m" >&2
    tail -5 "$_LOG_FILE" | sed 's/^/        /' >&2
    echo -e "     \e[90m╰─ Full log: $_LOG_FILE\e[0m" >&2
  fi
}

log_step_run() {
  local emoji="$1"
  local msg="$2"
  shift 2

  log_step "$emoji" "$msg"

  if [ "${LOG_VERBOSE:-}" = "1" ]; then
    printf "\n" >&2
    if "$@" 2>&1 | tee -a "$_LOG_FILE"; then
      log_ok
      return 0
    else
      log_fail
      return 1
    fi
  else
    if "$@" >> "$_LOG_FILE" 2>&1; then
      log_ok
      return 0
    else
      log_fail
      return 1
    fi
  fi
}

log_info() {
  echo -e "     \e[90m$1\e[0m" >&2
}

log_warn() {
  echo -e "  ⚠️   \e[33m$1\e[0m" >&2
}

log_summary() {
  local total_elapsed=$(( $(date +%s) - _LOG_TOTAL_START ))
  echo "" >&2
  if [ "$_LOG_FAIL" -eq 0 ]; then
    echo -e "  \e[32m✅  Done!\e[0m $_LOG_PASS steps completed in $(_log_format_time $total_elapsed)" >&2
  else
    echo -e "  \e[31m❌  Failed.\e[0m $_LOG_PASS passed, $_LOG_FAIL failed in $(_log_format_time $total_elapsed)" >&2
    echo -e "     Log: $_LOG_FILE" >&2
  fi
  echo "" >&2
}

trap _log_stop_spinner EXIT
