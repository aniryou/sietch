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

# Bootstrap pre-commit so shellcheck/shfmt run on `git commit` instead of
# only in CI (GH#167). Skip cleanly if any prerequisite is missing — the
# install must succeed even on machines without pre-commit installed, and
# must never overwrite a custom hook the user already has in place.
install_precommit() {
  if ! command -v pre-commit >/dev/null 2>&1; then
    echo "[install] skipping pre-commit install: 'pre-commit' not on \$PATH."
    return 0
  fi
  if [ ! -f "$LOOP_HOME/.pre-commit-config.yaml" ]; then
    echo "[install] skipping pre-commit install: .pre-commit-config.yaml not at repo root."
    return 0
  fi
  local hook="$LOOP_HOME/.git/hooks/pre-commit"
  if [ ! -f "$hook" ]; then
    (cd "$LOOP_HOME" && pre-commit install) >/dev/null
    echo "[install] ran 'pre-commit install'."
    return 0
  fi
  if grep -qi 'pre-commit' "$hook"; then
    echo "[install] skipping pre-commit install: hook already present at $hook."
    return 0
  fi
  # Stock git sample hook — safe to replace. Anything else without the
  # 'pre-commit' marker is treated as a user-authored hook and left alone.
  if grep -qi 'example hook' "$hook"; then
    (cd "$LOOP_HOME" && pre-commit install --overwrite) >/dev/null
    echo "[install] ran 'pre-commit install --overwrite' (replaced stock sample)."
    return 0
  fi
  echo "[install] skipping pre-commit install: existing custom hook at $hook (not overwriting)."
}
install_precommit

case ":$PATH:" in
  *":$TARGET_DIR:"*) ;;
  *) echo "[install] WARN: $TARGET_DIR is not on \$PATH. Add it to your shell rc." ;;
esac

echo "[install] done. Run 'st help' to verify."
