# Workflow

## Task note format

Task notes are plain markdown with frontmatter. Minimum viable note:

```markdown
---
repo: my-project
base: main
---

Add a rate limiter to the /api/upload endpoint. Should reject with 429
after 10 requests/minute per IP. Add a test for the rejection case.
```

- `repo` — which cloned project this applies to (matches a directory
  name under `~/projects/`)
- `base` — branch to fork from and PR back into. Defaults to `main` if
  omitted.

## Backlog/ — optional, unautomated

`Backlog/` is a holding area for small ideas and work-in-progress
notes. Nothing watches it, nothing acts on it. Use it however you
like — half-formed thoughts, drafts you're still editing, things you
want to think about before committing to. It exists purely so
`tasks/to-do/` doesn't get cluttered with things that aren't actually
ready yet.

## Queuing a task: the `-ready` suffix

Only files whose name ends in `-ready.md` inside `tasks/to-do/` are
picked up for planning. A plain `.md` file in that same folder is
inert — you can drop a task there while still drafting it, and
nothing happens until you rename it.

```
tasks/to-do/add-rate-limiter.md          ← sitting there, ignored
tasks/to-do/add-rate-limiter-ready.md    ← triggers planning
```

This means `tasks/to-do/` can double as your near-term staging area —
draft freely, rename to add `-ready` the moment you actually want it
picked up. No separate move between folders is required to queue
something, only a rename.

## Planning stage

`watch-todo.sh`:
1. Detects a new `*-ready.md` file in `tasks/to-do/`
2. Waits for a quiet period (no writes for ~8s) to avoid reading a
   file mid-Syncthing-sync
3. Strips the `-ready` suffix and moves it to `tasks/in-progress/`
4. Runs `claude -p` with `/plan` against the note's content
5. Writes the plan to `plans/<task-name>.plan.md`
6. Stops. Does not implement.

## Approval

You review the plan in Obsidian. To approve, rename the file:

```
plans/add-rate-limiter.plan.md  →  plans/approved-add-rate-limiter.plan.md
```

The `approved-` prefix is the trigger `watch-approved.sh` looks for.
If you want changes instead, edit the plan file in place — the
watcher only reacts to the prefix, not to content changes, so you can
iterate on a plan without accidentally triggering implementation.

## Implementation + PR

`watch-approved.sh`, on seeing an `approved-*.plan.md` file:

1. Reads `repo` and `base` from the original task note
2. `cd ~/projects/<repo>`
3. `git fetch origin <base> && git checkout -b task/<task-name> origin/<base>`
4. Runs `claude -p` invoking the `tdd-workflow` skill against the plan
5. Runs `/code-review`, addresses findings
6. Runs the project's build/test/lint (via `/quality-gate` or your
   project's own scripts)
7. Commits, pushes the branch
8. `gh pr create --base <base> --head task/<task-name> --fill`
9. Writes a summary + PR link to `tasks/done/<task-name>.md`
10. Moves the original task note and plan file into `tasks/done/`

## What the vault is NOT responsible for

Code review happens on GitHub, not in the vault. The vault's job ends
the moment a PR exists — don't try to review diffs inside Obsidian.
This keeps the "blast radius" of an unattended process bounded to a
branch and a PR, never a direct commit to `base`.
