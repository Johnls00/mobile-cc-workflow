#!/usr/bin/env bash
# Detects work left in an inconsistent state by a crash, reboot, or a
# watcher that died mid-run. Detection + notification only — it does
# not auto-fix anything, since guessing at recovery is riskier than
# asking you to look. Run periodically via systemd timer or cron.
set -uo pipefail

VAULT="${VAULT_PATH:?set VAULT_PATH to your mounted vault root}"
PROJECTS_DIR="${PROJECTS_DIR:?set PROJECTS_DIR to where repos are cloned}"
INPROGRESS_DIR="$VAULT/tasks/in-progress"
PLANS_DIR="$VAULT/plans"
STALE_MINUTES="${STALE_MINUTES:-60}"

NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"
NTFY_TOPIC="${NTFY_TOPIC:-}"

notify() {
  local title="$1" msg="$2" priority="${3:-default}"
  [[ -n "$NTFY_TOPIC" ]] || return 0
  curl -fsS -m 10 \
    -H "Title: $title" \
    -H "Priority: $priority" \
    -d "$msg" \
    "$NTFY_SERVER/$NTFY_TOPIC" >/dev/null 2>&1 || true
}

# 1. Task notes stuck in tasks/in-progress/ with no corresponding plan.
#    Means watch-todo.sh was interrupted after the move but before
#    (or during) the claude -p call.
find "$INPROGRESS_DIR" -maxdepth 1 -name '*.md' -mmin "+$STALE_MINUTES" 2>/dev/null | while read -r f; do
  name="$(basename "$f" .md)"
  if [[ ! -f "$PLANS_DIR/$name.plan.md" ]]; then
    echo "[sweep] Stale (no plan): $name"
    notify "Stuck task: $name" \
      "$name has been in tasks/in-progress/ for over ${STALE_MINUTES}m with no plan. The planning run may have died — check logs/$name.log and re-queue if needed." \
      "high"
  fi
done

# 2. Local task/* branches with no open PR and no commits in the
#    stale window. Means watch-approved.sh died mid-implementation.
for repo_path in "$PROJECTS_DIR"/*/; do
  [[ -d "$repo_path/.git" ]] || continue
  repo="$(basename "$repo_path")"
  (
    cd "$repo_path" || exit 0
    git for-each-ref --format='%(refname:short) %(committerdate:unix)' refs/heads/task/ 2>/dev/null
  ) | while read -r branch commit_epoch; do
    [[ -n "$branch" ]] || continue
    now=$(date +%s)
    age_min=$(( (now - commit_epoch) / 60 ))
    if (( age_min > STALE_MINUTES )); then
      has_pr=$(cd "$repo_path" && gh pr list --head "$branch" --json number -q '.[0].number' 2>/dev/null)
      if [[ -z "$has_pr" ]]; then
        echo "[sweep] Stale branch, no PR: $repo/$branch (${age_min}m old)"
        notify "Stuck implementation: $branch" \
          "$repo/$branch has had no activity for ${age_min}m and no PR exists. The implementation run may have died mid-way — check logs and either resume manually or delete the branch and re-approve." \
          "high"
      fi
    fi
  done
done
