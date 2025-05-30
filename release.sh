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
# ---------------------------------------

pause() { read -rp "▶▶  Press Enter to continue (Ctrl-C to abort)…"; }
echo_run() { echo "+ $*"; "$@"; }

push_cmds=()
queue_push() {
  push_cmds+=("git -C \"$(pwd)\" $*")
  echo "+ [queued] (in $(pwd)) git $*"
}

# ---------- PRIMARY REPO (LoopFollow) ----------
if [ "$(basename "$PWD")" = "$APP_NAME" ]; then
  PRIMARY_DIR="."
fi
PRIMARY_ABS_PATH="$(pwd -P)"
echo "🏁  Working in $PRIMARY_ABS_PATH …"

echo_run git checkout "$DEV_BRANCH"
echo_run git fetch --all
echo_run git pull

# read and bump version
old_ver=$(grep -E "^${MARKETING_KEY}[[:space:]]*=" "$VERSION_FILE" | awk '{print $3}')

# -----------------------------------------------------------------
# Interactive choice: major or minor bump
# -----------------------------------------------------------------
major_candidate="$(awk -F. '{printf "%d.0.0", $1 + 1}' <<<"$old_ver")"
minor_candidate="$(awk -F. '{printf "%d.%d.0", $1, $2 + 1}' <<<"$old_ver")"

echo
echo "Which version bump do you want?"
echo "  1) Major  →  ${major_candidate}"
echo "  2) Minor  →  ${minor_candidate}"
read -rp "Enter 1 or 2 (default = 2): " choice
echo

case "$choice" in
  1) BUMP_KIND="major" ; new_ver="$major_candidate" ;;
  ""|2) BUMP_KIND="minor" ; new_ver="$minor_candidate" ;;
  *)  echo "❌  Invalid choice – aborting." ; exit 1 ;;
esac

echo "🔢  Selected $BUMP_KIND bump: $old_ver  →  $new_ver"

# Ensure a tag for the previous version exists
old_tag="v${old_ver}"
if ! git rev-parse "$old_tag" >/dev/null 2>&1; then
  echo "⚠️  Tag $old_tag not found – creating it on current HEAD."
  git tag -a "$old_tag" -m "$old_tag"
  queue_push git push --tags                 # ⬅ queued
fi

echo "🔢  Bumping version: $old_ver  →  $new_ver"
sed -i '' "s/${MARKETING_KEY}[[:space:]]*=.*/${MARKETING_KEY} = ${new_ver}/" "$VERSION_FILE"

echo_run git diff "$VERSION_FILE"
pause                                     # checkpoint ① – verify diff

echo_run git commit -m "update version to ${new_ver}" "$VERSION_FILE"

echo "💻  Build & test dev branch now."
pause                                     # checkpoint ② – manual build test

queue_push git push origin "$DEV_BRANCH"  # ⬅ queued
queue_push git tag -a "v${new_ver}" -m "v${new_ver}"
queue_push git push --tags                # ⬅ queued

echo_run git checkout "$MAIN_BRANCH"
echo_run git pull
echo_run git merge "$DEV_BRANCH"

echo "💻  Build & test main branch now."
pause                                     # checkpoint ③ – manual build test

queue_push git push origin "$MAIN_BRANCH" # ⬅ queued

cd ..

# ---------- function to update a follower repo ----------
# ---------- function to update a follower repo ----------
# ---------- function to update a follower repo ----------
update_follower () {
  local DIR="$1"

  echo
  echo "🔄  Updating $DIR …"
  cd "$DIR"

  # 1 · Make sure we start from a clean, up-to-date main
  echo_run git checkout main
  echo_run git fetch --all
  echo_run git pull

  # 2 · Add (or replace) a TEMP remote that points to the primary repo
  if git remote | grep -q '^lf$'; then
    echo_run git remote remove lf
  fi
  echo_run git remote add lf "$PRIMARY_ABS_PATH"

  # 3 · Fetch just the tags we need from that repo
  echo_run git fetch --tags lf

  # 4 · Cherry-pick the range v${old_ver}..v${new_ver} into the index
  #     --no-commit keeps all patches staged as ONE combined change
  if ! git cherry-pick -x --no-commit "v${old_ver}..v${new_ver}"; then
    echo "‼️  Conflicts detected during cherry-pick."
    echo "    Resolve them, then press Enter to continue."
    pause
  fi

  # 5 · Single commit that captures the whole release bump
  git commit -m "transfer v${new_ver} updates from LF to ${DIR}"

  # 6 · Remove the temp remote
  echo_run git remote remove lf

  echo_run git status
  pause                                     # build & test checkpoint

  # 7 · Queue the push for later
  queue_push git push origin main           # queued, not executed now
  cd ..
}

# ---------- SECOND & THIRD ----------
update_follower "$SECOND_DIR"
update_follower "$THIRD_DIR"

# ---------- FINAL CONFIRMATION & PUSH ----------
echo
echo "🚀  All builds finished. Ready to push queued changes upstream."
read -rp "▶▶  Push everything now? (y/N): " confirm
if [[ $confirm =~ ^[Yy]$ ]]; then
  for cmd in "${push_cmds[@]}"; do
    echo "+ $cmd"
    bash -c "$cmd"          # runs with correct -C <dir> prefix
  done
  echo "🎉  All pushes completed."
else
  echo "🚫  Pushes skipped. Run manually if needed:"
  printf '   %s\n' "${push_cmds[@]}"
fi

echo
echo "🎉  All repos updated to v${new_ver} (local)."
echo "👉  Remember to create a GitHub release for tag v${new_ver}."