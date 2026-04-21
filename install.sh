#!/bin/bash
# ---------------------------------------------------------------------------
# kbn-dev-tools installer
#
# Installs kbn-dev and kbn-dev-ctl scripts + Claude Code agent skills for
# managing a local Kibana dual-mode dev environment (serverless + stateful).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/<org>/kbn-dev-tools/main/install.sh | bash
#   # or
#   git clone https://github.com/<org>/kbn-dev-tools && cd kbn-dev-tools && ./install.sh
#
# What it does:
#   1. Copies kbn-dev and kbn-dev-ctl to ~/.local/bin/ (added to PATH)
#   2. Installs Claude Code agent skills to ~/.claude/skills/ and ~/.agents/skills/
#   3. Verifies prerequisites (Docker; optionally a node version manager)
#
# Prerequisites:
#   - Docker
#   - A node version manager (optional: nvm, fnm, volta, mise, or asdf)
#     If detected, kbn-dev will auto-switch to kibana's required Node version.
#     Without one, you must ensure the correct Node version is active yourself.
# ---------------------------------------------------------------------------

set -euo pipefail

INSTALL_DIR="${KBN_DEV_TOOLS_DIR:-$HOME/.local/bin}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo "======================================"
echo " kbn-dev-tools installer"
echo "======================================"
echo ""

# --- Locate source scripts ------------------------------------------------
find_scripts() {
  if [ -f "$SCRIPT_DIR/scripts/kbn_dev.sh" ]; then
    echo "$SCRIPT_DIR/scripts"
  elif [ -f "$SCRIPT_DIR/kbn_dev.sh" ]; then
    echo "$SCRIPT_DIR"
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
echo "Installing scripts to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"

cp "$SCRIPTS_SRC/kbn_dev.sh" "$INSTALL_DIR/kbn-dev"
cp "$SCRIPTS_SRC/kbn_dev_ctl.sh" "$INSTALL_DIR/kbn-dev-ctl"
chmod +x "$INSTALL_DIR/kbn-dev" "$INSTALL_DIR/kbn-dev-ctl"

echo "  Installed: $INSTALL_DIR/kbn-dev"
echo "  Installed: $INSTALL_DIR/kbn-dev-ctl"

# --- Ensure PATH includes install dir -------------------------------------
path_ok=false
case ":$PATH:" in
  *":$INSTALL_DIR:"*) path_ok=true ;;
esac

if [ "$path_ok" = false ]; then
  shell_rc=""
  case "${SHELL:-}" in
    */zsh)  shell_rc="$HOME/.zshrc" ;;
    */bash) shell_rc="$HOME/.bashrc" ;;
  esac

  if [ -n "$shell_rc" ] && grep -qF "$INSTALL_DIR" "$shell_rc" 2>/dev/null; then
    echo "  [OK] PATH entry already in $shell_rc (source it to activate)"
  elif [ -n "$shell_rc" ]; then
    echo ""
    echo "  $INSTALL_DIR is not in your PATH."
    echo "  Adding to $shell_rc..."
    echo "" >> "$shell_rc"
    echo "# kbn-dev-tools" >> "$shell_rc"
    echo "export PATH=\"$INSTALL_DIR:\$PATH\"" >> "$shell_rc"
    echo "  Done. Run: source $shell_rc"
  else
    echo ""
    echo "  $INSTALL_DIR is not in your PATH."
    echo "  Add this to your shell profile:"
    echo "    export PATH=\"$INSTALL_DIR:\$PATH\""
  fi
fi

echo ""

# --- Install Claude Code skills -------------------------------------------
echo "Installing Claude Code agent skills..."

SKILLS_SRC="$SCRIPT_DIR/skills"
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

# --- Done -----------------------------------------------------------------
echo "======================================"
echo " Installation complete!"
echo "======================================"
echo ""
echo "  Commands:"
echo "    kbn-dev            Start Kibana (serverless + stateful)"
echo "    kbn-dev-ctl        Control plane (status, logs, restart, stop)"
echo ""
echo "  Usage (from your kibana repo root):"
echo "    cd <your-kibana-repo>"
echo "    kbn-dev --quiet       # start in background"
echo "    kbn-dev-ctl status    # check health"
echo "    kbn-dev-ctl attach    # open tmux log viewer"
echo ""
echo "  Claude Code skills:"
echo "    /kbn-dev              # start/stop/restart"
echo "    /kbn-dev-status       # quick status check"
echo ""
