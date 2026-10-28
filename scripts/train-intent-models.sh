#!/bin/zsh
# Trains Enigma's intent models from IntentTraining/ (see docs/superpowers/plans/2026-10-27-f31-intent-models.md).
#   scripts/train-intent-models.sh [--data <dir>] [--out <dir>] [--check] [--kind maxEnt|bert] <skill>...
# The trainer is compiled from the same IntentText.swift and IntentSkill.swift the app uses.
set -euo pipefail

cd "${0:A:h}/.."
build=$(mktemp -d "${TMPDIR:-/tmp}/enigma-intent-training.XXXXXX")
trap 'rm -rf "$build"' EXIT

xcrun swiftc -O -parse-as-library -module-name IntentTrainer -o "$build/train" \
  IntentTraining/train.swift \
  IntentTraining/IntentTrainingSupport.swift \
  Enigma/Intent/IntentText.swift \
  Enigma/Intent/IntentSkill.swift
"$build/train" "$@"
