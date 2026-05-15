#!/bin/bash
# ---------------------------------------------------------------------------
# kbn-dev — spin up Kibana + Elasticsearch for both serverless and stateful
#
# Run from the ROOT of your kibana repo checkout:
#   yarn kbn-dev
#
# Configuration:
#   The installer creates a .env file in the kbn-dev-tools repo root.
#   Edit it to override defaults. It is gitignored and sourced automatically
#   on startup via KBN_DEV_ENV_FILE (set by the installer in your shell profile).
#   See .env.dev for all available variables with descriptions.
#
# Environment variables (can also be set in .env):
#   CHROME_BIN                   Path to Chrome. Auto-detected if not set.
#   SKIP_BROWSER_LAUNCH          Set to any value to skip Chrome launch.
#   KBN_DEV_LOG_DIR              Log directory. Default: ~/.kbn-dev/logs
#   KBN_DEV_INFERENCE_URL        EIS URL. Set to "" to disable.
#                                Default: "https://inference.eu-west-1.aws.svc.qa.elastic.cloud"
#   KIBANA_EIS_CCM_API_KEY       CCM key passed to kbn-dev-ccm (skips vault). QA or prod.
#   KBN_DEV_ES_SLS_PORT          Serverless ES HTTP port. Default: 9200
#   KBN_DEV_ES_SLS_PROJECT_TYPE  Serverless project type. Default: elasticsearch_general_purpose
#   KBN_DEV_ES_SLS_EXTRA_ARGS   Additional args for serverless ES.
#   KBN_DEV_ES_STACK_PORT        Stateful ES HTTP port. Default: 9201
#   KBN_DEV_ES_STACK_LICENSE     Stateful ES license. Default: trial
#   KBN_DEV_ES_STACK_ML_ENABLED  Enable ML on stateful ES. Default: false
#   KBN_DEV_ES_STACK_EXTRA_ARGS  Additional args for stateful ES.
#
# Flags:
#   --clean               Wipe .es/cache and run `yarn kbn clean` before boot.
#   --quiet               Skip the tmux log viewer (on by default).
#
# Prerequisites:
#   - Node.js (nvm is detected automatically if installed)
#   - yarn (ships with the kibana repo via corepack/volta/etc.)
#   - Docker running (required by `yarn es`)
#   - Google Chrome (auto-detected, or set CHROME_BIN)
#   - Ports 5601, 5611 and the ES ports (default 9200/9201/9300/9301) must be free
#   - vault CLI (for EIS; skip with KIBANA_EIS_CCM_API_KEY or KBN_DEV_INFERENCE_URL="")
# ---------------------------------------------------------------------------

# --- Detect interactive mode ------------------------------------------------
# Non-interactive when stdin is not a terminal (piped, run by agent, CI, etc.).
# Interactive prompts auto-accept and verbose banners are suppressed.
INTERACTIVE=true
[ -t 0 ] || INTERACTIVE=false
SHUTTING_DOWN=false

# --- Defaults for Kibana env vars (overridable via .env) --------------------
export KBN_USE_RSPACK="${KBN_USE_RSPACK:-true}"

