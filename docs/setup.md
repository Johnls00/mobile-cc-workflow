# Setup

## 1. Proxmox LXC

- Unprivileged container, Debian or Ubuntu base
- 2-4 vCPU, 2GB RAM, 20-30GB disk is plenty
- Set CPU/memory limits at the LXC level so a stuck build/test process
  can't starve other containers

```bash
apt update && apt install -y git curl build-essential inotify-tools acl
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs
npm install -g @anthropic-ai/claude-code   # confirm actual package name
                                            # against current docs before running
```

`inotify-tools` (for `inotifywait`) is required by both `watch-todo.sh`
and `watch-approved.sh` — without it the watchers fail immediately on
start. `acl` (for `setfacl`/`getfacl`) is needed for step 2 below.

Package installs like these are done as root, since that's normal LXC
provisioning. The automation itself — `claude`/`gh` auth and the
systemd services — runs as a dedicated non-root user, created next.

## 2. Create the automation user

```bash
useradd -m -s /bin/bash mcw
```

This isn't optional cosmetics: `watch-approved.sh`'s implementation step
runs `claude -p --allow-dangerously-skip-permissions` (needed because
there's no TTY to answer a permission-to-edit prompt non-interactively),
and **Claude Code refuses that flag outright when running as root** —
`--dangerously-skip-permissions cannot be used with root/sudo privileges
for security reasons`. Every step below that involves `claude` or `gh`
auth, and all three systemd units (already configured with `User=mcw`
in `scripts/systemd/*`), run as this user rather than root.

## 3. Mount the Syncthing vault

Decide where Syncthing actually runs:

- **Option A:** Syncthing already runs in its own LXC/container. Bind-mount
  that vault folder into this LXC read-write.
- **Option B:** run a Syncthing instance inside this LXC as another peer
  of your existing vault.

Option A avoids duplicating sync endpoints and is the simpler mental
model — one Syncthing folder, multiple mounts of the same data.

```
# Example bind mount (adjust to your actual container IDs)
pct set <this-ctid> -mp0 /mnt/syncthing-data/vault,mp=/vault
```

Whatever mounts at `/vault` is very likely owned by `root` (Syncthing on
the other side typically runs as root too), so `mcw` has no access to it
by default. Grant it explicitly, including a default ACL so files/folders
created later (by Syncthing writing synced notes) inherit the same
access:

```bash
setfacl -R -m u:mcw:rwx -m d:u:mcw:rwx /vault
```

Verify: `su - mcw -c "touch /vault/tasks/to-do/.acltest && rm /vault/tasks/to-do/.acltest"`
should succeed silently.

If your vault is a general-purpose Obsidian vault shared with other
notes (finance, credentials, unrelated projects) rather than one
dedicated to this system, don't bind-mount the whole thing — create a
subfolder scoped to just this workflow (matching `vault-template/`'s
layout: `Backlog/`, `tasks/{to-do,in-progress,done}/`, `plans/`,
`logs/`) and mount only that subfolder as `/vault`. Otherwise the
automation user — and any `claude -p` run under it — has filesystem
access to everything else in the vault too.

## 4. Claude Code authentication (headless)

This LXC has no browser. Claude Code's normal login flow expects one.
Run this **as `mcw`**, not root:

```bash
su - mcw -c "claude auth login"
# follow the printed URL on your phone/laptop to authorize
```

Test this in isolation before building anything on top of it — it's
the step most likely to behave differently than expected on a
headless box. Verify with `su - mcw -c "claude auth status"`.

## 5. Git + GitHub CLI

```bash
apt install -y gh
su - mcw -c "gh auth login"
su - mcw -c "gh auth setup-git"
su - mcw -c 'git config --global user.name "your-name"'
su - mcw -c 'git config --global user.email "your-email"'
```

`gh auth login` alone does **not** configure git's credential helper —
`watch-approved.sh` calls raw `git fetch`/`git push` (not `gh`'s own
wrappers), and without `gh auth setup-git` those fail with `fatal: could
not read Username for 'https://github.com'` the moment they hit a private
repo, non-interactively, with nothing to prompt. Confirm it worked:
`su - mcw -c "git config --global --list | grep credential"` should show
`credential.https://github.com.helper=!/usr/bin/gh auth git-credential`.

The account/token `gh` authenticates as will be the author of every
PR this system opens. Consider whether you want a dedicated bot
account rather than your personal one, especially if you ever grant
this LXC access to work repos.

## 6. Install ECC (minimal profile)

```bash
su - mcw -c "git clone https://github.com/affaan-m/ECC.git ~/ECC"
su - mcw -c "cd ~/ECC && ./install.sh --profile minimal --no-hooks --target claude"
```

Minimal + no-hooks is deliberate: the hook runtime assumes an
interactive session reacting to events. This system's trigger model
is a file-watcher calling `claude -p` non-interactively, so hooks add
complexity without buying anything here.

Verify the commands this system depends on actually exist before
wiring up the watchers. This matters more than it sounds: an unknown
slash command doesn't make `claude -p` fail — it exits 0 and just
prints `Unknown command: /whatever` as if that were the plan, so
`watch-todo.sh` writes that one line to `plans/<name>.plan.md` and
notifies "Plan ready" as if planning succeeded. Nothing here surfaces
as an error; the wrong output just quietly becomes the plan.

```bash
su - mcw -c 'claude -p "/plan
Task note:
---
repo: some-test-repo
base: main
---
A one-line placeholder task. Write the plan only, do not implement." \
  | head -5'
```

If this prints `Unknown command: ...` instead of the start of a real
plan, the command name is wrong — check `~/.claude/commands/` for what
actually got installed (`claude plugin list` may report "No plugins
installed" even when ECC's commands work fine as flat, unnamespaced
slash commands; don't assume a `<plugin>:<command>` prefix without
checking).

## 7. Install the watcher scripts

```bash
cp scripts/watch-todo.sh scripts/watch-approved.sh scripts/sweep-stale.sh \
  /usr/local/bin/
chmod +x /usr/local/bin/watch-todo.sh /usr/local/bin/watch-approved.sh \
  /usr/local/bin/sweep-stale.sh

cp scripts/systemd/*.service scripts/systemd/*.timer /etc/systemd/system/
```

All three unit files already have `User=mcw` and `Environment=HOME=/home/mcw`
baked in — that's what makes steps 4-6 above need to run as `mcw` in the
first place, so the credentials/config the services read at runtime
actually match what got set up.

Before starting anything, edit **every** copied unit file
(`/etc/systemd/system/{watch-todo,watch-approved,sweep-stale}.service`)
and replace `NTFY_TOPIC=your-topic-here` with your actual ntfy topic —
see [notifications.md](notifications.md) for how to pick one. Also
confirm `VAULT_PATH` and `PROJECTS_DIR` match where you mounted the
vault (step 3) and where you'll clone repos (step 8) — `PROJECTS_DIR`
defaults to `/home/mcw/projects` since `mcw` (unlike root) can't reach
anything under `/root`.

```bash
systemctl daemon-reload
systemctl enable --now watch-todo.service watch-approved.service
systemctl enable --now sweep-stale.timer
```

Check both watchers came up clean before relying on them:

```bash
systemctl status watch-todo.service watch-approved.service
journalctl -u watch-todo.service -u watch-approved.service -f
```

## 8. Project repos

Clone the actual repos you'll be working on into the LXC as `mcw`, e.g.
`su - mcw -c "gh repo clone <owner>/<repo-name> ~/projects/<repo-name>"`.
Task notes reference these by name (see [workflow.md](workflow.md)).
