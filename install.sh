#!/usr/bin/env bash
# Put the claude-otel wrapper on your PATH by symlinking it into a bin directory.
# The link points back into this repo, so keep the repo where it is (git pull updates it).
#
#   ./install.sh [--bin-dir DIR] [--force]       install (default DIR: ~/.local/bin)
#   ./install.sh uninstall [--bin-dir DIR] [--force]   remove the link
#
# A link left behind by a checkout that was moved or deleted is replaced or removed without
# --force. A link to another checkout that still exists needs --force to switch or remove.
# A file or directory that is not one of our links is never removed.
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
    -h|--help)         sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                 die "unknown argument: $1 (try --help)" ;;
  esac
done

LINK="$BIN_DIR/claude-otel"
[ -f "$TARGET" ] || die "$TARGET not found"
[ -f "$ROOT/kit/kit.yaml" ] || die "$ROOT/kit/kit.yaml not found"

# What is at $LINK?
#   absent    nothing there
#   ours      a link to this checkout's wrapper
#   stale     a link to a .../bin/claude-otel that no longer exists (moved or deleted checkout)
#   other     a link to a .../bin/claude-otel in another checkout that still exists
#   dir       a real directory
#   foreign   anything else
link_state() {
  local dest
  if [ -L "$LINK" ]; then
    dest="$(readlink "$LINK")"
    if [ "$dest" = "$TARGET" ]; then echo ours; return; fi
    case "$dest" in
      */bin/claude-otel) if [ -e "$LINK" ]; then echo other; else echo stale; fi ;;
      *) echo foreign ;;
    esac
  elif [ -d "$LINK" ]; then echo dir
  elif [ -e "$LINK" ]; then echo foreign
  else echo absent
  fi
}

STATE="$(link_state)"

case "$ACTION" in
  install)
    chmod +x "$TARGET"
    mkdir -p "$BIN_DIR"
    case "$STATE" in
      ours)    echo "already installed: $LINK -> $TARGET" ;;
      absent)  ln -s "$TARGET" "$LINK"; echo "installed: $LINK -> $TARGET" ;;
      stale)   ln -sfn "$TARGET" "$LINK"
               echo "replaced a stale link (its checkout is gone): $LINK -> $TARGET" ;;
      other)   [ "$FORCE" = 1 ] || die "$LINK points at another checkout ($(readlink "$LINK")); use --force to switch it to this one"
               ln -sfn "$TARGET" "$LINK"; echo "switched: $LINK -> $TARGET" ;;
      dir)     die "$LINK is a directory; not touching it" ;;
      foreign) [ "$FORCE" = 1 ] || die "$LINK already exists and is not a link to a claude-otel checkout; use --force to replace it"
               ln -sfn "$TARGET" "$LINK"; echo "replaced: $LINK -> $TARGET" ;;
    esac

    case ":$PATH:" in
      *":$BIN_DIR:"*) ;;
      *) echo "note: $BIN_DIR is not on your PATH. Add this to your shell profile:"
         echo "  export PATH=\"$BIN_DIR:\$PATH\"" ;;
    esac
    command -v sbx >/dev/null 2>&1 || echo "note: sbx not found on PATH; install Docker Sandboxes (v0.51.0 or later) first"
    if ! command -v otel-desktop-viewer >/dev/null 2>&1; then
      echo "note: otel-desktop-viewer is not installed. Install it with:"
      echo "  brew tap ctrlspice/otel-desktop-viewer && brew install --cask otel-desktop-viewer"
    fi
    echo "try: claude-otel --help"
    ;;
  uninstall)
    case "$STATE" in
      ours)    rm "$LINK"; echo "removed $LINK" ;;
      stale)   rm "$LINK"; echo "removed a stale link (its checkout is gone): $LINK" ;;
      other)   [ "$FORCE" = 1 ] || die "$LINK belongs to another checkout ($(readlink "$LINK")); run that checkout's install.sh uninstall, or use --force"
               rm "$LINK"; echo "removed $LINK (it pointed at another checkout)" ;;
      dir)     die "$LINK is a directory; not touching it" ;;
      foreign) die "$LINK is not a link to a claude-otel checkout; leaving it alone" ;;
      absent)  echo "nothing to remove at $LINK" ;;
    esac
    ;;
esac