# --- Source .env overrides --------------------------------------------------
# Resolution order:
#   1. $KBN_DEV_ENV_FILE if set (explicit override)
#   2. <repo>/.env if this script resolves into a repo checkout
#      (scripts/kbn_dev.sh layout; works through symlinks from ~/.local/bin)
#   3. ~/.kbn-dev/.env (installed default)
if [ -z "${KBN_DEV_ENV_FILE:-}" ]; then
  _kbn_src="${BASH_SOURCE[0]}"
  while [ -L "$_kbn_src" ]; do
    _kbn_dir="$(cd "$(dirname "$_kbn_src")" && pwd)"
    _kbn_src="$(readlink "$_kbn_src")"
    case "$_kbn_src" in /*) ;; *) _kbn_src="$_kbn_dir/$_kbn_src" ;; esac
  done
  _kbn_dev_parent="$(cd "$(dirname "$_kbn_src")" && pwd)"
  if [ "$(basename "$_kbn_dev_parent")" = "scripts" ] && [ -f "$(dirname "$_kbn_dev_parent")/.env" ]; then
    KBN_DEV_ENV_FILE="$(dirname "$_kbn_dev_parent")/.env"
  else
    KBN_DEV_ENV_FILE="${KBN_DEV_HOME:-$HOME/.kbn-dev}/.env"
  fi
  unset _kbn_dev_parent _kbn_src _kbn_dir
fi
if [ -f "$KBN_DEV_ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a; . "$KBN_DEV_ENV_FILE"; set +a
  echo "kbn-dev: using env file $KBN_DEV_ENV_FILE"
else
  echo "kbn-dev: no env file at $KBN_DEV_ENV_FILE (using defaults)"
fi

# =============================================================================
# Utility functions
# =============================================================================

log_step() {
  [ "$SHUTTING_DOWN" = true ] && return
  local msg="$1"
  local logfile="${2:-}"
  local line
  line="[$(date '+%Y-%m-%d %H:%M:%S')] $msg"
  echo -e "\n$line"
  [ -n "$logfile" ] && echo -e "\n$line" >> "$logfile"
}

wait_for_log() {
  local logfile="$1" pattern="$2" pid="$3" label="$4"
  while true; do
    grep -q "$pattern" "$logfile" 2>/dev/null && return 0
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      log_step "ERROR: $label process died. Check $logfile"
      return 1
    fi
    sleep 2
  done
}

wait_for_kibana() {
  local label="$1" logfile="$2" es_pid="$3" kbn_pidfile="$4" port="${5:-}"
  local kbn_pid

  log_step "Waiting for $label to become available..."
  while true; do
    if grep -q "\[INFO \]\[status\] Kibana is now available" "$logfile" 2>/dev/null; then
      log_step "$label is available!"
      return 0
    fi
    # Also check via HTTP — the log grep can miss if log is buffered
    if [ -n "$port" ]; then
      local http_code
      http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$port/api/status" 2>/dev/null || echo "000")
      if [ "$http_code" = "200" ] || [ "$http_code" = "302" ]; then
        log_step "$label is available! (detected via HTTP $http_code)"
        return 0
      fi
    fi
    if ! kill -0 "$es_pid" 2>/dev/null && [ ! -f "$kbn_pidfile" ]; then
      log_step "FAILED: ES died and $label was never started."
      return 1
    fi
    if [ -f "$kbn_pidfile" ]; then
      kbn_pid=$(cat "$kbn_pidfile" 2>/dev/null)
      if [ -n "$kbn_pid" ] && ! kill -0 "$kbn_pid" 2>/dev/null; then
        # Double-check: the monitor PID might be orphaned from the pipeline
        # subshell. Check if the port is listening as a fallback.
        if [ -n "$port" ] && lsof -ti "tcp:$port" >/dev/null 2>&1; then
          sleep 2
          continue
        fi
        log_step "FAILED: $label monitor died. Check $logfile"
        return 1
      fi
    fi
    sleep 2
  done
}

kill_tree() {
  local pid="$1"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
  fi
}

kill_port() {
  local port="$1"
  local pid
  pid=$(lsof -ti "tcp:$port" 2>/dev/null)
  if [ -n "$pid" ]; then
    log_step "Clearing stale process $pid on port $port"
    kill -9 "$pid" 2>/dev/null || true
    sleep 1
  fi
}

write_status() {
  local state="$1"
  shift
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  cat > "$LOG_DIR/status.json" <<STATUSEOF
{
  "state": "$state",
  "updated": "$ts",
  "pid": $$,
  "log_dir": "$LOG_DIR",
  "kbn_dir": "$KBN_DIR",
  "clean": $CLEAN_CACHE,
  "eis": $([ "$CCM_ENABLED" = true ] && echo "true" || echo "false"),
  "components": {
    "essls":     { "pid": "${ESSLS_PID:-null}",     "log": "$ESSLS_LOG",     "port": $KBN_DEV_ES_SLS_PORT },
    "esstack":   { "pid": "${ESSTACK_PID:-null}",   "log": "$ESSTACK_LOG",   "port": $KBN_DEV_ES_STACK_PORT },
    "optimizer": { "pid": "${OPTIMIZER_PID:-null}",  "log": "$OPTIMIZER_LOG"  },
    "kbnsls":    { "pid": "${KBNSLS_PID:-null}",    "log": "$KBNSLS_LOG",    "port": 5601, "url": "http://localhost:5601" },
    "kbnstack":  { "pid": "${KBNSTACK_PID:-null}",  "log": "$KBNSTACK_LOG",  "port": 5611, "url": "$STACK_KBN_URL" }
  }$([ $# -gt 0 ] && echo ","; for kv in "$@"; do echo "  $kv"; done)
}
STATUSEOF
}

# =============================================================================
# Pre-flight checks (before anything starts)
# =============================================================================

# --- Intro banner (interactive only) ----------------------------------------
if [ "$INTERACTIVE" = true ]; then
  cat <<BANNER

=============================================
 kbn-dev — Kibana dual-mode dev launcher
=============================================

 Spins up Elasticsearch (serverless + stateful) and two Kibana
 instances in parallel, with an optimizer in watch mode.

 Prerequisites:
   Node.js    nvm is detected automatically from .nvmrc
   yarn       ships with the kibana repo (corepack/volta)
   Docker     required by 'yarn es' for ES clusters
   Chrome     auto-detected, or set CHROME_BIN
   vault      required for EIS (skip with KIBANA_EIS_CCM_API_KEY
              or KBN_DEV_INFERENCE_URL="")

 Configuration:
   Edit $KBN_DEV_ENV_FILE to customize.

 Flags:
   --clean                  Wipe .es/cache and run 'yarn kbn clean'
   --quiet                  Skip the tmux log viewer (on by default)

=============================================

BANNER
fi

# --- Repo root check -------------------------------------------------------
if [ ! -f "package.json" ] || ! grep -q '"name": "kibana"' package.json 2>/dev/null; then
  echo "ERROR: This script must be run from the root of the kibana repo."
  echo "  yarn kbn-dev"
  exit 1
fi
KBN_DIR="$(pwd)"

# --- Node version setup ----------------------------------------------------
# Detect whichever version manager is installed and activate the .nvmrc
# version. Then pin the resolved node binary at the front of PATH so
# backgrounded subshells can never fall back to a different version.
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
    . "$NVM_DIR/nvm.sh"
    nvm use
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

if ! command -v node >/dev/null 2>&1; then
  echo "ERROR: node is not available. Install Node.js (via nvm, fnm, volta, mise, or asdf), then retry."
  exit 1
fi

EXPECTED_NODE="v$(cat .nvmrc 2>/dev/null)"
ACTUAL_NODE="$(node --version 2>/dev/null)"
if [ "$EXPECTED_NODE" != "$ACTUAL_NODE" ]; then
  echo "ERROR: Expected node $EXPECTED_NODE (from .nvmrc) but got $ACTUAL_NODE"
  echo "  Your node version manager may not have switched correctly."
  echo "  Try: nvm install $(cat .nvmrc)  OR  fnm install $(cat .nvmrc)"
  exit 1
fi

# --- Parse flags ------------------------------------------------------------
CLEAN_CACHE=false
SHOW_LOGS=true
for arg in "$@"; do
  case $arg in
    --clean)        CLEAN_CACHE=true; shift ;;
    --quiet) SHOW_LOGS=false; shift ;;
    *) ;;
  esac
done

# --- Chrome profile setup --------------------------------------------------
LAUNCH_BROWSER=true
CHROME_PROFILE_DIR="$HOME/.kbn-dev/chrome"
SLS_PROFILE="$CHROME_PROFILE_DIR/kbn-sls"
STACK_PROFILE="$CHROME_PROFILE_DIR/kbn-stack"

detect_chrome() {
  local candidates=(
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary"
  )
  for c in "${candidates[@]}"; do
    [ -f "$c" ] && echo "$c" && return
  done
  for c in google-chrome google-chrome-stable chromium-browser chromium; do
    command -v "$c" >/dev/null 2>&1 && command -v "$c" && return
  done
  return 1
}

if [ -n "$SKIP_BROWSER_LAUNCH" ]; then
  [ "$INTERACTIVE" = true ] && echo "SKIP_BROWSER_LAUNCH is set — skipping Chrome setup."
  LAUNCH_BROWSER=false
elif [ -n "$CHROME_BIN" ]; then
  CHROME_BIN_CLEAN="${CHROME_BIN//\\/}"
  if [ "$CHROME_BIN_CLEAN" != "$CHROME_BIN" ] && [ -f "$CHROME_BIN_CLEAN" ]; then
    echo "NOTE: Stripped backslashes from CHROME_BIN (use plain spaces inside double quotes)."
    echo "  Was: $CHROME_BIN"
    echo "  Now: $CHROME_BIN_CLEAN"
    CHROME_BIN="$CHROME_BIN_CLEAN"
  fi

  if [ ! -f "$CHROME_BIN" ] && ! command -v "$CHROME_BIN" >/dev/null 2>&1; then
    echo "WARNING: CHROME_BIN='$CHROME_BIN' was not found."
    LAUNCH_BROWSER=false
  fi
else
  if detected=$(detect_chrome); then
    CHROME_BIN="$detected"
    echo "Auto-detected Chrome: $CHROME_BIN"
  else
    [ "$INTERACTIVE" = true ] && echo "WARNING: Chrome was not found. Open Kibana URLs manually."
    LAUNCH_BROWSER=false
  fi
fi

if [ "$LAUNCH_BROWSER" = true ]; then
  need_sls=false
  need_stack=false
  [ ! -d "$SLS_PROFILE" ] && need_sls=true
  [ ! -d "$STACK_PROFILE" ] && need_stack=true

  if [ "$need_sls" = true ] || [ "$need_stack" = true ]; then
    if [ "$INTERACTIVE" = true ]; then
      echo ""
      echo "Chrome profiles needed for independent Kibana logins:"
      [ "$need_sls" = true ]   && echo "  kbn-sls   (serverless)  -> $SLS_PROFILE   [not found]"
      [ "$need_stack" = true ]  && echo "  kbn-stack (stateful)    -> $STACK_PROFILE  [not found]"
      echo ""
      read -r -p "  Create missing profile(s)? [Y/n] " answer
    else
      answer="y"
    fi

    case "$answer" in
      [nN]*)
        echo "  Skipping. Open Kibana manually at the URLs printed at the end."
        LAUNCH_BROWSER=false
        ;;
      *)
        profile_ok=true
        for prof_dir in \
          $([ "$need_sls" = true ] && echo "$SLS_PROFILE") \
          $([ "$need_stack" = true ] && echo "$STACK_PROFILE"); do
          if mkdir -p "$prof_dir" 2>/dev/null; then
            echo "  Created: $prof_dir"
          else
            echo "  ERROR: Could not create $prof_dir"
            profile_ok=false
          fi
        done
        [ "$profile_ok" = false ] && LAUNCH_BROWSER=false
        ;;
    esac
    echo ""
  fi
fi

LAST_CHROME_PID=""
open_chrome() {
  local url="$1" profile="$2"
  LAST_CHROME_PID=""
  if [ "$LAUNCH_BROWSER" = true ]; then
    log_step "Opening Chrome: $url (profile: $(basename "$profile"))"
    if [[ "$OSTYPE" == darwin* ]]; then
      open -na "Google Chrome" --args --new-window --user-data-dir="$profile" "$url" &
    else
      "$CHROME_BIN" --new-window --user-data-dir="$profile" "$url" 2>/dev/null &
    fi
    LAST_CHROME_PID=$!
  fi
}

# --- Logging ----------------------------------------------------------------
LOG_DIR="${KBN_DEV_LOG_DIR:-$HOME/.kbn-dev/logs}"
mkdir -p "$LOG_DIR"
if [ ! -f "$LOG_DIR/../README" ]; then
  cat > "$LOG_DIR/../README" <<'EOF'
This directory is managed by kbn-dev (https://github.com/wildemat/kbn-dev-tools).

  logs/       Runtime logs for ES and Kibana instances
  chrome/     Chrome profile data for isolated Kibana browser sessions

Safe to delete when kbn-dev is not running.
EOF
fi

# --- Kill previous instance -------------------------------------------------
PIDFILE="$LOG_DIR/kbn.pid"
if [ -f "$PIDFILE" ]; then
  OLD_PID=$(cat "$PIDFILE" 2>/dev/null)
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Stopping previous kbn-dev instance (PID $OLD_PID)..."
    pkill -P "$OLD_PID" 2>/dev/null || true
    kill "$OLD_PID" 2>/dev/null || true
    sleep 2
  fi
fi
echo $$ > "$PIDFILE"

# --- PID tracking -----------------------------------------------------------
OPTIMIZER_PID=""
ESSLS_PID=""
ESSTACK_PID=""
KBNSLS_PID=""
KBNSTACK_PID=""
SLS_CHROME_PID=""
STACK_CHROME_PID=""

# --- Cleanup on exit --------------------------------------------------------
cleanup() {
  SHUTTING_DOWN=true
  set +m 2>/dev/null
  echo ""
  echo "Stopping all processes..."

  # Chrome
  for profile_dir in "$SLS_PROFILE" "$STACK_PROFILE"; do
    if [ -n "$profile_dir" ]; then
      local chrome_pids
      chrome_pids=$(pgrep -f "user-data-dir=$profile_dir" 2>/dev/null || true)
      if [ -n "$chrome_pids" ]; then
        echo "  Closing Chrome (profile: $(basename "$profile_dir"))"
        echo "$chrome_pids" | xargs kill 2>/dev/null || true
      fi
    fi
  done

  # Kill Kibana node processes by port
  for port in 5601 5611; do
    local port_pid
    port_pid=$(lsof -ti "tcp:$port" 2>/dev/null)
    if [ -n "$port_pid" ]; then
      echo "  Killing Kibana on port $port (PID $port_pid)"
      kill "$port_pid" 2>/dev/null || true
    fi
  done

  # Kill tracked PIDs and their children
  for pid in $KBNSLS_PID $KBNSTACK_PID $OPTIMIZER_PID $ESSLS_PID $ESSTACK_PID; do
    kill_tree "$pid"
  done

  sleep 2

  # Force-kill anything still alive
  for pid in $KBNSLS_PID $KBNSTACK_PID $OPTIMIZER_PID $ESSLS_PID $ESSTACK_PID; do
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "  Force-killing PID $pid"
      pkill -9 -P "$pid" 2>/dev/null || true
      kill -9 "$pid" 2>/dev/null || true
    fi
  done

  # Kill any remaining node processes on Kibana ports
  for port in 5601 5611; do
    local port_pid
    port_pid=$(lsof -ti "tcp:$port" 2>/dev/null)
    if [ -n "$port_pid" ]; then
      echo "  Force-killing orphan on port $port (PID $port_pid)"
      kill -9 "$port_pid" 2>/dev/null || true
    fi
  done

  # Stop ES Docker containers
  if command -v docker >/dev/null 2>&1; then
    local containers
    containers=$(docker ps -q --filter "name=es01" --filter "name=es02" --filter "name=es03" --filter "name=uiam" --filter "name=uiam-cosmosdb" 2>/dev/null | xargs)
    if [ -n "$containers" ]; then
      echo "  Stopping Docker containers: $containers"
      # shellcheck disable=SC2086
      docker stop $containers 2>/dev/null || true
      # shellcheck disable=SC2086
      docker rm -f $containers 2>/dev/null || true
    fi
  fi

  wait 2>/dev/null

  if command -v tmux >/dev/null 2>&1 && tmux has-session -t kbn-logs 2>/dev/null; then
    echo "  Killing tmux session 'kbn-logs'..."
    tmux kill-session -t kbn-logs 2>/dev/null || true
  fi

  write_status "stopped"
  rm -f "$PIDFILE" "$LOG_DIR/kbnsls.pid" "$LOG_DIR/kbnstack.pid"
  echo "Cleanup complete."
  exit
}
trap cleanup SIGINT SIGTERM

# --- Log files --------------------------------------------------------------
ESSLS_LOG="$LOG_DIR/essls.log"
ESSTACK_LOG="$LOG_DIR/esstack.log"
KBNSLS_LOG="$LOG_DIR/kbnsls.log"
KBNSTACK_LOG="$LOG_DIR/kbnstack.log"
OPTIMIZER_LOG="$LOG_DIR/optimizer.log"
MAIN_LOG="$LOG_DIR/main.log"
for f in "$ESSLS_LOG" "$ESSTACK_LOG" "$KBNSLS_LOG" "$KBNSTACK_LOG" "$OPTIMIZER_LOG" "$MAIN_LOG"; do
  rm -f "$f"; touch "$f"
done

# --- Build inference flag ---------------------------------------------------
KBN_DEV_INFERENCE_URL="${KBN_DEV_INFERENCE_URL:-https://inference.eu-west-1.aws.svc.qa.elastic.cloud}"
CCM_ENABLED=false
INFERENCE_FLAG=""
if [ -n "$KBN_DEV_INFERENCE_URL" ]; then
  CCM_ENABLED=true
  # Only pass the QA inference URL to ES when the user hasn't provided their
  # own CCM key.  A user-supplied KIBANA_EIS_CCM_API_KEY means they connect to
  # their own cloud EIS endpoint and the default QA URL would conflict.
  if [ -z "${KIBANA_EIS_CCM_API_KEY:-}" ]; then
    INFERENCE_FLAG="-E xpack.inference.elastic.url=$KBN_DEV_INFERENCE_URL"
  fi
fi

# --- ES cluster overrides ---------------------------------------------------
KBN_DEV_ES_SLS_PORT="${KBN_DEV_ES_SLS_PORT:-9200}"
KBN_DEV_ES_SLS_PROJECT_TYPE="${KBN_DEV_ES_SLS_PROJECT_TYPE:-elasticsearch_general_purpose}"
KBN_DEV_ES_SLS_EXTRA_ARGS="${KBN_DEV_ES_SLS_EXTRA_ARGS:-}"
KBN_DEV_ES_STACK_PORT="${KBN_DEV_ES_STACK_PORT:-9201}"
KBN_DEV_ES_STACK_LICENSE="${KBN_DEV_ES_STACK_LICENSE:-trial}"
KBN_DEV_ES_STACK_ML_ENABLED="${KBN_DEV_ES_STACK_ML_ENABLED:-false}"
KBN_DEV_ES_STACK_EXTRA_ARGS="${KBN_DEV_ES_STACK_EXTRA_ARGS:-}"
KBN_DEV_ES_SLS_TRANSPORT_PORT=$((KBN_DEV_ES_SLS_PORT + 100))
KBN_DEV_ES_STACK_TRANSPORT_PORT=$((KBN_DEV_ES_STACK_PORT + 100))

# --- Mock IdP / SAML (stateful) ---------------------------------------------
# PR elastic/kibana#263998 enabled SAML Mock IdP for stateful by default.
# `yarn es snapshot` auto-configures a SAML realm whose SP/ACS URLs must match
# Kibana's host:port/basePath. The fixed basePath is /kbn (MOCK_IDP_KIBANA_BASE_PATH).
# For basic license, SAML is unsupported — disable the plugin + basePath entirely.
STACK_MOCK_IDP_FLAGS=""
STACK_KBN_URL="http://localhost:5611/kbn"
if [ "$KBN_DEV_ES_STACK_LICENSE" = "basic" ]; then
  STACK_MOCK_IDP_FLAGS="--mockIdpPlugin.enabled=false --no-base-path"
  STACK_KBN_URL="http://localhost:5611"
fi

# --- Vault pre-check for EIS -----------------------------------------------
EIS_VAULT_ADDR="${VAULT_ADDR:-https://secrets.elastic.co:8200}"
EIS_VAULT_SECRET="secret/kibana-issues/dev/inference/kibana-eis-ccm"

setup_eis_vault() {
  if [ "$CCM_ENABLED" = false ]; then
    return
  fi

  if [ -n "$KIBANA_EIS_CCM_API_KEY" ]; then
    echo "  EIS enabled — using KIBANA_EIS_CCM_API_KEY (vault skipped)."
    return
  fi

  echo ""
  echo "============================================="
  echo " EIS — Cloud Connected Mode"
  echo "============================================="
  echo ""
  echo "  URL:     $KBN_DEV_INFERENCE_URL"
  echo "  Vault:   $EIS_VAULT_ADDR"
  echo "  Secret:  $EIS_VAULT_SECRET"
  echo ""

  if ! command -v vault >/dev/null 2>&1; then
    echo "  ERROR: 'vault' CLI not found."
    echo "  To fix: install vault, set KIBANA_EIS_CCM_API_KEY, or set KBN_DEV_INFERENCE_URL=\"\""
    echo "  Continuing without EIS."
    CCM_ENABLED=false
    INFERENCE_FLAG=""
    return
  fi

  while true; do
    if VAULT_ADDR="$EIS_VAULT_ADDR" vault read -field key "$EIS_VAULT_SECRET" >/dev/null 2>&1; then
      echo "  Vault access confirmed. EIS will run after each ES cluster is ready."
      break
    fi

    if [ "$INTERACTIVE" = false ]; then
      echo "  Vault access failed (non-interactive). Continuing without EIS."
      CCM_ENABLED=false
      INFERENCE_FLAG=""
      return
    fi

    echo "  Vault access failed. Log in with:"
    echo ""
    echo "    VAULT_ADDR=$EIS_VAULT_ADDR vault login -method oidc"
    echo ""
    read -r -p "  Press Enter after logging in to retry (or Ctrl+C to abort)... "
    echo ""
  done
  echo ""
  echo "============================================="
}

setup_eis_vault

# --- Print config summary ---------------------------------------------------
open_tmux_logs() {
  tmux kill-session -t kbn-logs 2>/dev/null || true
  tmux new-session -d -s kbn-logs -n logs \
    "tail -f $ESSLS_LOG" \; \
    select-pane -T "ES Serverless" \; \
    split-window -h \
    "tail -f $ESSTACK_LOG" \; \
    select-pane -T "ES Stateful" \; \
    split-window -v \
    "tail -f $KBNSTACK_LOG" \; \
    select-pane -T "Kibana Stack" \; \
    select-pane -t 0 \; \
    split-window -v \
    "tail -f $KBNSLS_LOG" \; \
    select-pane -T "Kibana SLS" \; \
    select-layout tiled \; \
    set pane-border-status top \; \
    set pane-border-format " #{pane_index}: #{pane_title} "
}

echo "============================================="
echo " kbn-dev: Kibana dual-mode dev launcher"
echo "============================================="
echo "  Repo:      $KBN_DIR"
echo "  Clean:     $CLEAN_CACHE"
echo "  EIS:       $([ "$CCM_ENABLED" = true ] && echo "enabled ($KBN_DEV_INFERENCE_URL)" || echo "disabled")"
echo "  ES SLS:    projectType=$KBN_DEV_ES_SLS_PROJECT_TYPE"
echo "  ES Stack:  license=$KBN_DEV_ES_STACK_LICENSE, ml=$KBN_DEV_ES_STACK_ML_ENABLED, saml=$([ -z "$STACK_MOCK_IDP_FLAGS" ] && echo "enabled" || echo "disabled")"
echo "  Optimizer: $([ "$KBN_USE_RSPACK" = "true" ] || [ "$KBN_USE_RSPACK" = "1" ] && echo "rspack" || echo "webpack (legacy)")"
echo "  Browser:   $([ "$LAUNCH_BROWSER" = true ] && echo "Chrome (kbn-sls + kbn-stack profiles)" || echo "disabled")"
echo "  Show logs: $SHOW_LOGS"
echo "============================================="
echo ""
echo " LOGGING"
echo "  Dir: $LOG_DIR"
echo "  Override with: KBN_DEV_LOG_DIR=/your/path"
if [ "$SHOW_LOGS" = true ]; then
  if command -v tmux >/dev/null 2>&1; then
    echo "  Tmux session 'kbn-logs' will be created (detached). Run 'kbn-dev-ctl attach' to open."
    echo "  Use --quiet to skip."
  else
    echo "  WARNING: tmux not found. Install tmux for the log viewer."
    echo "  Falling back to individual tail commands."
    SHOW_LOGS=false
  fi
fi
echo ""
echo "============================================="

if [ "$SHOW_LOGS" = true ]; then
  open_tmux_logs
  echo ""
  echo "  tmux session 'kbn-logs' opened. Attach in another terminal:"
  echo ""
  echo "    tmux attach -t kbn-logs"
  echo ""
fi

write_status "starting"

# =============================================================================
# PHASE 1: Check ports + start Elasticsearch clusters in parallel
# =============================================================================

clean_docker_sls() {
  # Remove stale serverless containers (es01-03, uiam, uiam-cosmosdb)
  local stale_ids
  stale_ids=$(docker ps -aq --filter "label=org.opencontainers.image.url=https://github.com/elastic/kibana" 2>/dev/null)
  if [ -z "$stale_ids" ]; then
    for img in uiam uiam-azure-cosmos-emulator elasticsearch-serverless; do
      stale_ids="$stale_ids $(docker ps -aq --filter "ancestor=docker.elastic.co/kibana-ci/$img:latest-verified" 2>/dev/null)"
    done
  fi
  stale_ids=$(echo "$stale_ids" | xargs)
  if [ -n "$stale_ids" ]; then
    echo "  Removing containers: $stale_ids"
    # shellcheck disable=SC2086
    docker rm -f $stale_ids 2>/dev/null || true
  else
    echo "  No stale containers."
  fi

  # Remove stale 'elastic' Docker network — stale DNS entries from crashed
  # containers can cause uiam to fail resolving uiam-cosmosdb.
  # Force-disconnect any lingering containers first, otherwise rm fails.
  for cid in $(docker network inspect elastic -f '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null); do
    docker network disconnect -f elastic "$cid" 2>/dev/null || true
  done
  docker network rm elastic 2>/dev/null || true
}

log_step "Cleaning up stale kibana-ci Docker resources..."
if command -v docker >/dev/null 2>&1; then
  clean_docker_sls

  dangling=$(docker images -q --filter "dangling=true" --filter "reference=docker.elastic.co/kibana-ci/*" 2>/dev/null | xargs)
  if [ -n "$dangling" ]; then
    echo "  Removing dangling images: $dangling"
    # shellcheck disable=SC2086
    docker rmi $dangling 2>/dev/null || true
  fi

  if [ "$CLEAN_CACHE" = true ]; then
    echo "  --clean: removing all kibana-ci images (will re-pull)..."
    # shellcheck disable=SC2046
    docker rmi $(docker images -q "docker.elastic.co/kibana-ci/*" 2>/dev/null) 2>/dev/null || true
  fi
else
  echo "  Docker not available — skipping."
fi

log_step "Clearing dev ports..."
for port in $KBN_DEV_ES_SLS_PORT $KBN_DEV_ES_STACK_PORT $KBN_DEV_ES_SLS_TRANSPORT_PORT $KBN_DEV_ES_STACK_TRANSPORT_PORT 5601 5611; do
  pid=$(lsof -ti "tcp:$port" 2>/dev/null)
  if [ -n "$pid" ]; then
    proc_name=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
    echo "  Killing PID $pid on port $port ($proc_name)"
    kill "$pid" 2>/dev/null || true
  fi
done

if [ "$CLEAN_CACHE" = true ]; then
  log_step "Cleaning ES cache (.es/cache)..."
  rm -rf "$KBN_DIR/.es/cache/"
fi

log_step "Starting ES Serverless..." "$ESSLS_LOG"
(
  cd "$KBN_DIR" || exit 1

  run_es_sls() {
    # shellcheck disable=SC2086
    yarn es serverless \
      --projectType "$KBN_DEV_ES_SLS_PROJECT_TYPE" \
      --clean --kill \
      $KBN_DEV_ES_SLS_EXTRA_ARGS \
      $INFERENCE_FLAG
  }

  # Retry up to 3 times in case of uiam/cosmosdb startup race.
  # Between attempts, tear down the Docker network so uiam gets fresh DNS.
  max_attempts=3
  attempt=0
  succeeded=false
  while [ $attempt -lt $max_attempts ]; do
    attempt=$((attempt + 1))
    if [ $attempt -gt 1 ]; then
      echo ""
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cleaning Docker network before retry..."
      clean_docker_sls
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] ES Serverless attempt $attempt/$max_attempts..."
    fi

    run_es_sls && { succeeded=true; break; }

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ES Serverless attempt $attempt/$max_attempts failed (uiam/cosmosdb startup race)."
    sleep 5
  done

  # Nuclear fallback: full image purge + network teardown, then one last try.
  if [ "$succeeded" = false ]; then
    echo ""
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] All $max_attempts attempts failed. Running full Docker cleanup (equivalent to --clean)..."
    clean_docker_sls
    # shellcheck disable=SC2046
    docker rmi $(docker images -q "docker.elastic.co/kibana-ci/*" 2>/dev/null) 2>/dev/null || true
    docker volume prune -f 2>/dev/null || true
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ES Serverless final attempt (after full cleanup)..."
    run_es_sls
  fi
) >> "$ESSLS_LOG" 2>&1 &
ESSLS_PID=$!

log_step "Starting ES Stateful (snapshot)..." "$ESSTACK_LOG"
(
  cd "$KBN_DIR" || exit 1
  # shellcheck disable=SC2086
  yarn es snapshot \
    --license "$KBN_DEV_ES_STACK_LICENSE" --clean \
    --kibanaUrl "$STACK_KBN_URL" \
    -E http.port=$KBN_DEV_ES_STACK_PORT \
    -E transport.port=$KBN_DEV_ES_STACK_TRANSPORT_PORT \
    -E xpack.ml.enabled="$KBN_DEV_ES_STACK_ML_ENABLED" \
    $KBN_DEV_ES_STACK_EXTRA_ARGS \
    $INFERENCE_FLAG
) >> "$ESSTACK_LOG" 2>&1 &
ESSTACK_PID=$!

write_status "es_starting"

# =============================================================================
# PHASE 2: Bootstrap and build optimizer
# =============================================================================

(
  cd "$KBN_DIR" || exit 1
  if [ "$CLEAN_CACHE" = true ]; then
    log_step "Running yarn kbn clean..." "$MAIN_LOG"
    yarn kbn clean || exit 1
  fi
  log_step "Running yarn kbn bootstrap..." "$MAIN_LOG"
  yarn kbn bootstrap || exit 1
) >> "$MAIN_LOG" 2>&1
BOOTSTRAP_EXIT=$?

if [ $BOOTSTRAP_EXIT -ne 0 ]; then
  log_step "ERROR: Bootstrap failed (exit $BOOTSTRAP_EXIT). Check $MAIN_LOG"
  echo "  Tip: run 'yarn kbn bootstrap' manually to see the full error."
  cleanup
fi

USE_RSPACK=false
if [ "$KBN_USE_RSPACK" = "true" ] || [ "$KBN_USE_RSPACK" = "1" ]; then
  USE_RSPACK=true
fi

if [ "$USE_RSPACK" = true ]; then
  log_step "Starting rspack optimizer (watch mode)..."
  (
    cd "$KBN_DIR" || exit 1
    node scripts/build_rspack_bundles.js --watch
  ) >> "$OPTIMIZER_LOG" 2>&1 &
  OPTIMIZER_PID=$!

  log_step "Waiting for rspack initial build..."
  if wait_for_log "$OPTIMIZER_LOG" "RSPack build completed\|Watching for changes" "$OPTIMIZER_PID" "Rspack Optimizer"; then
    log_step "Rspack optimizer build complete!"
  fi
else
  log_step "Starting webpack optimizer (watch mode)..."
  (
    cd "$KBN_DIR" || exit 1
    node scripts/build_kibana_platform_plugins --watch
  ) >> "$OPTIMIZER_LOG" 2>&1 &
  OPTIMIZER_PID=$!

  log_step "Waiting for optimizer initial build..."
  if wait_for_log "$OPTIMIZER_LOG" "succ.*bundles compiled successfully\|succ all bundles cached" "$OPTIMIZER_PID" "Optimizer"; then
    log_step "Optimizer build complete!"
  fi
fi

write_status "optimizer_ready"

# =============================================================================
# PHASE 3: Wait for ES → run EIS → start Kibana
# =============================================================================

start_kbnsls() {
  kill_port 5601
  log_step "Starting Kibana Serverless (port 5601)..." "$KBNSLS_LOG"
  (
    cd "$KBN_DIR" || exit 1
    export KBN_OPTIMIZER_USE_MAX_AVAILABLE_RESOURCES=false
    yarn serverless-es \
      --server.port=5601 \
      --no-optimizer
  ) >> "$KBNSLS_LOG" 2>&1
}

start_kbnstack() {
  kill_port 5611
  log_step "Starting Kibana Stateful (port 5611)..." "$KBNSTACK_LOG"
  (
    cd "$KBN_DIR" || exit 1
    export KBN_OPTIMIZER_USE_MAX_AVAILABLE_RESOURCES=false
    # shellcheck disable=SC2086
    yarn start \
      --elasticsearch http://localhost:$KBN_DEV_ES_STACK_PORT \
      --server.port=5611 \
      --xpack.security.cookieName=sid-stack \
      --no-optimizer \
      $STACK_MOCK_IDP_FLAGS
  ) >> "$KBNSTACK_LOG" 2>&1
}

needs_bootstrap() {
  local logfile="$1"
  local tail_lines
  tail_lines=$(tail -80 "$logfile" 2>/dev/null)
  if echo "$tail_lines" | grep -qE "Cannot find module|MODULE_NOT_FOUND|ENOENT.*node_modules"; then
    return 0
  fi
  return 1
}

run_bootstrap() {
  local clean="$1"
  log_step "Running auto-bootstrap (clean=$clean)..." "$MAIN_LOG"
  (
    cd "$KBN_DIR" || return 1
    if [ "$clean" = true ]; then
      yarn kbn clean >> "$MAIN_LOG" 2>&1 || true
    fi
    yarn kbn bootstrap >> "$MAIN_LOG" 2>&1
  )
  return $?
}

monitor_process() {
  local name="$1" start_fn="$2" logfile="$3"
  local failures=0 max_failures=3
  local bootstrap_attempts=0 max_bootstrap=2

  while true; do
    $start_fn &
    local pid=$!
    wait $pid
    local exit_code=$?

    if [ $exit_code -eq 130 ] || [ $exit_code -eq 143 ]; then
      break
    elif [ $exit_code -ne 0 ]; then
      failures=$((failures + 1))
      log_step "$name exited with code $exit_code (attempt $failures/$max_failures)" "$logfile"

      if needs_bootstrap "$logfile"; then
        bootstrap_attempts=$((bootstrap_attempts + 1))
        if [ $bootstrap_attempts -le $max_bootstrap ]; then
          local do_clean=false
          [ $bootstrap_attempts -gt 1 ] && do_clean=true
          log_step "$name crashed due to missing module — auto-bootstrapping (attempt $bootstrap_attempts/$max_bootstrap, clean=$do_clean)..." "$logfile"
          if run_bootstrap "$do_clean"; then
            log_step "Bootstrap succeeded. Restarting $name..."
            failures=$((failures - 1))
            sleep 2
            continue
          else
            log_step "Bootstrap failed. Check $MAIN_LOG" "$logfile"
          fi
        else
          log_step "$name still failing after $max_bootstrap bootstrap attempts." "$logfile"
        fi
      fi

      if [ $failures -lt $max_failures ]; then
        log_step "Restarting $name in 5s..."
        sleep 5
      else
        log_step "$name exceeded max retries ($max_failures). Giving up."
        kill $$ 2>/dev/null
        exit 1
      fi
    else
      log_step "$name exited cleanly (code 0)"
      break
    fi
  done
}

wait_for_es_http() {
  local port="$1" label="$2" max_wait="${3:-30}"
  local elapsed=0
  log_step "Waiting for $label HTTP endpoint on port $port..."
  while [ $elapsed -lt $max_wait ]; do
    # Serverless uses HTTPS (self-signed), stateful uses HTTP — try both.
    if curl -sk -o /dev/null -w '' "https://localhost:$port/" 2>/dev/null; then
      log_step "$label HTTP endpoint ready (https, ${elapsed}s)"
      return 0
    fi
    if curl -s -o /dev/null -w '' "http://localhost:$port/" 2>/dev/null; then
      log_step "$label HTTP endpoint ready (http, ${elapsed}s)"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  log_step "WARNING: $label HTTP endpoint not reachable after ${max_wait}s — EIS may fail."
  return 1
}

run_es_to_kibana_pipeline() {
  local es_label="$1" es_log="$2" es_pid="$3" es_ready_pattern="$4"
  local kbn_label="$5" kbn_start_fn="$6" kbn_log="$7" kbn_pidfile="$8"
  local es_port="${9:-9200}"
  local ccm_target="${10:---sls}"  # --sls or --stack

  log_step "Waiting for $es_label to be ready..."
  if ! wait_for_log "$es_log" "$es_ready_pattern" "$es_pid" "$es_label"; then
    return 1
  fi

  log_step "$es_label is ready!"

  if [ "$CCM_ENABLED" = true ]; then
    wait_for_es_http "$es_port" "$es_label"

    local eis_ok=false
    for eis_attempt in 1 2 3; do
      log_step "Running EIS setup for $es_label (attempt $eis_attempt/3, ES_PORT=$es_port)..."
      if CCM_API_KEY="${KIBANA_EIS_CCM_API_KEY:-}" \
         VAULT_ADDR="$EIS_VAULT_ADDR" \
         ES_PORT="$es_port" \
         kbn-dev-ccm "$ccm_target" >> "$MAIN_LOG" 2>&1; then
        eis_ok=true
        break
      fi
      log_step "EIS setup for $es_label failed (attempt $eis_attempt/3)."
      sleep 3
    done
    if [ "$eis_ok" = false ]; then
      log_step "WARNING: EIS setup failed for $es_label after 3 attempts. Kibana will start without EIS."
    fi
  fi

  monitor_process "$kbn_label" "$kbn_start_fn" "$kbn_log" &
  echo "$!" > "$kbn_pidfile"
  wait
}

# Serverless pipeline (background)
(
  run_es_to_kibana_pipeline \
    "ES Serverless" "$ESSLS_LOG" "$ESSLS_PID" "succ Serverless ES cluster running" \
    "kbnsls" start_kbnsls "$KBNSLS_LOG" "$LOG_DIR/kbnsls.pid" "$KBN_DEV_ES_SLS_PORT" "--sls"
) &

# Stateful pipeline (background)
(
  run_es_to_kibana_pipeline \
    "ES Stateful" "$ESSTACK_LOG" "$ESSTACK_PID" "succ ES cluster is ready" \
    "kbnstack" start_kbnstack "$KBNSTACK_LOG" "$LOG_DIR/kbnstack.pid" "$KBN_DEV_ES_STACK_PORT" "--stack"
) &

# =============================================================================
# PHASE 4: Wait for Kibana → open browser → report
# =============================================================================

SLS_READY=false
STACK_READY=false
SLS_WAIT_DONE=false
STACK_WAIT_DONE=false

# Wait for both in parallel using background subshells and marker files
SLS_MARKER="$LOG_DIR/.sls_ready"
STACK_MARKER="$LOG_DIR/.stack_ready"
rm -f "$SLS_MARKER" "$STACK_MARKER"

(
  if wait_for_kibana "Kibana Serverless" "$KBNSLS_LOG" "$ESSLS_PID" "$LOG_DIR/kbnsls.pid" 5601; then
    touch "$SLS_MARKER"
  fi
) &
SLS_WAIT_PID=$!

(
  if wait_for_kibana "Kibana Stateful" "$KBNSTACK_LOG" "$ESSTACK_PID" "$LOG_DIR/kbnstack.pid" 5611; then
    touch "$STACK_MARKER"
  fi
) &
STACK_WAIT_PID=$!

# Wait for both to finish
wait $SLS_WAIT_PID 2>/dev/null
wait $STACK_WAIT_PID 2>/dev/null

if [ -f "$SLS_MARKER" ]; then
  log_step "Kibana Serverless is available at http://localhost:5601"
  SLS_READY=true
  open_chrome "http://localhost:5601" "$SLS_PROFILE"
  SLS_CHROME_PID="$LAST_CHROME_PID"
fi

if [ -f "$STACK_MARKER" ]; then
  log_step "Kibana Stateful is available at $STACK_KBN_URL"
  STACK_READY=true
  open_chrome "$STACK_KBN_URL" "$STACK_PROFILE"
  STACK_CHROME_PID="$LAST_CHROME_PID"
fi

rm -f "$SLS_MARKER" "$STACK_MARKER"

# --- Read child PIDs --------------------------------------------------------
[ -f "$LOG_DIR/kbnsls.pid" ]  && KBNSLS_PID=$(cat "$LOG_DIR/kbnsls.pid")
[ -f "$LOG_DIR/kbnstack.pid" ] && KBNSTACK_PID=$(cat "$LOG_DIR/kbnstack.pid")

# --- Status report ----------------------------------------------------------
if [ "$SLS_READY" = false ] && [ "$STACK_READY" = false ]; then
  write_status "failed"
  echo ""
  echo "============================================="
  echo " STARTUP FAILED"
  echo "============================================="
  echo ""
  echo "  Neither Kibana instance came up. Check the logs:"
  echo "    yarn kbn-dev-ctl logs essls --grep ERROR"
  echo "    yarn kbn-dev-ctl logs esstack --grep ERROR"
  echo ""
  echo "  Common causes: Docker not running, bootstrap needed (--clean), node mismatch."
  echo ""
  cleanup
fi

if [ "$SLS_READY" = false ] || [ "$STACK_READY" = false ]; then
  echo ""
  if [ "$SLS_READY" = false ]; then
    echo "  WARNING: Kibana Serverless failed to start."
    echo "    Check: yarn kbn-dev-ctl logs essls --grep ERROR"
  fi
  if [ "$STACK_READY" = false ]; then
    echo "  WARNING: Kibana Stateful failed to start."
    echo "    Check: yarn kbn-dev-ctl logs esstack --grep ERROR"
  fi
  echo "  Continuing with available instance(s)."
  echo ""
fi

write_status "running"

echo ""
echo "============================================="
echo " STATUS"
echo "============================================="
echo ""
[ "$SLS_READY" = true ]   && echo "  [OK]     Kibana Serverless:  http://localhost:5601" \
                           || echo "  [FAILED] Kibana Serverless — check $KBNSLS_LOG"
[ "$STACK_READY" = true ]  && echo "  [OK]     Kibana Stateful:    $STACK_KBN_URL" \
                           || echo "  [FAILED] Kibana Stateful — check $KBNSTACK_LOG"
echo ""
echo "  PIDs:"
echo "    Optimizer:        $OPTIMIZER_PID"
echo "    ES Serverless:    $ESSLS_PID"
echo "    ES Stateful:      $ESSTACK_PID"
echo "    Kibana SLS:       ${KBNSLS_PID:-(not started)}"
echo "    Kibana Stack:     ${KBNSTACK_PID:-(not started)}"
[ -n "$SLS_CHROME_PID" ]   && echo "    Chrome SLS:       $SLS_CHROME_PID"
[ -n "$STACK_CHROME_PID" ] && echo "    Chrome Stack:     $STACK_CHROME_PID"
echo ""
echo "  Logs: $LOG_DIR"
if [ "$SHOW_LOGS" = true ]; then
  echo "  View: tmux attach -t kbn-logs"
else
  echo "  View: tail -f $LOG_DIR/*.log"
fi
echo ""
echo "============================================="
echo "Press Ctrl+C to stop all processes."

wait
