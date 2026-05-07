#!/usr/bin/env bash
# Symlink the loop CLI into ~/.local/bin so it's available on $PATH.
# Idempotent — safe to run repeatedly after `git pull` in this repo.

set -u
set -o pipefail

LOOP_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${LOOP_INSTALL_DIR:-$HOME/.local/bin}"
mkdir -p "$TARGET_DIR"

LINK="$TARGET_DIR/st"
SOURCE="$LOOP_HOME/bin/st"

if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$SOURCE" ]; then
  echo "[install] $LINK already linked; nothing to do."
else
  ln -sfn "$SOURCE" "$LINK"
  echo "[install] linked $LINK → $SOURCE"
fi

chmod +x "$LOOP_HOME/bin/st" \
  "$LOOP_HOME/runners"/*.sh \
  "$LOOP_HOME/runners/lib"/*.sh

case ":$PATH:" in
  *":$TARGET_DIR:"*) ;;
  *) echo "[install] WARN: $TARGET_DIR is not on \$PATH. Add it to your shell rc." ;;
esac

echo "[install] done. Run 'st help' to verify."
