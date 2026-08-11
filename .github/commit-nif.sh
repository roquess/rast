#!/usr/bin/env bash
# Commit a freshly built per-platform NIF back to main (used by build-nif.yml).
# Usage: commit-nif.sh <path> <label>
set -euo pipefail

FILE="$1"
LABEL="$2"

git config user.name  "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
git add "$FILE"

if git diff --staged --quiet; then
  echo "$FILE unchanged, nothing to commit"
else
  git commit -m "ci: update $LABEL NIF [skip ci]"
  git pull --rebase --autostash origin main
  git push
fi
