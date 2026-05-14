#!/bin/bash
# ---------------------------------------------------------------------------
# kbn-dev-ctl — query and control a kbn-dev instance
#
# Usage:
#   yarn kbn-dev-ctl status [--json]            Show component health
#   yarn kbn-dev-ctl logs <component>           Tail the last 50 lines of a component log
#     [--tail N]                         Number of lines (default 50)
#     [--follow]                         Follow (tail -f)
#     [--grep PATTERN]                   Filter lines
#   yarn kbn-dev-ctl restart <component>        Restart kbnsls or kbnstack
#     [--kibana-only]                    Restart only Kibana, leave ES running
#   yarn kbn-dev-ctl stop                       Stop the entire kbn-dev instance
#
# Components: essls, esstack, optimizer, kbnsls, kbnstack, all
#
# The log directory defaults to ~/.kbn-dev/logs (override with KBN_DEV_LOG_DIR).
# All commands work from any directory.
# ---------------------------------------------------------------------------

set -euo pipefail

# --- Source .env overrides --------------------------------------------------
if [ -z "${KBN_DEV_ENV_FILE:-}" ]; then
  KBN_DEV_ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"
fi
if [ -f "$KBN_DEV_ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a; . "$KBN_DEV_ENV_FILE"; set +a
fi

# --- Node version setup -----------------------------------------------------
# Agent shells (Claude Code, Cursor, CI) don't load version managers by
# default, so yarn may see the wrong node and fail the engine check.
# Detect whichever manager is installed and activate the .nvmrc version.
setup_node() {
  # Already correct? Skip.
  if [ -f ".nvmrc" ] && command -v node >/dev/null 2>&1; then
    local want="v$(cat .nvmrc 2>/dev/null)"
    local have="$(node --version 2>/dev/null)"
    [ "$want" = "$have" ] && return 0
  fi

  # nvm
  if [ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]; then
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh" --no-use
    [ -f ".nvmrc" ] && nvm use --silent 2>/dev/null || true
    [ -n "${NVM_BIN:-}" ] && export PATH="$NVM_BIN:$PATH"
    return 0
  fi

  # fnm
  if command -v fnm >/dev/null 2>&1; then
    eval "$(fnm env --shell bash 2>/dev/null)" || true
    [ -f ".nvmrc" ] && fnm use --silent-if-unchanged 2>/dev/null || true
    return 0
  fi

  # volta (auto-activates based on package.json, no explicit use needed)
  if command -v volta >/dev/null 2>&1; then
    return 0
  fi

  # mise (formerly rtx)
  if command -v mise >/dev/null 2>&1; then
    eval "$(mise activate bash 2>/dev/null)" || true
    return 0
  fi

  # asdf
  if [ -s "${ASDF_DIR:-$HOME/.asdf}/asdf.sh" ]; then
    # shellcheck disable=SC1091
    . "${ASDF_DIR:-$HOME/.asdf}/asdf.sh" 2>/dev/null || true
    return 0
  fi
}
setup_node

# --- Locate log directory ---------------------------------------------------
find_log_dir() {
  local d="${KBN_DEV_LOG_DIR:-$HOME/.kbn-dev/logs}"
  mkdir -p "$d" 2>/dev/null
  echo "$d"
}

LOG_DIR="$(find_log_dir)"
STATUS_FILE="$LOG_DIR/status.json"

# --- Helpers ----------------------------------------------------------------
component_log() {
  local comp="$1"
  case "$comp" in
    essls)     echo "$LOG_DIR/essls.log" ;;
    esstack)   echo "$LOG_DIR/esstack.log" ;;
    optimizer) echo "$LOG_DIR/optimizer.log" ;;
    kbnsls)    echo "$LOG_DIR/kbnsls.log" ;;
    kbnstack)  echo "$LOG_DIR/kbnstack.log" ;;
    main)      echo "$LOG_DIR/main.log" ;;
    *)         echo "ERROR: Unknown component '$comp'" >&2
               echo "  Valid: essls, esstack, optimizer, kbnsls, kbnstack, main" >&2
               exit 1 ;;
  esac
}

pid_alive() {
  local pid="$1"
  [ -n "$pid" ] && [ "$pid" != "null" ] && kill -0 "$pid" 2>/dev/null
}

port_listening() {
  local port="$1"
  lsof -ti "tcp:$port" >/dev/null 2>&1
}

check_ready() {
  local logfile="$1" pattern="$2"
  grep -q "$pattern" "$logfile" 2>/dev/null
}

