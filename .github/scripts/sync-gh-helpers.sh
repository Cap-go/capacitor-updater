#!/usr/bin/env bash
# Shared GitHub helpers for automated backport/sync workflows.

set -euo pipefail

ensure_repo_label() {
  local repo="$1"
  local name="$2"
  local color="$3"
  local description="$4"

  if gh api "repos/${repo}/labels/${name}" >/dev/null 2>&1; then
    return 0
  fi

  gh label create "$name" \
    --repo "$repo" \
    --color "$color" \
    --description "$description" >/dev/null 2>&1 || {
    echo "Warning: could not create label '${name}'"
    return 1
  }
}

ensure_sync_labels() {
  local repo="$1"

  ensure_repo_label "$repo" automated 0e8a16 "Fully automated workflow-managed change" || true
  ensure_repo_label "$repo" needs-attention b60205 "Needs human follow-up" || true
  ensure_repo_label "$repo" merge-conflict d93f0b "Merge conflict detected during automation" || true
  ensure_repo_label "$repo" lts-backport 1d76db "Automated backport from main onto an LTS Capacitor branch" || true
}

repo_has_issues() {
  local repo="$1"
  gh api "repos/${repo}" --jq '.has_issues' 2>/dev/null || echo "false"
}

create_pr_and_capture_number() {
  local repo="$1"
  local base="$2"
  local head="$3"
  local title="$4"
  local body="$5"

  gh pr create \
    --repo "$repo" \
    --base "$base" \
    --head "$head" \
    --title "$title" \
    --body "$body" >/dev/null

  gh pr list \
    --repo "$repo" \
    --state open \
    --base "$base" \
    --head "$head" \
    --json number \
    -q '.[0].number'
}

add_labels_to_pr() {
  local repo="$1"
  local pr_number="$2"
  shift 2

  if [ "$#" -eq 0 ]; then
    return 0
  fi

  local csv
  csv=$(printf '%s,' "$@")
  csv=${csv%,}

  gh pr edit "$pr_number" --repo "$repo" --add-label "$csv" >/dev/null 2>&1 || {
    echo "Warning: could not add labels '${csv}' to PR #${pr_number}"
    return 1
  }
}

create_or_update_conflict_issue() {
  local repo="$1"
  local title="$2"
  local body="$3"
  local search_text="$4"

  if [ "$(repo_has_issues "$repo")" != "true" ]; then
    return 1
  fi

  local existing_issue
  existing_issue=$(
    gh issue list \
      --repo "$repo" \
      --state open \
      --search "$search_text" \
      --json number \
      -q '.[0].number' 2>/dev/null || true
  )

  if [ -n "$existing_issue" ]; then
    gh issue comment "$existing_issue" --repo "$repo" --body "$body" >/dev/null 2>&1 || return 1
    echo "$existing_issue"
    return 0
  fi

  gh issue create \
    --repo "$repo" \
    --title "$title" \
    --body "$body" \
    --label lts-backport \
    --label merge-conflict \
    --label needs-attention >/dev/null 2>&1 || return 1

  gh issue list \
    --repo "$repo" \
    --state open \
    --search "$search_text" \
    --json number \
    -q '.[0].number'
}

merge_main_preferred() {
  local commit_message="$1"

  if git merge origin/main --no-edit -m "$commit_message"; then
    return 0
  fi

  git merge --abort || true

  if git merge origin/main -X theirs --no-edit -m "$commit_message"; then
    return 0
  fi

  local unmerged
  unmerged=$(git diff --name-only --diff-filter=U || true)
  if [ -z "$unmerged" ]; then
    return 1
  fi

  local file
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    if git checkout --theirs -- "$file" 2>/dev/null; then
      git add "$file"
    elif git rm -f "$file" 2>/dev/null; then
      :
    else
      return 1
    fi
  done <<< "$unmerged"

  if [ -n "$(git diff --name-only --diff-filter=U || true)" ]; then
    return 1
  fi

  if [ -f .git/MERGE_HEAD ]; then
    git commit --no-edit || git commit -m "$commit_message"
    return 0
  fi

  return 1
}
