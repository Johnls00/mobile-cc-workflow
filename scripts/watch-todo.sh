#!/usr/bin/env bash
# Watches vault/tasks/to-do/ for new task notes, plans them, stops.
# Does NOT implement anything. See docs/workflow.md.
set -euo pipefail

VAULT="${VAULT_PATH:?set VAULT_PATH to your mounted vault root}"
TODO_DIR="$VAULT/tasks/to-do"
INPROGRESS_DIR="$VAULT/tasks/in-progress"
PLANS_DIR="$VAULT/plans"
QUIET_SECONDS=8

NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"
NTFY_TOPIC="${NTFY_TOPIC:-}"   # set to a unique, hard-to-guess topic name

notify() {
  local title="$1" msg="$2" priority="${3:-default}"
  [[ -n "$NTFY_TOPIC" ]] || return 0
  curl -fsS -m 10 \
    -H "Title: $title" \
    -H "Priority: $priority" \
    -d "$msg" \
    "$NTFY_SERVER/$NTFY_TOPIC" >/dev/null 2>&1 || true
}

mkdir -p "$TODO_DIR" "$INPROGRESS_DIR" "$PLANS_DIR"

# Returns once the given file has had no writes for QUIET_SECONDS.
# Protects against reading a file mid-Syncthing-sync.
wait_for_quiet() {
  local f="$1"
  local last_size=-1
  local cur_size
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

process_task() {
  local task_file="$1"
  local raw_name name
  raw_name="$(basename "$task_file" .md)"
  name="${raw_name%-ready}"   # strip the trigger suffix for downstream naming

  # Collision check: don't clobber an in-progress run or an existing
  # plan for the same task name. This is the case that matters most —
  # queuing the same name twice from a phone (double-tap, retry after
  # a sync hiccup) should never silently overwrite live work.
  if [[ -f "$INPROGRESS_DIR/$name.md" || -f "$PLANS_DIR/$name.plan.md" ]]; then
    echo "[watch-todo] Skipping $name — already in-progress or planned" >&2
    notify "Task skipped: $name" \
      "$name is already in-progress or has a plan. Rename or delete the duplicate in tasks/to-do/ if this was a mistake." \
      "high"
    return
  fi

  wait_for_quiet "$task_file"

  local inprogress_file="$INPROGRESS_DIR/$name.md"
  mv "$task_file" "$inprogress_file"

  local repo base
  repo=$(grep -m1 '^repo:' "$inprogress_file" | sed 's/repo:[[:space:]]*//')
  base=$(grep -m1 '^base:' "$inprogress_file" | sed 's/base:[[:space:]]*//')
  base="${base:-main}"

  echo "[watch-todo] Planning: $name (repo=$repo base=$base)"

  local plan_file="$PLANS_DIR/$name.plan.md"
  if ! claude -p "/plan

Task note:
$(cat "$inprogress_file")

Write the plan only. Do not implement anything." \
    > "$plan_file" 2>> "$VAULT/logs/$name.log"; then
    echo "[watch-todo] Planning failed for $name" >&2
    rm -f "$plan_file"
    notify "Plan failed: $name" \
      "Planning failed for '$name'. Check logs/$name.log. Task note left in tasks/in-progress/." \
      "urgent"
    return
  fi

  echo "[watch-todo] Plan written: $plan_file"
  notify "Plan ready: $name" \
    "Plan for '$name' is ready to review in plans/$name.plan.md. Rename to approved-$name.plan.md to implement." \
    "default"
}

echo "[watch-todo] Watching $TODO_DIR for *-ready.md ..."
inotifywait -m -e close_write,moved_to --format '%f' "$TODO_DIR" | while read -r fname; do
  # Only files ending in "-ready.md" are picked up. A plain .md file in
  # tasks/to-do/ is treated as a draft sitting in the queue, not yet
  # queued for execution — rename to add "-ready" when it actually is.
  [[ "$fname" == *-ready.md ]] || continue
  process_task "$TODO_DIR/$fname"
done