# --- status -----------------------------------------------------------------
# Disable errexit/pipefail for the status function. A grep no-match (exit 1)
# inside a pipeline with pipefail + set -e kills the script before any output,
# causing false "not running" reports from skill dynamic injection fallbacks.
cmd_status() {
  set +eo pipefail

  local json_mode=false
  [ "${1:-}" = "--json" ] && json_mode=true

  local main_pid=""
  [ -f "$LOG_DIR/kbn.pid" ] && main_pid=$(cat "$LOG_DIR/kbn.pid" 2>/dev/null)
  local main_alive=false
  pid_alive "$main_pid" && main_alive=true

  local state="unknown"
  [ -f "$STATUS_FILE" ] && state=$(grep -o '"state": *"[^"]*"' "$STATUS_FILE" 2>/dev/null | head -1 | sed 's/.*: *"//;s/"//')

  local essls_pid="" esstack_pid="" optimizer_pid="" kbnsls_pid="" kbnstack_pid=""
  if [ -f "$STATUS_FILE" ]; then
    essls_pid=$(grep -o '"essls".*"pid": *"[^"]*"' "$STATUS_FILE" 2>/dev/null | grep -o '"pid": *"[^"]*"' | head -1 | sed 's/.*"pid": *"//;s/"//g') || true
    esstack_pid=$(grep -o '"esstack".*"pid": *"[^"]*"' "$STATUS_FILE" 2>/dev/null | grep -o '"pid": *"[^"]*"' | head -1 | sed 's/.*"pid": *"//;s/"//g') || true
    optimizer_pid=$(grep -o '"optimizer".*"pid": *"[^"]*"' "$STATUS_FILE" 2>/dev/null | grep -o '"pid": *"[^"]*"' | head -1 | sed 's/.*"pid": *"//;s/"//g') || true
    kbnsls_pid=$(grep -o '"kbnsls".*"pid": *"[^"]*"' "$STATUS_FILE" 2>/dev/null | grep -o '"pid": *"[^"]*"' | head -1 | sed 's/.*"pid": *"//;s/"//g') || true
    kbnstack_pid=$(grep -o '"kbnstack".*"pid": *"[^"]*"' "$STATUS_FILE" 2>/dev/null | grep -o '"pid": *"[^"]*"' | head -1 | sed 's/.*"pid": *"//;s/"//g') || true
  fi

  # Pid files are updated by --kibana-only restarts; prefer them over stale status.json
  if ! pid_alive "$kbnsls_pid" && [ -f "$LOG_DIR/kbnsls.pid" ]; then
    kbnsls_pid=$(cat "$LOG_DIR/kbnsls.pid" 2>/dev/null)
  fi
  if ! pid_alive "$kbnstack_pid" && [ -f "$LOG_DIR/kbnstack.pid" ]; then
    kbnstack_pid=$(cat "$LOG_DIR/kbnstack.pid" 2>/dev/null)
  fi

  local essls_alive=false esstack_alive=false optimizer_alive=false
  local kbnsls_alive=false kbnstack_alive=false
  pid_alive "$essls_pid" && essls_alive=true
  pid_alive "$esstack_pid" && esstack_alive=true
  pid_alive "$optimizer_pid" && optimizer_alive=true
  pid_alive "$kbnsls_pid" && kbnsls_alive=true
  pid_alive "$kbnstack_pid" && kbnstack_alive=true

  local p5601=false p5611=false p9200=false p9201=false
  port_listening 5601 && p5601=true
  port_listening 5611 && p5611=true
  port_listening 9200 && p9200=true
  port_listening 9201 && p9201=true

  local essls_ready=false esstack_ready=false kbnsls_ready=false kbnstack_ready=false
  if [ "$essls_alive" = true ] || [ "$p9200" = true ]; then
    check_ready "$LOG_DIR/essls.log" "succ Serverless ES cluster running" && essls_ready=true
  fi
  if [ "$esstack_alive" = true ] || [ "$p9201" = true ]; then
    check_ready "$LOG_DIR/esstack.log" "succ ES cluster is ready" && esstack_ready=true
  fi
  # Kibana ready = log says available AND port is actually open.
  # The log check alone is unreliable after restarts (stale messages).
  if [ "$p5601" = true ]; then
    check_ready "$LOG_DIR/kbnsls.log" "\[INFO \]\[status\] Kibana is now available" && kbnsls_ready=true
  fi
  if [ "$p5611" = true ]; then
    check_ready "$LOG_DIR/kbnstack.log" "\[INFO \]\[status\] Kibana is now available" && kbnstack_ready=true
  fi

  if [ "$json_mode" = true ]; then
    cat <<EOF
{
  "running": $main_alive,
  "state": "$state",
  "pid": ${main_pid:-null},
  "log_dir": "$LOG_DIR",
  "components": {
    "essls":     { "pid": ${essls_pid:-null},     "alive": $essls_alive,     "ready": $essls_ready,     "port_open": $p9200  },
    "esstack":   { "pid": ${esstack_pid:-null},   "alive": $esstack_alive,   "ready": $esstack_ready,   "port_open": $p9201  },
    "optimizer": { "pid": ${optimizer_pid:-null},  "alive": $optimizer_alive  },
    "kbnsls":    { "pid": ${kbnsls_pid:-null},    "alive": $kbnsls_alive,    "ready": $kbnsls_ready,    "port_open": $p5601, "url": "http://localhost:5601" },
    "kbnstack":  { "pid": ${kbnstack_pid:-null},  "alive": $kbnstack_alive,  "ready": $kbnstack_ready,  "port_open": $p5611, "url": "http://localhost:5611" }
  }
}
EOF
    return
  fi

  echo ""
  echo "kbn-dev status"
  echo "=========="
  if [ "$main_alive" = true ]; then
    echo "  Controller:   running (PID $main_pid, state: $state)"
  else
    echo "  Controller:   not running"
  fi
  echo ""

  local fmt="  %-12s  %-8s  %-8s  %s\n"
  printf "$fmt" "COMPONENT" "PROCESS" "READY" "PORT"
  printf "$fmt" "---------" "-------" "-----" "----"
  printf "$fmt" "essls"     "$([ "$essls_alive" = true ] && echo "up" || echo "down")"     "$([ "$essls_ready" = true ] && echo "yes" || echo "no")"     "9200 $([ "$p9200" = true ] && echo "open" || echo "closed")"
  printf "$fmt" "esstack"   "$([ "$esstack_alive" = true ] && echo "up" || echo "down")"   "$([ "$esstack_ready" = true ] && echo "yes" || echo "no")"   "9201 $([ "$p9201" = true ] && echo "open" || echo "closed")"
  printf "$fmt" "optimizer" "$([ "$optimizer_alive" = true ] && echo "up" || echo "down")"  "-"                                                            "-"
  printf "$fmt" "kbnsls"    "$([ "$kbnsls_alive" = true ] && echo "up" || echo "down")"    "$([ "$kbnsls_ready" = true ] && echo "yes" || echo "no")"    "5601 $([ "$p5601" = true ] && echo "open" || echo "closed")"
  printf "$fmt" "kbnstack"  "$([ "$kbnstack_alive" = true ] && echo "up" || echo "down")"  "$([ "$kbnstack_ready" = true ] && echo "yes" || echo "no")"  "5611 $([ "$p5611" = true ] && echo "open" || echo "closed")"
  echo ""
  echo "  Logs: $LOG_DIR"
  echo ""
}

