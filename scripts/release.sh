#!/bin/sh
# Build, sign and publish an Enigma release that installed copies update to
# through Sparkle. See docs/Updates.md.
#
#   scripts/release.sh <version>            release X.Y.Z from a clean, current main
#   scripts/release.sh --dry-run <version>  build and update the appcast in a
#                                           temporary worktree; publish nothing
#
# For the manual end-to-end check, a dry run can build against a test feed:
# ENIGMA_RELEASE_TEST_FEED_URL=<url> scripts/release.sh --dry-run <version>.
# A real release refuses it.
#
# Steps: preflight, bump the version, archive and verify the signature, zip,
# sign the zip and add it to appcast.xml with Sparkle's generate_appcast, then
# publish in an order that never leaves the feed pointing at a missing file:
# commit and tag, push the tag, create the GitHub release, push main.

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_directory="$HOME/Library/Caches/Enigma-Release"
derived_data="$work_directory/DerivedData"
repository_url="https://github.com/leow427/Enigma"

usage() {
  echo "Usage: $0 [--dry-run] <version>" >&2
  exit 64
}

fail() {
  echo "release: $*" >&2
  exit 1
}

say() {
  echo "release: $*"
}

dry_run=false
if [ "${1:-}" = --dry-run ]; then
  dry_run=true
  shift
fi
[ "$#" -eq 1 ] || usage
version=$1
tag="v$version"
test_feed_url=${ENIGMA_RELEASE_TEST_FEED_URL:-}
if [ -n "$test_feed_url" ] && [ "$dry_run" != true ]; then
  fail "ENIGMA_RELEASE_TEST_FEED_URL is only for dry runs"
fi
notes="$repository_root/docs/release-notes/$version.md"
project="Enigma.xcodeproj/project.pbxproj"

# A check that blocks a real release but only warns in a dry run, so the
# script can be exercised from a feature branch.
require() {
  if [ "$dry_run" = true ]; then
    echo "release: warning (dry run): $*" >&2
  else
    fail "$*"
  fi
}

# The single value of an app-target build setting, which appears once per configuration.
setting() {
  values=$(sed -n "s/^[[:space:]]*$1 = \\(.*\\);\$/\\1/p" "$2")
  [ "$(printf '%s\n' "$values" | wc -l | tr -d ' ')" = 2 ] || fail "expected $1 twice in $2"
  [ "$(printf '%s\n' "$values" | sort -u | wc -l | tr -d ' ')" = 1 ] || fail "$1 differs between configurations"
  printf '%s\n' "$values" | head -n 1
}

# Succeeds when X.Y.Z $1 is newer than X.Y.Z $2, compared field by field.
is_newer() {
  saved_ifs=$IFS
  IFS=.
  # shellcheck disable=SC2086
  set -- $1 $2
  IFS=$saved_ifs
  for _ in 1 2 3; do
    eval "new=\$1 old=\$4"
    [ "$new" -gt "$old" ] && return 0
    [ "$new" -lt "$old" ] && return 1
    shift
  done
  return 1
}

# MARK: 1. Preflight

printf '%s\n' "$version" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' \
  || fail "version '$version' is not X.Y.Z"
current_version=$(setting MARKETING_VERSION "$repository_root/$project")
current_build=$(setting CURRENT_PROJECT_VERSION "$repository_root/$project")
printf '%s\n' "$current_build" | grep -Eq '^[0-9]+$' || fail "CURRENT_PROJECT_VERSION '$current_build' is not an integer"
is_newer "$version" "$current_version" || fail "$version is not newer than the current version $current_version"
[ -f "$notes" ] || fail "release notes are missing: docs/release-notes/$version.md"
[ "$(head -n 1 "$notes")" = "# Enigma $version" ] \
  || fail "docs/release-notes/$version.md must start with the line: # Enigma $version"
if git -C "$repository_root" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  fail "tag $tag already exists locally"
fi
if git -C "$repository_root" ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
  fail "tag $tag already exists on origin"
fi

