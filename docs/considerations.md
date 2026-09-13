# Considerations

Decisions and gotchas worth revisiting as the system gets built,
roughly in the order they'll bite.

## Resolved in this iteration

- **Notification gap** — closed via ntfy pushes at plan-ready, PR-ready,
  and every failure/skip point. See docs/notifications.md.
- **Crash/reboot recovery** — `sweep-stale.sh` + a systemd timer detect
  (not auto-fix) work left inconsistent by a crash or restart.
- **Duplicate/collision handling** — both watchers now refuse to
  clobber existing in-progress work, plans, branches, or open PRs,
  and notify instead.

## Still deliberately deferred

- **Log rotation** — not urgent; revisit once `logs/` is visibly
  bloating the vault.
- **Concurrency** — left sequential/single-task-at-a-time by design.
  Safer against git/branch contention; means a backlog of queued
  tasks processes one at a time, not in parallel.

## Design-level

- **Human approval gate is load-bearing.** The plan/execute split
  (stop after planning, require an explicit rename to proceed) is the
  main safety mechanism in this whole system. Don't collapse it for
  convenience later — that's the point where an unreviewed plan gets
  executed against a real repo.
- **PR-based, not direct-commit.** Every implementation lands on a
  branch and opens a PR; nothing pushes to `base` directly. This is
  what makes "unattended overnight run" tolerable — worst case is a
  bad PR, not a bad `main`.
- **Author identity for PRs.** Decide whether `gh` authenticates as
  you or a dedicated bot account before this touches anything beyond
  personal/toy repos.

## Sync-layer

- **Partial-sync races.** Syncthing writes files incrementally; a
  watcher firing on first-write-event can read a truncated file. The
  debounce/quiet-period in `watch-todo.sh` exists specifically for
  this — don't remove it as an "optimization."
- **No file locking between Obsidian and the watcher.** If you're
  actively editing a plan file in Obsidian at the exact moment
  `watch-approved.sh` polls, edge-case corruption is possible in
  theory. Low probability, but don't rename-to-approve mid-edit.

## Infra-level

- **Headless auth.** Claude Code's and `gh`'s login flows both assume
  a browser. Test both in isolation during setup — this is the step
  most likely to differ from documented behavior.
- **Resource caps at the LXC level**, not just trust in the process,
  so a runaway test suite can't contend with other containers.
- **API cost, not compute cost, is the real resource to watch.** Every
  plan/implement/review cycle spends Claude usage — this system makes
  it very easy to queue up several tasks in a row from your phone,
  which is convenient but worth keeping an eye on.

## ECC-specific

- **Minimal + no-hooks profile** was chosen deliberately for the
  non-interactive trigger model. Revisit only if a specific hook
  (e.g. deterministic lint enforcement) turns out to matter more than
  the added complexity.
- **`multi-*` commands need `ccg-workflow`** separately installed —
  not needed for this single-task workflow, skip it unless a future
  task genuinely needs multi-agent orchestration.

## Open decisions to make before building

1. ~~Backlog → to-do promotion~~ — resolved: `Backlog/` is optional and
   unautomated; queuing happens via the `-ready` filename suffix
   inside `tasks/to-do/` itself (see workflow.md).
2. Dedicated bot GitHub account vs. personal account for `gh auth`.
3. Whether `tasks/done/` entries get cleaned up periodically or kept
   as a permanent log (affects vault size over time).
4. Per-project quality gates — does `/quality-gate` need project-specific
   config, or is a generic build/test/lint sufficient across your repos?

## `-ready` suffix — things to watch

- **Renaming on mobile mid-sync.** A rename is itself a write event;
  the existing quiet-period debounce in `watch-todo.sh` still applies,
  so this is covered, but worth confirming in practice on your actual
  Obsidian mobile file-rename UX.
- **Typos in the suffix are silent.** `-redy.md` or `-Ready.md` (case
  mismatch) simply never triggers, with no error surfaced anywhere.
  If a task seems stuck, check the exact filename first.
