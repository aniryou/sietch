#!/usr/bin/env bash
# Symlink the sietch CLI into ~/.local/bin so it's available on $PATH.
# Idempotent — safe to run repeatedly after `git pull` in this repo.

set -u
set -o pipefail

SIETCH_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${SIETCH_INSTALL_DIR:-$HOME/.local/bin}"
mkdir -p "$TARGET_DIR"

LINK="$TARGET_DIR/st"
SOURCE="$SIETCH_HOME/bin/st"

if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$SOURCE" ]; then
  echo "[install] $LINK already linked; nothing to do."
else
  ln -sfn "$SOURCE" "$LINK"
  echo "[install] linked $LINK → $SOURCE"
fi

chmod +x "$SIETCH_HOME/bin/st" \
         "$SIETCH_HOME/wrappers"/*.sh \
         "$SIETCH_HOME/lib"/*.sh

case ":$PATH:" in
  *":$TARGET_DIR:"*) ;;
  *) echo "[install] WARN: $TARGET_DIR is not on \$PATH. Add it to your shell rc." ;;
esac

echo "[install] done. Run 'st help' to verify."
