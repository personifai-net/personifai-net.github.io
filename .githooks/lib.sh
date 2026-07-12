#!/usr/bin/env bash
# Shared helpers for WORKTREES.md enforcement hooks.
# Sourced by pre-commit and reference-transaction.

is_main_clone() {
  local gd cd_
  gd=$(git rev-parse --git-dir 2>/dev/null) || return 1
  cd_=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
  [ "$(cd "$gd" && pwd)" = "$(cd "$cd_" && pwd)" ]
}
