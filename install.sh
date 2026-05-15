#!/bin/bash
# ---------------------------------------------------------------------------
# kbn-dev-tools installer
#
# Installs kbn-dev and kbn-dev-ctl scripts + Claude Code agent skills for
# managing a local Kibana dual-mode dev environment (serverless + stateful).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/wildemat/kbn-dev-tools/main/install.sh | bash
#   # or
#   git clone https://github.com/wildemat/kbn-dev-tools && cd kbn-dev-tools && ./install.sh
#
# What it does:
#   1. Installs kbn-dev, kbn-dev-ctl, and kbn-dev-ccm to ~/.local/bin/ (added to PATH).
#      - When run from a local checkout: symlinks (so repo edits go live).
#      - When run via curl | sh: copies (the bootstrap tmpdir is ephemeral).
#      - Override with KBN_DEV_INSTALL_MODE=copy or =symlink.
#   2. Creates ~/.kbn-dev/.env from the .env.dev template (if missing).
#   3. Installs Claude Code agent skills to ~/.claude/skills/ (and ~/.agents/skills/ if it exists).
#   4. Verifies prerequisites (Docker; optionally a node version manager).
#
# Prerequisites:
#   - Docker
#   - A node version manager (optional: nvm, fnm, volta, mise, or asdf)
#     If detected, kbn-dev will auto-switch to kibana's required Node version.
#     Without one, you must ensure the correct Node version is active yourself.
# ---------------------------------------------------------------------------

set -euo pipefail

REPO="wildemat/kbn-dev-tools"
BRANCH="main"

# When run via curl | sh, $0 is "bash" and there are no local files.
# Bootstrap by downloading the repo tarball and re-executing from there.
# The _KBN_DEV_BOOTSTRAP flag tells the inner run to copy (not symlink) scripts,
# since the tmpdir won't survive past install.
if [ ! -f "$(dirname "$0")/scripts/kbn_dev.sh" ] && [ ! -f "$(dirname "$0")/kbn_dev.sh" ]; then
  echo "Downloading kbn-dev-tools..."
  _tmpdir="$(mktemp -d)"
  trap 'rm -rf "$_tmpdir"' EXIT
  curl -fsSL "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" \
    | tar -xz -C "$_tmpdir" --strip-components=1
  export _KBN_DEV_BOOTSTRAP=1
  exec bash "$_tmpdir/install.sh" "$@"
fi

INSTALL_DIR="${KBN_DEV_TOOLS_DIR:-$HOME/.local/bin}"
KBN_DEV_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo "======================================"
echo " kbn-dev-tools installer"
echo "======================================"
echo ""

# --- Locate source scripts ------------------------------------------------
find_scripts() {
  if [ -f "$KBN_DEV_SCRIPT_DIR/scripts/kbn_dev.sh" ]; then
    echo "$KBN_DEV_SCRIPT_DIR/scripts"
  elif [ -f "$KBN_DEV_SCRIPT_DIR/kbn_dev.sh" ]; then
    echo "$KBN_DEV_SCRIPT_DIR"
  else
    echo ""
  fi
}

SCRIPTS_SRC="$(find_scripts)"
if [ -z "$SCRIPTS_SRC" ]; then
  echo "ERROR: Cannot find kbn_dev.sh and kbn_dev_ctl.sh"
  echo "  Run this script from the kbn-dev-tools directory."
  exit 1
fi

# --- Check prerequisites --------------------------------------------------
echo "Checking prerequisites..."

check_ok=true

node_mgr=""
if [ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]; then
  node_mgr="nvm"
elif command -v fnm >/dev/null 2>&1; then
  node_mgr="fnm"
elif command -v volta >/dev/null 2>&1; then
  node_mgr="volta"
elif command -v mise >/dev/null 2>&1; then
  node_mgr="mise"
elif [ -s "${ASDF_DIR:-$HOME/.asdf}/asdf.sh" ]; then
  node_mgr="asdf"
fi

if [ -n "$node_mgr" ]; then
  echo "  [OK] Node version manager: $node_mgr (will auto-switch to kibana's Node version)"
else
  echo "  [--] No node version manager found (checked nvm, fnm, volta, mise, asdf)."
  echo "       Not required, but you'll need to ensure the correct Node version is active."
  echo "       To enable auto-switching: https://github.com/nvm-sh/nvm or https://github.com/Schniz/fnm"
fi

if command -v docker >/dev/null 2>&1; then
  echo "  [OK] Docker found"
else
  echo "  [!!] Docker not found. Required for ES clusters."
  check_ok=false
fi

if [ "$check_ok" = false ]; then
  echo ""
  echo "  Some prerequisites are missing. Install them and re-run."
  exit 1
fi

echo ""

# --- Install scripts ------------------------------------------------------
# Symlink when running from a real checkout so edits to the repo are picked up
# live (and the scripts/ detection in kbn_dev.sh resolves through the link to
# load the repo's .env). Copy when bootstrapped via curl | sh, since the
# tmpdir vanishes after install. Force copy with KBN_DEV_INSTALL_MODE=copy.
install_mode="${KBN_DEV_INSTALL_MODE:-}"
if [ -z "$install_mode" ]; then
  if [ "${_KBN_DEV_BOOTSTRAP:-0}" = "1" ]; then
    install_mode="copy"
  else
    install_mode="symlink"
  fi
fi

echo "Installing scripts to $INSTALL_DIR ($install_mode)..."
mkdir -p "$INSTALL_DIR"

