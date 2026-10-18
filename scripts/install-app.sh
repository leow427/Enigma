#!/bin/sh
# Build a signed Release copy of Enigma from this checkout and install it to
# /Applications, replacing (and relaunching) any running copy.
#
#   scripts/install-app.sh                 build, install, and launch
#   scripts/install-app.sh --no-launch     build and install only
#   scripts/install-app.sh --install-hooks reinstall automatically after each
#                                          commit or pull on main
#   scripts/install-app.sh --remove-hooks  stop reinstalling automatically
#
# The app is signed with the project's Apple Development team, like a run from
# Xcode, so Screen Recording, Accessibility, and Keychain approvals carry over
# between updates. Set ENIGMA_INSTALL_DIR to install somewhere else.

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
install_directory=${ENIGMA_INSTALL_DIR:-/Applications}
derived_data="$HOME/Library/Caches/Enigma-Install/DerivedData"
state_directory="$HOME/Library/Caches/Enigma-Install"
log_file="$HOME/Library/Logs/Enigma-Install.log"
bundle_identifier="com.leow427.AISpotlight"
hook_marker="# Enigma auto-install hook"

usage() {
  echo "Usage: $0 [--no-launch | --if-running | --install-hooks | --remove-hooks]" >&2
  exit 64
}

hooks_directory() {
  git -C "$repository_root" rev-parse --path-format=absolute --git-path hooks
}

install_hooks() {
  directory=$(hooks_directory)
  mkdir -p "$directory"
  for hook in post-commit post-merge; do
    path="$directory/$hook"
    if [ -e "$path" ] && ! grep -q "$hook_marker" "$path"; then
      echo "Skipping $hook: an existing hook is not Enigma's ($path)." >&2
      continue
    fi
    cat > "$path" <<EOF
#!/bin/sh
$hook_marker
# Rebuilds and reinstalls Enigma in the background when main changes.
[ "\$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" = "main" ] || exit 0
mkdir -p "\$HOME/Library/Logs"
nohup "$repository_root/scripts/install-app.sh" --if-running >> "$log_file" 2>&1 &
EOF
    chmod +x "$path"
    echo "Installed $hook hook."
  done
  echo "Enigma reinstalls after each commit or pull on main. Log: $log_file"
}

remove_hooks() {
  directory=$(hooks_directory)
  for hook in post-commit post-merge; do
    path="$directory/$hook"
    if [ -e "$path" ] && grep -q "$hook_marker" "$path"; then
      rm "$path"
      echo "Removed $hook hook."
    fi
  done
}

launch_mode=always
case "${1:-}" in
  "") ;;
  --no-launch) launch_mode=never ;;
  --if-running) launch_mode=if-running ;;
  --install-hooks) install_hooks; exit 0 ;;
  --remove-hooks) remove_hooks; exit 0 ;;
  *) usage ;;
esac
[ "$#" -le 1 ] || usage

# One build at a time. A request that arrives mid-build is remembered and run
# once the current build finishes, so the installed app ends on the newest commit.
mkdir -p "$state_directory"
lock_directory="$state_directory/lock"
pending_file="$state_directory/pending"
if ! mkdir "$lock_directory" 2>/dev/null; then
  if [ -f "$lock_directory/pid" ] && kill -0 "$(cat "$lock_directory/pid")" 2>/dev/null; then
    echo "$launch_mode" > "$pending_file"
    echo "An Enigma install is already running; this update will follow it."
    exit 0
  fi
  rm -rf "$lock_directory"
  mkdir "$lock_directory"
fi
echo $$ > "$lock_directory/pid"
trap 'rm -rf "$lock_directory"' EXIT HUP INT TERM

while :; do
  rm -f "$pending_file"
  revision=$(git -C "$repository_root" rev-parse --short HEAD)
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Building Enigma at $revision…"

  xcodebuild build \
    -project "$repository_root/AI-Spotlight.xcodeproj" \
    -scheme Enigma \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    -allowProvisioningUpdates \
    -quiet

  built_app="$derived_data/Build/Products/Release/Enigma.app"
  codesign --verify --deep --strict "$built_app"
  installed_app="$install_directory/Enigma.app"

  was_running=false
  if pgrep -f "$installed_app/Contents/MacOS/Enigma" >/dev/null 2>&1; then
    was_running=true
    osascript -e "tell application id \"$bundle_identifier\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do
      pgrep -f "$installed_app/Contents/MacOS/Enigma" >/dev/null 2>&1 || break
      sleep 0.2
    done
  fi

  # Copy beside the destination first so the swap is a quick rename.
  staging_app="$install_directory/.Enigma-installing.app"
  rm -rf "$staging_app"
  ditto "$built_app" "$staging_app"
  rm -rf "$installed_app"
  mv "$staging_app" "$installed_app"
  echo "Installed $installed_app ($revision)."

  if [ "$launch_mode" = always ] || { [ "$launch_mode" = if-running ] && [ "$was_running" = true ]; }; then
    open "$installed_app"
  fi

  [ -f "$pending_file" ] || break
  launch_mode=$(cat "$pending_file")
done
