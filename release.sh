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
  queue_push push --tags
fi

# bump number in file
sed -i '' "s/${MARKETING_KEY}[[:space:]]*=.*/${MARKETING_KEY} = ${new_ver}/" "$VERSION_FILE"
echo_run git diff "$VERSION_FILE"
pause
echo_run git commit -m "update version to ${new_ver}" "$VERSION_FILE"

echo "💻  Build & test dev branch now."
pause

queue_push push origin "$DEV_BRANCH"
git tag -a "v${new_ver}" -m "v${new_ver}"
queue_push push --tags

echo_run git checkout "$MAIN_BRANCH"
echo_run git pull
echo_run git merge "$DEV_BRANCH"

echo "💻  Build & test main branch now."
pause
queue_push push origin "$MAIN_BRANCH"

# --- create a mailbox with exactly the release commits ---------------
mkdir -p "$PATCH_DIR"
MBX_FILE="${PATCH_DIR}/LF_v${new_ver}.mbox"
git format-patch -k --stdout "v${old_ver}".."v${new_ver}" > "$MBX_FILE"

cd ..

# ---------- function to update a follower repo ----------
update_follower () {
  local DIR="$1"

  echo
  echo "🔄  Updating $DIR …"
  cd "$DIR"

  # 1 · Start from a clean, up-to-date main
  echo_run git checkout main
  echo_run git fetch --all
  echo_run git pull

  # 2 · Add (or refresh) a TEMP remote that points at the primary repo
  if git remote | grep -q '^lf$'; then
    echo_run git remote remove lf
  fi
  echo_run git remote add lf "$PRIMARY_ABS_PATH"

  for tag in "v${old_ver}" "v${new_ver}"; do
    git rev-parse -q "$tag" >/dev/null && echo_run git tag -d "$tag"
  done

  # 3 · Fetch only the two release tags
  echo_run git fetch --no-tags lf \
          "refs/tags/v${old_ver}:refs/tags/v${old_ver}" \
          "refs/tags/v${new_ver}:refs/tags/v${new_ver}"

  # 4 · Remember current HEAD so we can squash later
  start_sha=$(git rev-parse HEAD)

  # 5 · Cherry-pick the whole range (normal mode, no -n)
  if ! git cherry-pick -x "v${old_ver}..v${new_ver}"; then
    echo "‼️  Conflicts detected during cherry-pick."
    echo "    Resolve them (edit files, git add), then press Enter to continue."
    pause
    # User may already have continued; run a defensive check
    while [ -f .git/CHERRY_PICK_HEAD ]; do
      echo_run git cherry-pick --continue || {
        echo "    Still conflicts. Fix and press Enter again."; pause; }
    done
  fi

  # 6 · Squash every temporary commit into ONE follower-side commit
  git reset --soft "$start_sha"
  git commit -m "transfer v${new_ver} updates from LF to ${DIR}"

  # 7 · Remove the temp remote
  echo_run git remote remove lf

  echo_run git status
  pause                                       # build & test checkpoint

  # 8 · Queue the push for later
  queue_push push origin main
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