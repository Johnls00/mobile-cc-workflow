#!/usr/bin/env bash
# Watches vault/plans/ for files renamed to approved-*.plan.md.
# On match: branches off <base>, implements via TDD + review, opens a PR.
# See docs/workflow.md.
set -euo pipefail

VAULT="${VAULT_PATH:?set VAULT_PATH to your mounted vault root}"
PROJECTS_DIR="${PROJECTS_DIR:?set PROJECTS_DIR to where repos are cloned}"
PLANS_DIR="$VAULT/plans"
INPROGRESS_DIR="$VAULT/tasks/in-progress"
DONE_DIR="$VAULT/tasks/done"
QUIET_SECONDS=8

NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"
NTFY_TOPIC="${NTFY_TOPIC:-}"   # same topic as watch-todo.sh, or a separate one

notify() {
  local title="$1" msg="$2" priority="${3:-default}"
  [[ -n "$NTFY_TOPIC" ]] || return 0
  curl -fsS -m 10 \
    -H "Title: $title" \
    -H "Priority: $priority" \
    -d "$msg" \
    "$NTFY_SERVER/$NTFY_TOPIC" >/dev/null 2>&1 || true
}

mkdir -p "$DONE_DIR"

wait_for_quiet() {
  local f="$1"
  local last_size=-1 cur_size
  while true; do
    cur_size=$(stat -c%s "$f" 2>/dev/null || echo -1)
    if [[ "$cur_size" == "$last_size" ]]; then
      sleep "$QUIET_SECONDS"
      cur_size=$(stat -c%s "$f" 2>/dev/null || echo -1)
      [[ "$cur_size" == "$last_size" ]] && return 0
    fi
    last_size="$cur_size"
    sleep 1
  done
}

process_approved() {
  local plan_file="$1"
  local base_name
  base_name="$(basename "$plan_file" .plan.md)"          # approved-<task>
  local task_name="${base_name#approved-}"

  wait_for_quiet "$plan_file"

  local task_note="$INPROGRESS_DIR/$task_name.md"
  if [[ ! -f "$task_note" ]]; then
    echo "[watch-approved] No matching task note for $task_name, skipping" >&2
    notify "Task failed: $task_name" "No matching task note found in tasks/in-progress/. Was it moved or deleted?" "urgent"
    return
  fi

  local repo base
  repo=$(grep -m1 '^repo:' "$task_note" | sed 's/repo:[[:space:]]*//')
  base=$(grep -m1 '^base:' "$task_note" | sed 's/base:[[:space:]]*//')
  base="${base:-main}"

  local repo_path="$PROJECTS_DIR/$repo"
  if [[ ! -d "$repo_path" ]]; then
    echo "[watch-approved] Repo not found: $repo_path" >&2
    notify "Task failed: $task_name" "Repo not found: $repo_path" "urgent"
    return
  fi

  local branch="task/$task_name"

  # Collision check: a branch or open PR already existing for this
  # task name means either this got approved twice (double-tap on
  # mobile) or a previous run is still live. Recreating the branch
  # with `checkout -B` would silently discard it, so refuse instead.
  if (cd "$repo_path" && git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1); then
    echo "[watch-approved] Branch $branch already exists on origin, skipping" >&2
    notify "Task skipped: $task_name" \
      "Branch $branch already exists in $repo. Delete it or rename the plan file if this was a duplicate approval." \
      "high"
    return
  fi
  if (cd "$repo_path" && gh pr list --head "$branch" --state open --json number -q '.[0].number' 2>/dev/null | grep -q .); then
    echo "[watch-approved] Open PR already exists for $branch, skipping" >&2
    notify "Task skipped: $task_name" \
      "An open PR already exists for $branch. Close it or rename the plan file if this was a duplicate approval." \
      "high"
    return
  fi

  echo "[watch-approved] Implementing: $task_name (repo=$repo base=$base branch=$branch)"

  # NOTE: this is deliberately an && chain, not `set -e`. `set -e` inside a
  # subshell that's itself the operand of `if !` is a well-known bash trap —
  # errexit gets silently disabled in that context, so earlier commands can
  # fail (e.g. an auth error on `git fetch`) and the script sails on regardless.
  # `set -o pipefail` covers the one real pipeline below, so a `gh pr create`
  # failure isn't masked by `tee` succeeding.
  if ! (
    set -o pipefail
    cd "$repo_path" &&
    git fetch origin "$base" &&
    git checkout -B "$branch" "origin/$base" &&
    claude -p "Implement the following approved plan using the tdd-workflow skill,
then run /code-review and address findings, then run the project's
build/lint/test suite.

Plan:
$(cat "$plan_file")" \
      --dangerously-skip-permissions \
      >> "$VAULT/logs/$task_name.log" 2>&1 &&
    git add -A &&
    { git commit -m "Implement: $task_name" || echo "[watch-approved] Nothing to commit"; } &&
    git push -u origin "$branch" &&
    gh pr create --base "$base" --head "$branch" \
      --title "$task_name" \
      --body "Automated implementation of approved plan. See $task_name.log for session detail." \
      | tee -a "$VAULT/logs/$task_name.log"
  ); then
    echo "[watch-approved] Implementation failed for $task_name" >&2
    notify "Implementation failed: $task_name" \
      "Failed on branch $branch in $repo. Check logs/$task_name.log. Task note and plan left in place for retry." \
      "urgent"
    return
  fi

  local pr_url
  pr_url=$(cd "$repo_path" && gh pr view "$branch" --json url -q .url 2>/dev/null || echo "unknown")

  {
    echo "# $task_name — done"
    echo
    echo "PR: $pr_url"
    echo
    echo "## Original task"
    cat "$task_note"
  } > "$DONE_DIR/$task_name.md"

  mv "$plan_file" "$DONE_DIR/$task_name.plan.md"
  rm -f "$task_note"

  echo "[watch-approved] Done: $task_name -> $pr_url"
  notify "PR ready: $task_name" "$pr_url" "default"
}

echo "[watch-approved] Watching $PLANS_DIR for approved-*.plan.md ..."
inotifywait -m -e moved_to,close_write --format '%f' "$PLANS_DIR" | while read -r fname; do
  [[ "$fname" == approved-*.plan.md ]] || continue
  process_approved "$PLANS_DIR/$fname"
done
