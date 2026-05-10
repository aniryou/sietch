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

# Warn if locally installed shellcheck/shfmt versions don't match what CI
# pins. The hooks in .pre-commit-config.yaml use `language: system`, so they
# invoke whatever's on $PATH — a version mismatch lets a green `git commit`
# ship a red CI lint, which GH#167 exists to prevent. Source of truth is
# the SHELLCHECK_VERSION / SHFMT_VERSION lines in .github/workflows/ci.yml,
# parsed below so install.sh doesn't become a third place for the version.
check_lint_tool_versions() {
  local ci="$LOOP_HOME/.github/workflows/ci.yml"
  [ -f "$ci" ] || return 0
  local pinned_shellcheck pinned_shfmt
  pinned_shellcheck=$(awk -F= '/^[[:space:]]*SHELLCHECK_VERSION=/ {sub(/^v/, "", $2); gsub(/[[:space:]]/, "", $2); print $2; exit}' "$ci")
  pinned_shfmt=$(awk -F= '/^[[:space:]]*SHFMT_VERSION=/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "$ci")

  if [ -n "$pinned_shellcheck" ] && command -v shellcheck >/dev/null 2>&1; then
    local installed_sc
    installed_sc=$(shellcheck --version 2>/dev/null | awk '/^version:/ {print $2; exit}')
    if [ -n "$installed_sc" ] && [ "$installed_sc" != "$pinned_shellcheck" ]; then
      echo "[install] WARN: shellcheck $installed_sc installed but CI pins v$pinned_shellcheck (see .github/workflows/ci.yml). Local pre-commit may diverge from CI lint — install matching version to close the gap."
    fi
  fi

  if [ -n "$pinned_shfmt" ] && command -v shfmt >/dev/null 2>&1; then
    local installed_sf
    installed_sf=$(shfmt --version 2>/dev/null | head -1 | tr -d '[:space:]')
    if [ -n "$installed_sf" ] && [ "$installed_sf" != "$pinned_shfmt" ]; then
      echo "[install] WARN: shfmt $installed_sf installed but CI pins $pinned_shfmt (see .github/workflows/ci.yml). Local pre-commit may diverge from CI lint — install matching version to close the gap."
    fi
  fi
  return 0
}
check_lint_tool_versions

case ":$PATH:" in
  *":$TARGET_DIR:"*) ;;
  *) echo "[install] WARN: $TARGET_DIR is not on \$PATH. Add it to your shell rc." ;;
esac

echo "[install] done. Run 'st help' to verify."
