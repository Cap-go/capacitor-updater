#!/usr/bin/env bash
# Merge main into a Capacitor LTS branch, restore major-specific pins, then
# push so bump_version.yml can tag and build.yml can publish.

set -euo pipefail

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  echo "Usage: backport-lts.sh v5|v6|v7"
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# Scripts live on main. Copy them before switching onto the LTS branch.
SCRIPT_STASH="$(mktemp -d)"
cp -a "$ROOT/.github/scripts/." "$SCRIPT_STASH/"
cp "$ROOT/.github/lts-backport.json" "$SCRIPT_STASH/lts-backport.json"
HELPERS="$SCRIPT_STASH/sync-gh-helpers.sh"
RESTORE="$SCRIPT_STASH/restore-lts-constraints.mjs"
# shellcheck source=/dev/null
source "$HELPERS"

if ! jq -e --arg target "$TARGET" '.targets[$target]' "$SCRIPT_STASH/lts-backport.json" >/dev/null; then
  echo "Unknown target '$TARGET'"
  exit 1
fi

TARGET_BRANCH="$(jq -r --arg target "$TARGET" '.targets[$target].branch' "$SCRIPT_STASH/lts-backport.json")"
DROP_UISCENE="$(jq -r --arg target "$TARGET" '.targets[$target].dropUiScene' "$SCRIPT_STASH/lts-backport.json")"
NPM_TAG="$(jq -r --arg target "$TARGET" '.targets[$target].npmTag' "$SCRIPT_STASH/lts-backport.json")"
SYNC_BRANCH="backport/main-to-${TARGET_BRANCH}"

git fetch origin main "$TARGET_BRANCH"
git checkout -B "$SYNC_BRANCH" "origin/${TARGET_BRANCH}"

MAIN_VERSION="$(git show origin/main:package.json | node -e "let s='';process.stdin.on('data',d=>s+=d);process.stdin.on('end',()=>console.log(JSON.parse(s).version))")"
TARGET_VERSION="$(node -p "require('./package.json').version")"
echo "main=$MAIN_VERSION ${TARGET_BRANCH}=$TARGET_VERSION"

COMMIT_MESSAGE="chore: backport ${MAIN_VERSION} onto ${TARGET_BRANCH}"
USED_PREFERRED_MERGE="false"

if merge_main_preferred "$COMMIT_MESSAGE"; then
  USED_PREFERRED_MERGE="true"
else
  git merge --abort || git reset --hard "origin/${TARGET_BRANCH}"
fi

UNMERGED="$(git diff --name-only --diff-filter=U || true)"
if [ -n "$UNMERGED" ] || [ "$USED_PREFERRED_MERGE" != "true" ]; then
  echo "Unable to complete merge of main into ${TARGET_BRANCH}"
  ensure_sync_labels "${GITHUB_REPOSITORY}"
  create_or_update_conflict_issue "${GITHUB_REPOSITORY}" \
    "⚠️ LTS backport to ${TARGET_BRANCH} needs manual conflict resolution" \
    "The scheduled backport of \`${MAIN_VERSION}\` onto \`${TARGET_BRANCH}\` could not be resolved with the main-preferred merge strategy plus LTS constraint restore. Manual resolution is required." \
    "LTS backport to ${TARGET_BRANCH} needs manual conflict resolution in:title" || true
  exit 1
fi

node "$RESTORE" --target "$TARGET" --repo-root "$ROOT" --config "$SCRIPT_STASH/lts-backport.json"

if command -v bun >/dev/null 2>&1; then
  bun install
  if [ -f example-app/package.json ]; then
    (
      cd example-app
      bun install
      bunx cap sync || echo "cap sync failed; lockfile and constraint restore still applied"
    )
  fi
fi

if [ "$DROP_UISCENE" = "true" ]; then
  git checkout "origin/${TARGET_BRANCH}" -- \
    example-app/ios/App/App/AppDelegate.swift \
    example-app/ios/App/App/Info.plist \
    example-app/ios/App/App.xcodeproj/project.pbxproj || true
  if [ -f example-app/ios/App/App/SceneDelegate.swift ]; then
    git rm -f example-app/ios/App/App/SceneDelegate.swift || rm -f example-app/ios/App/App/SceneDelegate.swift
  fi
fi