# --- logs -------------------------------------------------------------------
cmd_logs() {
  local comp="${1:-}"
  shift || true

  if [ -z "$comp" ]; then
    echo "Usage: yarn kbn-dev-ctl logs <component> [--tail N] [--follow] [--grep PATTERN]"
    echo "Components: essls, esstack, optimizer, kbnsls, kbnstack, main, all"
    exit 1
  fi

  local tail_n=50 follow=false grep_pattern=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --tail)   tail_n="$2"; shift 2 ;;
      --follow) follow=true; shift ;;
      --grep)   grep_pattern="$2"; shift 2 ;;
      *)        echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done

  local components
  if [ "$comp" = "all" ]; then
    components="essls esstack optimizer kbnsls kbnstack"
  else
    components="$comp"
  fi

  for c in $components; do
    local logfile
    logfile=$(component_log "$c")
    if [ ! -f "$logfile" ]; then
      echo "[$c] Log file not found: $logfile"
      continue
    fi

    if [ "$comp" = "all" ]; then
      echo ""
      echo "=== $c ==="
    fi

    if [ "$follow" = true ]; then
      if [ -n "$grep_pattern" ]; then
        tail -f "$logfile" | grep --line-buffered "$grep_pattern"
      else
        tail -f "$logfile"
      fi
    else
      local content
      content=$(tail -n "$tail_n" "$logfile")
      if [ -n "$grep_pattern" ]; then
        echo "$content" | grep "$grep_pattern" || true
      else
        echo "$content"
      fi
    fi
  done
}

