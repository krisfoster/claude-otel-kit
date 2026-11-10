#!/usr/bin/env bash
# Put the claude-otel wrapper on your PATH by symlinking it into a bin directory.
# The link points back into this repo, so keep the repo where it is (git pull updates it).
#
#   ./install.sh [--bin-dir DIR] [--force]    install (default DIR: ~/.local/bin)
#   ./install.sh uninstall [--bin-dir DIR]    remove the link, only if it is ours
set -euo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$ROOT/bin/claude-otel"
BIN_DIR="${HOME}/.local/bin"
FORCE=0
ACTION=install

die() { echo "install.sh: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    install|uninstall) ACTION="$1"; shift ;;
    --bin-dir)         BIN_DIR="${2:?--bin-dir needs a value}"; shift 2 ;;
    --force)           FORCE=1; shift ;;
    -h|--help)         sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                 die "unknown argument: $1 (try --help)" ;;
  esac
done

LINK="$BIN_DIR/claude-otel"
[ -f "$TARGET" ] || die "$TARGET not found"
[ -f "$ROOT/kit/kit.yaml" ] || die "$ROOT/kit/kit.yaml not found"

is_ours() { [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$TARGET" ]; }

case "$ACTION" in
  install)
    chmod +x "$TARGET"
    mkdir -p "$BIN_DIR"
    if is_ours; then
      echo "already installed: $LINK -> $TARGET"
    elif [ -e "$LINK" ] || [ -L "$LINK" ]; then
      [ "$FORCE" = 1 ] || die "$LINK already exists and is not a link to this repo; use --force to replace it"
      ln -sfn "$TARGET" "$LINK"
      echo "replaced: $LINK -> $TARGET"
    else
      ln -s "$TARGET" "$LINK"
      echo "installed: $LINK -> $TARGET"
    fi

    case ":$PATH:" in
      *":$BIN_DIR:"*) ;;
      *) echo "note: $BIN_DIR is not on your PATH. Add this to your shell profile:"
         echo "  export PATH=\"$BIN_DIR:\$PATH\"" ;;
    esac
    command -v sbx >/dev/null 2>&1 || echo "note: sbx not found on PATH; install Docker Sandboxes (v0.45 or later) first"
    if ! command -v otel-desktop-viewer >/dev/null 2>&1; then
      echo "note: otel-desktop-viewer is not installed. Install it with:"
      echo "  brew tap ctrlspice/otel-desktop-viewer && brew install --cask otel-desktop-viewer"
    fi
    echo "try: claude-otel --help"
    ;;
  uninstall)
    if is_ours; then
      rm "$LINK"
      echo "removed $LINK"
    elif [ -e "$LINK" ] || [ -L "$LINK" ]; then
      die "$LINK is not a link to this repo; leaving it alone"
    else
      echo "nothing to remove at $LINK"
    fi
    ;;
esac
