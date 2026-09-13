# Resource notes

No local model inference happens anywhere in this system. Claude Code
calls the Anthropic API for every planning/implementation/review step;
the LXC's job is orchestration (file watching, git, `gh`), not compute.

| Component | Footprint |
|---|---|
| ECC install (skills/agents/rules as markdown+JSON) | Tens of MB on disk |
| Idle state | ~0 — no persistent daemon unless hooks are enabled (they aren't, by design) |
| `claude -p` session (active) | Single Node.js process, roughly comparable to any CLI tool — brief CPU bursts, modest RAM while running |
| `watch-todo.sh` / `watch-approved.sh` (inotify-based) | Essentially free — kernel-level file event listening, not polling |
| Build/test runs during implementation | Depends entirely on the target project, not on ECC or Claude Code themselves |

Comparable in weight to the Syncthing daemon: mostly idle, brief
activity spikes tied to actual task runs. Lighter than Jellyfin
transcoding or any ML-based indexing (e.g. Immich) you may be running
elsewhere on the same host.

The LXC-level CPU/RAM caps in [setup.md](setup.md) exist to bound the
*build/test* step of a task, not the orchestration layer — a bad test
suite or infinite loop in a project you're working on is the
realistic resource risk, not ECC or Claude Code itself.
