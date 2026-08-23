#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
expected="$(cat "$project_root/.xcode-version")"
actual="$(xcodebuild -version)"

if [[ "$actual" != "$expected" ]]; then
  print -u2 "CodexGauge requires this release toolchain:"
  print -u2 "$expected"
  print -u2 "Current toolchain:"
  print -u2 "$actual"
  exit 1
fi
