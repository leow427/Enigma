#!/bin/sh

# Redraws the app icon (the AppIcon set) and the menu bar template
# (EnigmaMenuBarMark) from the character's own Swift drawing code, through
# EnigmaIconTests. Run it after changing the character's drawing or
# EnigmaAppIcon; EnigmaIconTests fails until the committed copies match.

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# xcodebuild passes TEST_RUNNER_-prefixed variables to the test host without the prefix.
TEST_RUNNER_ENIGMA_ICON_ASSET_DIR="$repository_root/Enigma/Resources/Assets.xcassets" \
  "$repository_root/scripts/verify-xcode.sh" test \
  -only-testing:EnigmaTests/EnigmaIconTests/testGenerateAppIdentityAssets \
  "$@"