# --- restart ----------------------------------------------------------------
restart_kibana_only() {
  local comp="$1"

  local kbn_dir=""
  if [ -f "$STATUS_FILE" ]; then
    kbn_dir=$(grep -o '"kbn_dir": *"[^"]*"' "$STATUS_FILE" 2>/dev/null | sed 's/.*"kbn_dir": *"//;s/"//g')
  fi
  if [ -z "$kbn_dir" ] || [ ! -d "$kbn_dir" ]; then
    if [ -f "package.json" ] && grep -q '"name": "kibana"' package.json 2>/dev/null; then
      kbn_dir="$(pwd)"
    else
      echo "ERROR: Cannot determine Kibana repo root."
      echo "  Run from the kibana repo root or ensure kbn-dev is running."
      exit 1
    fi
  fi

  local es_stack_port="${KBN_DEV_ES_STACK_PORT:-9201}"

  local targets=""
  if [ "$comp" = "serverless" ] || [ "$comp" = "all" ]; then targets="$targets serverless"; fi
  if [ "$comp" = "stateful" ] || [ "$comp" = "all" ]; then targets="$targets stateful"; fi

  for target in $targets; do
    local port pidfile logfile label
    if [ "$target" = "serverless" ]; then
      port=5601
      pidfile="$LOG_DIR/kbnsls.pid"
      logfile="$LOG_DIR/kbnsls.log"
      label="Kibana Serverless"
    else
      port=5611
      pidfile="$LOG_DIR/kbnstack.pid"
      logfile="$LOG_DIR/kbnstack.log"
      label="Kibana Stateful"
    fi

    echo "Restarting $label (port $port) — ES cluster stays running."

    # Kill the monitor process tree (monitor → start_fn subshell → yarn → node)
    if [ -f "$pidfile" ]; then
      local mon_pid
      mon_pid=$(cat "$pidfile" 2>/dev/null)
      if [ -n "$mon_pid" ] && kill -0 "$mon_pid" 2>/dev/null; then
        echo "  Stopping monitor tree (PID $mon_pid)..."
        pkill -TERM -g "$(ps -o pgid= -p "$mon_pid" 2>/dev/null | tr -d ' ')" 2>/dev/null || true
        pkill -P "$mon_pid" 2>/dev/null || true
        kill "$mon_pid" 2>/dev/null || true
      fi
    fi

    # Kill all processes on the port — lsof can return multiple PIDs
    local port_pids
    port_pids=$(lsof -ti "tcp:$port" 2>/dev/null | tr '\n' ' ' || true)
    if [ -n "$port_pids" ]; then
      echo "  Killing $label on port $port (PIDs: $port_pids)..."
      kill $port_pids 2>/dev/null || true
      sleep 2
      port_pids=$(lsof -ti "tcp:$port" 2>/dev/null | tr '\n' ' ' || true)
      if [ -n "$port_pids" ]; then
        echo "  Force-killing remaining PIDs: $port_pids"
        kill -9 $port_pids 2>/dev/null || true
        sleep 1
      fi
    fi

    # Wait for the port to be fully released (TCP TIME_WAIT / kernel cleanup)
    local wait_attempts=0
    while lsof -ti "tcp:$port" >/dev/null 2>&1; do
      wait_attempts=$((wait_attempts + 1))
      if [ $wait_attempts -ge 10 ]; then
        echo "  ERROR: port $port is still in use after kill attempts."
        echo "  Check manually: lsof -ti tcp:$port"
        continue 2
      fi
      echo "  Waiting for port $port to be released... ($wait_attempts)"
      sleep 1
    done

    # Reset the log so readiness checks start fresh
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] --- $label restart (kibana-only) ---" > "$logfile"

    echo "  Starting $label..."
    if [ "$target" = "serverless" ]; then
      nohup bash -c "
        cd \"$kbn_dir\" || exit 1
        export KBN_OPTIMIZER_USE_MAX_AVAILABLE_RESOURCES=false
        exec yarn serverless-es \
          --server.port=5601 \
          --no-optimizer
      " >> "$logfile" 2>&1 &
    else
      nohup bash -c "
        cd \"$kbn_dir\" || exit 1
        export KBN_OPTIMIZER_USE_MAX_AVAILABLE_RESOURCES=false
        exec yarn start \
          --elasticsearch \"http://localhost:$es_stack_port\" \
          --server.port=5611 \
          --xpack.security.cookieName=sid-stack \
          --no-optimizer
      " >> "$logfile" 2>&1 &
    fi
    local new_pid=$!
    disown $new_pid 2>/dev/null || true
    echo "$new_pid" > "$pidfile"
    echo "  Started $label (PID $new_pid)"
    echo ""
  done

  echo "  Use 'yarn kbn-dev-ctl status' to monitor."
}