git add -A
if [ -n "$(git diff --name-only --diff-filter=U || true)" ]; then
  echo "Constraint restore left unresolved files"
  git diff --name-only --diff-filter=U
  ensure_sync_labels "${GITHUB_REPOSITORY}"
  git commit -am "chore: WIP backport ${MAIN_VERSION} onto ${TARGET_BRANCH} (unresolved constraints)" || true
  git push origin "$SYNC_BRANCH" --force
  PR_BODY=$(cat <<EOF
## What
- Attempted automatic backport of \`${MAIN_VERSION}\` onto \`${TARGET_BRANCH}\`

## Why
- LTS users need the latest Capgo updater on Capacitor $(jq -r --arg target "$TARGET" '.targets[$target].major' "$SCRIPT_STASH/lts-backport.json")

## How
- Merged \`main\` with a main-preferred conflict strategy, then restored pins from \`.github/lts-backport.json\`
- Constraint restore could not finish; remaining conflict files need a human

## Testing
- Not run; merge is incomplete

## Not Tested
- Publish, native tests, Maestro
EOF
  )
  EXISTING_PR="$(gh pr list --repo "${GITHUB_REPOSITORY}" --base "$TARGET_BRANCH" --head "$SYNC_BRANCH" --state open --json number -q '.[0].number' || true)"
  if [ -z "$EXISTING_PR" ]; then
    EXISTING_PR="$(create_pr_and_capture_number "${GITHUB_REPOSITORY}" "$TARGET_BRANCH" "$SYNC_BRANCH" "chore: backport ${MAIN_VERSION} to ${TARGET_BRANCH}" "$PR_BODY")"
  fi
  add_labels_to_pr "${GITHUB_REPOSITORY}" "$EXISTING_PR" lts-backport merge-conflict needs-attention || true
  exit 1
fi

if ! git diff --cached --quiet; then
  git commit -m "chore: restore Capacitor ${TARGET_BRANCH} constraints after backport ${MAIN_VERSION}"
fi

if [ "$(git rev-list --count "origin/${TARGET_BRANCH}..HEAD")" -eq 0 ]; then
  echo "No backport needed for ${TARGET_BRANCH}; already up to date after constraint restore"
  exit 0
fi

git push origin "$SYNC_BRANCH" --force
echo "Pushed ${SYNC_BRANCH}"

PR_BODY=$(cat <<EOF
## What
- Automatic backport of \`${MAIN_VERSION}\` onto \`${TARGET_BRANCH}\` as the matching LTS version
- Restored Capacitor ${TARGET_BRANCH} pins from \`.github/lts-backport.json\`

## Why
- LTS users should get the latest Capgo updater without waiting on manual merge

## How
- Merged \`main\` with a main-preferred conflict strategy (same approach as capacitor-plus)
- Reapplied major-specific Capacitor, iOS, Android, and example-app constraints
- Direct-push to \`${TARGET_BRANCH}\` so \`bump_version.yml\` can test, tag, and publish \`${NPM_TAG}\`

## Testing
- Constraint restore self-test
- \`bump_version.yml\` on \`${TARGET_BRANCH}\` runs the full test workflow before tagging

## Not Tested
- Live npm publish until the tag job finishes
EOF
)

# Direct push to the LTS branch so bump_version.yml can test, tag, and publish.
if git push origin "HEAD:${TARGET_BRANCH}"; then
  echo "Pushed backport to ${TARGET_BRANCH}. bump_version.yml will tag ${NPM_TAG} after tests pass."
  ensure_sync_labels "${GITHUB_REPOSITORY}"
  EXISTING_PR="$(gh pr list --repo "${GITHUB_REPOSITORY}" --base "$TARGET_BRANCH" --head "$SYNC_BRANCH" --state open --json number -q '.[0].number' || true)"
  if [ -n "$EXISTING_PR" ]; then
    gh pr comment "$EXISTING_PR" --body "Automatic backport succeeded and was pushed directly to \`${TARGET_BRANCH}\`. Closing this PR." >/dev/null 2>&1 || true
    gh pr close "$EXISTING_PR" >/dev/null 2>&1 || true
  fi
else
  echo "Direct push to ${TARGET_BRANCH} failed; opening a PR instead"
  ensure_sync_labels "${GITHUB_REPOSITORY}"
  EXISTING_PR="$(gh pr list --repo "${GITHUB_REPOSITORY}" --base "$TARGET_BRANCH" --head "$SYNC_BRANCH" --state open --json number -q '.[0].number' || true)"
  if [ -z "$EXISTING_PR" ]; then
    EXISTING_PR="$(create_pr_and_capture_number "${GITHUB_REPOSITORY}" "$TARGET_BRANCH" "$SYNC_BRANCH" "chore: backport ${MAIN_VERSION} to ${TARGET_BRANCH}" "$PR_BODY")"
  fi
  add_labels_to_pr "${GITHUB_REPOSITORY}" "$EXISTING_PR" lts-backport automated || true
  gh pr merge "$EXISTING_PR" --repo "${GITHUB_REPOSITORY}" --squash --auto >/dev/null 2>&1 || true
fi
