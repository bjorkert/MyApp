#!/usr/bin/env bash
# ------------------------------------------------------------
#  release.sh  – semi-automatic release helper
# ------------------------------------------------------------
set -euo pipefail
set -o errtrace
trap 'echo "❌  Error – aborting"; exit 1' ERR

# -------- configurable -----------------
APP_NAME="${1:-MyApp}"
SECOND_DIR="${APP_NAME}_Second"
THIRD_DIR="${APP_NAME}_Third"
VERSION_FILE="Config.xcconfig"
MARKETING_KEY="LOOP_FOLLOW_MARKETING_VERSION"
DEV_BRANCH="dev"
MAIN_BRANCH="Main"
PATCH_DIR="../${APP_NAME}_update_patches"
# ---------------------------------------

pause()     { read -rp "▶▶  Press Enter to continue (Ctrl-C to abort)…"; }
echo_run()  { echo "+ $*"; "$@"; }

push_cmds=()
queue_push() {
  push_cmds+=("git -C \"$(pwd)\" $*")
  echo "+ [queued] (in $(pwd)) git $*"
}

# ---------- PRIMARY REPO (LoopFollow) ----------
PRIMARY_ABS_PATH="$(pwd -P)"
echo "🏁  Working in $PRIMARY_ABS_PATH …"

echo_run git checkout "$DEV_BRANCH"
echo_run git fetch --all
echo_run git pull

# --- read and bump version -------------------------------------------------
old_ver=$(grep -E "^${MARKETING_KEY}[[:space:]]*=" "$VERSION_FILE" | awk '{print $3}')

major_candidate="$(awk -F. '{printf "%d.0.0", $1 + 1}' <<<"$old_ver")"
minor_candidate="$(awk -F. '{printf "%d.%d.0", $1, $2 + 1}' <<<"$old_ver")"

echo
echo "Which version bump do you want?"
echo "  1) Major  →  $major_candidate"
echo "  2) Minor  →  $minor_candidate"
read -rp "Enter 1 or 2 (default = 2): " choice
echo

case "$choice" in
  1) new_ver="$major_candidate" ;;
  ""|2) new_ver="$minor_candidate" ;;
  *) echo "❌  Invalid choice – aborting."; exit 1 ;;
esac

echo "🔢  Bumping version: $old_ver  →  $new_ver"

old_tag="v${old_ver}"
if ! git rev-parse "$old_tag" >/dev/null 2>&1; then
  git tag -a "$old_tag" -m "$old_tag"
  queue_push git push --tags
fi

# bump number in file
sed -i '' "s/${MARKETING_KEY}[[:space:]]*=.*/${MARKETING_KEY} = ${new_ver}/" "$VERSION_FILE"
echo_run git diff "$VERSION_FILE"
pause
echo_run git commit -m "update version to ${new_ver}" "$VERSION_FILE"

echo "💻  Build & test dev branch now."
pause

queue_push git push origin "$DEV_BRANCH"
queue_push git tag -a "v${new_ver}" -m "v${new_ver}"
queue_push git push --tags

echo_run git checkout "$MAIN_BRANCH"
echo_run git pull
echo_run git merge "$DEV_BRANCH"

echo "💻  Build & test main branch now."
pause
queue_push git push origin "$MAIN_BRANCH"

# --- create a mailbox with exactly the release commits ---------------
mkdir -p "$PATCH_DIR"
MBX_FILE="${PATCH_DIR}/LF_v${new_ver}.mbox"
git format-patch -k --stdout "v${old_ver}".."v${new_ver}" > "$MBX_FILE"

cd ..

# ---------- apply the mailbox in each follower repo -----------------
update_follower () {
  local DIR="$1"

  echo
  echo "🔄  Updating $DIR …"
  cd "$DIR"

  echo_run git checkout main
  echo_run git fetch --all
  echo_run git pull

  # apply all release commits as ONE squashed change, with 3-way fallback
  if ! git am --3way --squash "$MBX_FILE"; then
    echo "‼️  Conflicts detected during git am."
    echo "    Resolve them, stage the files, then press Enter to continue."
    pause
    git am --continue
  fi

  git commit -m "transfer v${new_ver} updates from LF to ${DIR}"

  echo_run git status
  pause                                       # build & test checkpoint

  queue_push git push origin main
  cd ..
}

update_follower "$SECOND_DIR"
update_follower "$THIRD_DIR"

# ---------- final confirmation & push queue --------------------------
echo
echo "🚀  All builds finished. Ready to push queued changes upstream."
read -rp "▶▶  Push everything now? (y/N): " confirm
if [[ $confirm =~ ^[Yy]$ ]]; then
  for cmd in "${push_cmds[@]}"; do
    echo "+ $cmd"
    bash -c "$cmd"
  done
  echo "🎉  All pushes completed."
else
  echo "🚫  Pushes skipped. Run manually if needed:"
  printf '   %s\n' "${push_cmds[@]}"
fi

echo
echo "🎉  All repos updated to v${new_ver} (local)."
echo "👉  Remember to create a GitHub release for tag v${new_ver}."