KBN_DEV_HOME="${KBN_DEV_HOME:-$HOME/.kbn-dev}"
ENV_FILE_PATH="$KBN_DEV_HOME/.env"

install_one() {
  local src="$1" dest="$2" pin_env_file="${3:-false}"
  rm -f "$dest"
  if [ "$install_mode" = "symlink" ]; then
    ln -s "$src" "$dest"
  else
    cp "$src" "$dest"
    chmod +x "$dest"
    # In copy mode, lock KBN_DEV_ENV_FILE to the installed default so the
    # auto-detect block (which resolves scripts/.. when present) doesn't
    # accidentally pick up an unrelated repo's .env. Users can still
    # override by exporting KBN_DEV_ENV_FILE before invoking the command.
    if [ "$pin_env_file" = true ]; then
      local tmpfile
      tmpfile="$(mktemp)"
      {
        head -n 1 "$dest"
        echo ": \"\${KBN_DEV_ENV_FILE:=$ENV_FILE_PATH}\""
        tail -n +2 "$dest"
      } > "$tmpfile"
      mv "$tmpfile" "$dest"
      chmod +x "$dest"
    fi
  fi
}

install_one "$SCRIPTS_SRC/kbn_dev.sh"     "$INSTALL_DIR/kbn-dev"     true
install_one "$SCRIPTS_SRC/kbn_dev_ctl.sh" "$INSTALL_DIR/kbn-dev-ctl" true
install_one "$SCRIPTS_SRC/kbn_dev_ccm.sh" "$INSTALL_DIR/kbn-dev-ccm"

echo "  Installed: $INSTALL_DIR/kbn-dev"
echo "  Installed: $INSTALL_DIR/kbn-dev-ctl"
echo "  Installed: $INSTALL_DIR/kbn-dev-ccm"

# --- Create .env from template if it doesn't exist ------------------------
mkdir -p "$KBN_DEV_HOME"

if [ ! -f "$ENV_FILE_PATH" ] && [ -f "$KBN_DEV_SCRIPT_DIR/.env.dev" ]; then
  cp "$KBN_DEV_SCRIPT_DIR/.env.dev" "$ENV_FILE_PATH"
  echo "  Created:   $ENV_FILE_PATH (from .env.dev — edit to customize)"
else
  echo "  Existing:  $ENV_FILE_PATH (not overwritten)"
fi

# --- Check PATH (informational only — installer never edits shell profiles) -
path_ok=false
case ":$PATH:" in
  *":$INSTALL_DIR:"*) path_ok=true ;;
esac

echo ""

# --- Install Claude Code skills -------------------------------------------
echo "Installing Claude Code agent skills..."

SKILLS_SRC="$KBN_DEV_SCRIPT_DIR/skills"
if [ ! -d "$SKILLS_SRC/kbn-dev" ]; then
  echo "  Skills directory not found at $SKILLS_SRC. Skipping."
else
  SKILLS_DEST="$HOME/.claude/skills"
  mkdir -p "$SKILLS_DEST"

  # Copy skill directories
  for skill_dir in "$SKILLS_SRC"/*/; do
    skill_name="$(basename "$skill_dir")"
    dest="$SKILLS_DEST/$skill_name"
    if [ -d "$dest" ]; then
      echo "  Updating: $skill_name"
      rm -rf "$dest"
    else
      echo "  Installing: $skill_name"
    fi
    cp -r "$skill_dir" "$dest"
  done

  echo ""
  echo "  Skills installed to $SKILLS_DEST"

  # Also install to .agents/skills if the directory exists (Claude Code reads from here)
  AGENTS_DEST="$HOME/.agents/skills"
  if [ -d "$AGENTS_DEST" ] || [ -d "$HOME/.agents" ]; then
    mkdir -p "$AGENTS_DEST"
    for skill_dir in "$SKILLS_SRC"/*/; do
      skill_name="$(basename "$skill_dir")"
      dest="$AGENTS_DEST/$skill_name"
      [ -d "$dest" ] && rm -rf "$dest"
      cp -r "$skill_dir" "$dest"
    done
    echo "  Also installed to $AGENTS_DEST"
  fi
fi

echo ""

echo ""

# --- Done -----------------------------------------------------------------
echo "======================================"
echo " Installation complete!"
echo "======================================"
echo ""
echo "  Commands:"
echo "    kbn-dev            Start Kibana (serverless + stateful)"
echo "    kbn-dev-ctl        Control plane (status, logs, restart, stop)"
echo "    kbn-dev-ccm        Configure EIS/CCM on a running cluster"
echo ""
echo "  Usage (from your kibana repo root):"
echo "    cd <your-kibana-repo>"
echo "    kbn-dev --quiet       # start in background"
echo "    kbn-dev-ctl status    # check health"
echo "    kbn-dev-ctl attach    # open tmux log viewer"
echo ""
echo "  Configuration:"
echo "    Edit $ENV_FILE_PATH to override defaults."
if [ "$install_mode" = "symlink" ]; then
  echo "    Or drop a .env in $KBN_DEV_SCRIPT_DIR/ for repo-local overrides."
fi
echo ""
echo "  Claude Code skills:"
echo "    /kbn-dev              # start/stop/restart"
echo "    /kbn-dev-status       # quick status check"
if [ "$path_ok" = false ]; then
  echo ""
  echo "  >>> $INSTALL_DIR is not on your PATH. Add this to your shell profile:"
  echo ""
  echo "      export PATH=\"$INSTALL_DIR:\$PATH\""
  echo ""
fi