branch=$(git -C "$repository_root" rev-parse --abbrev-ref HEAD)
[ "$branch" = main ] || require "not on main (on $branch)"
[ -z "$(git -C "$repository_root" status --porcelain)" ] || require "the working tree has uncommitted changes"
git -C "$repository_root" fetch --quiet origin main
[ "$(git -C "$repository_root" rev-parse HEAD)" = "$(git -C "$repository_root" rev-parse origin/main)" ] \
  || require "HEAD is not level with origin/main"
gh auth status >/dev/null 2>&1 || fail "gh is not signed in (run gh auth login)"

new_build=$((current_build + 1))
say "releasing $version (build $new_build), after $current_version (build $current_build)"

# Everything below works on `source`: the checkout itself, or a temporary worktree in a dry run.
temporary=$(mktemp -d "${TMPDIR:-/tmp}/enigma-release.XXXXXX")
mount_point=""
worktree=""
# A real release edits the checkout's project and appcast before it commits them;
# if it stops before the commit, put them back.
restore_checkout=false
cleanup() {
  if [ -n "$mount_point" ]; then hdiutil detach -quiet "$mount_point" >/dev/null 2>&1 || true; fi
  if [ -n "$worktree" ]; then git -C "$repository_root" worktree remove --force "$worktree" >/dev/null 2>&1 || true; fi
  if [ "$restore_checkout" = true ]; then
    git -C "$repository_root" checkout -- "$project" appcast.xml
    echo "release: stopped before committing; restored $project and appcast.xml" >&2
  fi
  rm -rf "$temporary"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

if [ "$dry_run" = true ]; then
  worktree="$temporary/source"
  git -C "$repository_root" worktree add --quiet --detach "$worktree" HEAD
  source=$worktree
  # The app bundles the notes, which a dry run may not have committed yet.
  cp "$notes" "$source/docs/release-notes/"
else
  source=$repository_root
fi

mkdir -p "$work_directory"
say "resolving packages"
xcodebuild -resolvePackageDependencies -project "$source/Enigma.xcodeproj" -scheme Enigma \
  -derivedDataPath "$derived_data" -quiet
sparkle_tools="$derived_data/SourcePackages/artifacts/sparkle/Sparkle/bin"
[ -x "$sparkle_tools/generate_appcast" ] || fail "Sparkle's generate_appcast was not found in $sparkle_tools"

# MARK: 2. Bump

cp "$source/$project" "$temporary/project.before"
[ "$dry_run" = true ] || restore_checkout=true
sed -e "s/^\\([[:space:]]*MARKETING_VERSION = \\)$current_version;\$/\\1$version;/" \
    -e "s/^\\([[:space:]]*CURRENT_PROJECT_VERSION = \\)$current_build;\$/\\1$new_build;/" \
    "$temporary/project.before" > "$source/$project"
changed=$(diff "$temporary/project.before" "$source/$project" | grep -c '^>' || true)
[ "$changed" = 4 ] || fail "the version bump changed $changed lines of $project, not 4"
[ "$(setting MARKETING_VERSION "$source/$project")" = "$version" ] || fail "MARKETING_VERSION was not bumped"
[ "$(setting CURRENT_PROJECT_VERSION "$source/$project")" = "$new_build" ] || fail "CURRENT_PROJECT_VERSION was not bumped"

# MARK: 3. Build and verify

archive="$temporary/Enigma.xcarchive"
say "archiving (Release)"
if [ -n "$test_feed_url" ]; then
  say "warning: this build checks the test feed $test_feed_url"
  set -- "ENIGMA_UPDATE_FEED_URL=$test_feed_url"
else
  set --
fi
xcodebuild archive -project "$source/Enigma.xcodeproj" -scheme Enigma -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$archive" -derivedDataPath "$derived_data" \
  -allowProvisioningUpdates -quiet "$@"
app="$archive/Products/Applications/Enigma.app"
[ -d "$app" ] || fail "the archive has no Enigma.app"

built_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
built_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
[ "$built_version" = "$version" ] && [ "$built_build" = "$new_build" ] \
  || fail "the app says $built_version ($built_build), expected $version ($new_build)"
cmp -s "$notes" "$app/Contents/Resources/release-notes/$version.md" \
  || fail "the app does not bundle docs/release-notes/$version.md for What's new?"

# `xcodebuild archive` leaves Sparkle's helpers ad-hoc signed (an Organizer export
# would re-sign them). Re-sign them with the app's own identity and the hardened
# runtime, innermost first, in the order and with the flags Sparkle documents
# (https://sparkle-project.org/documentation/sandboxing/#code-signing), then the
# app itself with its entitlements. No --deep: Downloader keeps its own entitlements.
first_authority() {
  codesign -dvv "$1" 2>&1 | sed -n 's/^Authority=//p' | head -n 1
}
app_authority=$(first_authority "$app")
[ -n "$app_authority" ] || fail "the archived app has no signing identity"
codesign -d --extract-certificates="$temporary/certificate" "$app" 2>/dev/null
signing_identity=$(shasum -a 1 "$temporary/certificate0" | cut -d ' ' -f 1)
sparkle_framework="$app/Contents/Frameworks/Sparkle.framework"
sparkle_code="$sparkle_framework/Versions/B"
say "re-signing Sparkle's helpers with the app's identity"
codesign -f -s "$signing_identity" -o runtime "$sparkle_code/XPCServices/Installer.xpc"
codesign -f -s "$signing_identity" -o runtime --preserve-metadata=entitlements "$sparkle_code/XPCServices/Downloader.xpc"
codesign -f -s "$signing_identity" -o runtime "$sparkle_code/Autoupdate"
codesign -f -s "$signing_identity" -o runtime "$sparkle_code/Updater.app"
codesign -f -s "$signing_identity" -o runtime "$sparkle_framework"
codesign -f -s "$signing_identity" -o runtime --preserve-metadata=entitlements "$app"

codesign --verify --deep --strict "$app" || fail "codesign --verify failed"
for code in "$sparkle_code/XPCServices/Installer.xpc" "$sparkle_code/XPCServices/Downloader.xpc" \
  "$sparkle_code/Autoupdate" "$sparkle_code/Updater.app" "$sparkle_framework" \
  "$app/Contents/Frameworks/llama.framework" "$app"; do
  name=${code#"$app/"}
  [ "$code" = "$app" ] && name=Enigma.app
  [ "$(first_authority "$code")" = "$app_authority" ] || fail "$name is not signed with the app's identity"
  codesign -dvv "$code" 2>&1 | grep -q '^CodeDirectory .*flags=.*runtime' || fail "$name lacks the hardened runtime"
  say "signed with the app's identity and hardened runtime: $name"
done
codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -convert json -o "$temporary/entitlements.json" -
plutil -convert json -o "$temporary/expected-entitlements.json" "$source/Enigma/Resources/Enigma.entitlements"
cmp -s "$temporary/entitlements.json" "$temporary/expected-entitlements.json" \
  || fail "the signed app's entitlements differ from Enigma.entitlements"
say "entitlements match Enigma.entitlements (no get-task-allow)"

designated_requirement() {
  codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p'
}
new_requirement=$(designated_requirement "$app")
[ -n "$new_requirement" ] || fail "could not read the new app's designated requirement"

previous_tag=$(cd "$repository_root" && gh release list --exclude-drafts --limit 1 --json tagName --jq '.[0].tagName')
[ -n "$previous_tag" ] || fail "no previous GitHub release to compare the signature with"
previous="$temporary/previous"
mkdir -p "$previous"
say "comparing the signature with $previous_tag"
if (cd "$repository_root" && gh release download "$previous_tag" --pattern 'Enigma-*.zip' --dir "$previous") 2>/dev/null; then
  ditto -x -k "$previous"/Enigma-*.zip "$previous/app"
  previous_app=$(find "$previous/app" -maxdepth 2 -name '*.app' -type d | head -n 1)
else
  (cd "$repository_root" && gh release download "$previous_tag" --pattern '*.dmg' --dir "$previous") \
    || fail "$previous_tag has neither an Enigma zip nor a DMG"
  mount_point="$previous/mount"
  mkdir -p "$mount_point"
  hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mount_point" "$(find "$previous" -maxdepth 1 -name '*.dmg' | head -n 1)"
  previous_app=$(find "$mount_point" -maxdepth 2 -name '*.app' -type d | head -n 1)
fi
[ -n "$previous_app" ] || fail "no app found in $previous_tag"
previous_requirement=$(designated_requirement "$previous_app")
if [ "$new_requirement" != "$previous_requirement" ]; then
  echo "release: the signing identity changed; installed copies would lose their permissions." >&2
  echo "  $previous_tag: $previous_requirement" >&2
  echo "  $version: $new_requirement" >&2
  exit 1
fi
say "designated requirement matches $previous_tag"

# MARK: 4. Package

feed="$temporary/feed"
mkdir -p "$feed"
archive_name="Enigma-$version.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$feed/$archive_name"

# MARK: 5. Appcast

cp "$notes" "$feed/Enigma-$version.md"
cp "$source/appcast.xml" "$feed/appcast.xml"
cp "$source/appcast.xml" "$temporary/appcast.before"
download_prefix="$repository_url/releases/download/$tag/"
say "signing the archive and updating appcast.xml"
"$sparkle_tools/generate_appcast" --download-url-prefix "$download_prefix" --embed-release-notes \
  --maximum-deltas 0 --maximum-versions 0 -o "$feed/appcast.xml" "$feed"

item_value() {
  xmllint --xpath "string(//item[*[local-name()='version']='$new_build']/$1)" "$feed/appcast.xml" 2>/dev/null || true
}
[ "$(item_value "*[local-name()='shortVersionString']")" = "$version" ] \
  || fail "the new appcast item has no sparkle:version $new_build with sparkle:shortVersionString $version"
[ "$(item_value 'enclosure/@url')" = "$download_prefix$archive_name" ] \
  || fail "the new appcast item does not point at $download_prefix$archive_name"
[ -n "$(item_value "enclosure/@*[local-name()='edSignature']")" ] || fail "the new appcast item has no sparkle:edSignature"
cp "$feed/appcast.xml" "$source/appcast.xml"

if [ "$dry_run" = true ]; then
  output="$work_directory/dry-run/$version"
  rm -rf "$output"
  mkdir -p "$output"
  cp "$feed/$archive_name" "$feed/appcast.xml" "$source/$project" "$output/"
  diff -u "$temporary/appcast.before" "$feed/appcast.xml" || true
  say "dry run finished; nothing was committed, tagged, pushed or uploaded."
  say "results: $output"
  exit 0
fi

# MARK: 6. Publish

remote_main=$(git -C "$repository_root" ls-remote origin refs/heads/main | cut -f 1)
[ "$remote_main" = "$(git -C "$repository_root" rev-parse HEAD)" ] \
  || fail "origin/main moved during the build; pull and run the release again"
archive_copy="$work_directory/$archive_name"
cp "$feed/$archive_name" "$archive_copy"
git -C "$repository_root" add "$project" appcast.xml "docs/release-notes/$version.md"
git -C "$repository_root" commit --quiet -m "Release $version"
restore_checkout=false
git -C "$repository_root" tag "$tag"
say "pushing $tag"
git -C "$repository_root" push --quiet origin "$tag" \
  || fail "pushing $tag failed; nothing is published. Retry with: git push origin $tag, then gh release create $tag $archive_copy --notes-file docs/release-notes/$version.md --prerelease and git push origin main. Or undo with: git tag -d $tag && git reset --hard HEAD~1"
say "creating the GitHub release"
# Every release is a pre-release while Enigma is in early development. Sparkle
# reads the feed from main and downloads by tag, so it doesn't need a "Latest" release.
(cd "$repository_root" && gh release create "$tag" "$archive_copy" --notes-file "docs/release-notes/$version.md" --prerelease) \
  || fail "gh release create failed; re-run it, or delete the pushed tag. main and the live feed are unchanged."
say "pushing main"
git -C "$repository_root" push --quiet origin main \
  || fail "pushing main failed after the release was created. The live feed is unchanged and safe; retry with: git push origin main"
say "released $version. Installed copies pick it up at their next daily check."
