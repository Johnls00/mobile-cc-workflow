# Notifications, crash recovery, and collisions

Concurrency is deliberately left as-is (both watchers process one
task at a time, sequentially) — the additions below are about
visibility and safety, not parallelism.

## Push notifications (ntfy)

Both watchers send a push notification via [ntfy](https://ntfy.sh) at
the points where you'd otherwise have to open Obsidian to check:

| Event | Script | Priority |
|---|---|---|
| Plan ready to review | `watch-todo.sh` | default |
| Planning failed | `watch-todo.sh` | urgent |
| Duplicate task skipped | `watch-todo.sh` | high |
| PR opened | `watch-approved.sh` | default |
| Implementation failed | `watch-approved.sh` | urgent |
| Duplicate branch/PR skipped | `watch-approved.sh` | high |
| Stale/crashed task detected | `sweep-stale.sh` | high |

### Setup

1. Install the [ntfy app](https://ntfy.sh/) on your phone (or use the
   web app).
2. Subscribe to a topic — treat the topic name like a password, since
   anyone who knows it on the public ntfy.sh server can read your
   notifications. A long random string
   (`task-updates-a8f3k2j9x`) is fine. Self-hosting an ntfy server is
   the stronger option if you want this fully private — out of scope
   here, but a small addition to the same Proxmox host.
3. Set `NTFY_TOPIC` in each systemd unit's `Environment=` line (see
   `scripts/systemd/*.service`) to that topic name.
4. If self-hosting, also set `NTFY_SERVER` to your own instance URL.

Notifications are best-effort — a failed `curl` never breaks the
watcher (`|| true` on every notify call). If your phone doesn't get a
notification, the vault files themselves are still the source of
truth.

## Crash / reboot recovery

`sweep-stale.sh` runs periodically (every 30 minutes via
`sweep-stale.timer`) and checks two things:

1. **Task notes stuck in `tasks/in-progress/`** with no corresponding
   file in `plans/` after `STALE_MINUTES` (default 60). This means
   `watch-todo.sh` was interrupted after moving the note but before
   finishing the plan — most likely a service restart or an LXC
   reboot mid-run.
2. **Local `task/*` branches with no open PR** and no commits within
   `STALE_MINUTES`. This means `watch-approved.sh` died mid-
   implementation — branch created, work in progress, never pushed
   or PR'd.

It only detects and notifies — it does not delete branches, re-queue
tasks, or retry anything automatically. Recovery is a judgment call
(resume manually, delete the branch and re-approve, or re-queue the
task) that's safer left to you than guessed at by a script.

Installed alongside the other units in
[docs/setup.md](setup.md#6-install-the-watcher-scripts) — no separate
install step needed here.

## Duplicate / collision handling

Two collision points were identified and are now guarded:

**Same task queued twice (`watch-todo.sh`).** Before moving a
`*-ready.md` file, it checks whether `tasks/in-progress/<name>.md` or
`plans/<name>.plan.md` already exists. If either does, the duplicate
is left in `tasks/to-do/` untouched and you get a notification — it
does not overwrite live work.

**Same plan approved twice, or a branch/PR already exists
(`watch-approved.sh`).** Before creating a branch, it checks:
- whether `task/<name>` already exists on `origin`
- whether an open PR already exists for that branch

If either is true, it stops before touching git and notifies you,
rather than resetting an existing branch (which would silently
discard any commits or review context already on it).

Both checks are look-before-you-leap, not locking — there's a narrow
window where two near-simultaneous triggers could still race. Given
this system processes one task at a time and triggers require an
explicit rename on your part, that window is small enough not to be
worth solving with real locking for now.