restart_full() {
  local comp="$1"

  echo "Restarting $comp — full stop + start (ES and Kibana)."
  echo ""

  cmd_stop
  sleep 3

  if ! [ -f "package.json" ] || ! grep -q '"name": "kibana"' package.json 2>/dev/null; then
    echo ""
    echo "  Stopped. To start again, run from the kibana repo root:"
    echo "    yarn kbn-dev"
    return
  fi

  if ! command -v kbn >/dev/null 2>&1 && ! [ -f "scripts/kbn_dev.sh" ]; then
    echo ""
    echo "  Stopped. To start again: yarn kbn-dev"
    return
  fi

  echo ""
  if [ -t 0 ]; then
    echo "  Starting kbn-dev..."
    if [ -f "scripts/kbn_dev.sh" ]; then
      exec bash scripts/kbn_dev.sh
    else
      exec kbn
    fi
  else
    echo "  Starting kbn-dev in background..."
    if [ -f "scripts/kbn_dev.sh" ]; then
      bash scripts/kbn_dev.sh --quiet &
    else
      kbn --quiet &
    fi
    echo "  PID: $!"
    echo "  Use 'yarn kbn-dev-ctl status' to monitor."
  fi
}

cmd_restart() {
  local comp="${1:-}"
  shift || true
  local kibana_only=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --kibana-only) kibana_only=true; shift ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done

  if [ "$comp" != "kbnsls" ] && [ "$comp" != "kbnstack" ] && [ "$comp" != "serverless" ] && [ "$comp" != "stateful" ] && [ "$comp" != "all" ]; then
    echo "Usage: yarn kbn-dev-ctl restart <serverless|stateful|all> [--kibana-only]"
    echo ""
    echo "  Restarts the given mode. By default restarts both ES and Kibana."
    echo "  --kibana-only   Restart only Kibana, leaving ES running."
    echo "  Aliases: kbnsls = serverless, kbnstack = stateful"
    exit 1
  fi

  # Normalize aliases
  [ "$comp" = "kbnsls" ] && comp="serverless"
  [ "$comp" = "kbnstack" ] && comp="stateful"

  if [ "$kibana_only" = true ]; then
    restart_kibana_only "$comp"
  else
    restart_full "$comp"
  fi
}

# --- stop -------------------------------------------------------------------
cmd_stop() {
  local main_pid=""
  [ -f "$LOG_DIR/kbn.pid" ] && main_pid=$(cat "$LOG_DIR/kbn.pid" 2>/dev/null)

  if [ -z "$main_pid" ] || ! kill -0 "$main_pid" 2>/dev/null; then
    echo "No running kbn-dev instance found."
    return
  fi

  echo "Stopping kbn-dev (PID $main_pid)..."
  kill "$main_pid" 2>/dev/null
  echo "Sent SIGTERM. Cleanup will handle child processes."
}

# --- Main dispatch ----------------------------------------------------------
case "${1:-status}" in
  status)  shift 2>/dev/null || true; cmd_status "$@" ;;
  logs)    shift; cmd_logs "$@" ;;
  attach)  exec tmux attach -t kbn-logs ;;
  restart) shift; cmd_restart "$@" ;;
  stop)    cmd_stop ;;
  -h|--help|help)
    echo "Usage: yarn kbn-dev-ctl <command> [options]"
    echo ""
    echo "Commands:"
    echo "  status [--json]              Show component health"
    echo "  logs <component> [options]   View component logs"
    echo "  attach                       Attach to the tmux log viewer"
    echo "  restart <serverless|stateful|all>  Restart (ES + Kibana)"
    echo "    --kibana-only                    Restart only Kibana, leave ES running"
    echo "  stop                         Stop the kbn-dev instance"
    echo ""
    echo "Components: essls, esstack, optimizer, kbnsls, kbnstack, main, all"
    echo ""
    echo "Log options:"
    echo "  --tail N       Number of lines (default 50)"
    echo "  --follow       Follow (tail -f)"
    echo "  --grep PATTERN Filter lines"
    ;;
  *)
    echo "Unknown command: $1" >&2
    echo "Run 'yarn kbn-dev-ctl help' for usage." >&2
    exit 1
    ;;
esac
