# Mobile Claude Code Workflow

Plan and trigger development work from your phone. Write a task note in
Obsidian, review the plan Claude Code produces, approve it, and get a PR
back — all without opening a laptop.

## How it fits together

```
 Phone (Obsidian)          Syncthing            Proxmox LXC
 ┌─────────────┐        ┌───────────┐        ┌────────────────────┐
 │ vault/      │◄──────►│ sync      │◄──────►│ vault/ (mounted)   │
 │  Backlog/   │        └───────────┘        │                    │
 │  tasks/     │                             │ watch-todo.sh      │
 │  plans/     │                             │   -> claude -p     │
 │  logs/      │                             │   -> plans/*.md    │
 └─────────────┘                             │                    │
                                             │ watch-approved.sh  │
                                             │   -> git branch    │
                                             │   -> claude -p     │
                                             │   -> gh pr create  │
                                             └────────────────────┘
```

No local model inference happens on the LXC. Claude Code calls the
Anthropic API; the LXC just orchestrates file-watching, git, and the
`gh` CLI. Resource footprint is closer to Syncthing than to Jellyfin —
see [docs/resource-notes.md](docs/resource-notes.md).

## Task lifecycle

1. **Backlog/** — optional. Small ideas, drafts, work-in-progress
   notes. Nothing automated touches this folder; use it however's
   convenient.
2. **tasks/to-do/** — write or move a task note here. It sits inert
   until its filename ends in `-ready.md` — draft it in place, rename
   to trigger. This is the trigger boundary.
3. `watch-todo.sh` picks up any `*-ready.md` file, moves it to
   `tasks/in-progress/`, runs
   `/plan` against it, and writes the result to `plans/`. **It stops
   there.** No implementation happens yet.
4. You review the plan in Obsidian on your phone.
5. **Approve** by renaming the plan file to `approved-*.md` (or moving
   it to `plans/approved/` — see [docs/workflow.md](docs/workflow.md)
   for the exact convention).
6. `watch-approved.sh` creates a branch off the task's specified base
   (default `main`), runs the implementation (TDD workflow +
   code-review), pushes, and opens a PR via `gh pr create`.
7. You review the PR from GitHub's mobile app or web — not from the
   vault. The vault's job ends at "a PR exists."
8. On merge (or manual move), the task note goes to `tasks/done/` with
   a link to the PR.

## Read next

- [docs/setup.md](docs/setup.md) — LXC, Claude Code auth, ECC install
- [docs/workflow.md](docs/workflow.md) — task note format, approval
  convention, branch/PR conventions
- [docs/considerations.md](docs/considerations.md) — every gotcha and
  decision point called out during design
- [docs/resource-notes.md](docs/resource-notes.md) — what this actually
  costs to run alongside your other containers
- [docs/notifications.md](docs/notifications.md) — push notifications,
  crash recovery, and duplicate/collision handling
