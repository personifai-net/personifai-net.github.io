# Worktrees & Multi-Agent Policy

> **Scope:** Applies to **every repo** in this project (same list as [BRANCHING.md](./BRANCHING.md)).
>
> **This doc governs *where* agents do their work** so that multiple Claude sessions on the same filesystem don't step on each other's branches, stashes, or working tree. Branch-flow rules still live in [BRANCHING.md](./BRANCHING.md); this doc is strictly about working-directory isolation.

---

## The Rule In One Sentence

Every Claude session that will create a branch, commit, or push does so in a **git worktree** under `.worktrees/<session-id>/`; the main repo clones stay on `dev` and are treated as read-only reference + `git pull` targets.

---

## Directory Model

```
/mnt/c/Users/rbell/PROJECTS/personifAI-dev/
├── pai-core/              ← main clone, stays on dev, READ-ONLY for agents
├── pai-mobile-backend/    ← main clone, stays on dev, READ-ONLY for agents
├── pai-environment/       ← main clone, stays on dev, READ-ONLY for agents
├── pai-web/               ← main clone, stays on dev, READ-ONLY for agents
│   …
└── .worktrees/
    ├── <session-id-A>/
    │   ├── pai-core/           ← worktree on feature/<slug>
    │   └── pai-web/            ← worktree on feature/<slug>
    └── <session-id-B>/
        └── pai-mobile-backend/ ← worktree on feature/<other-slug>
```

- `.worktrees/` sits at the project root, **outside** any individual repo.
- Each session gets a single `.worktrees/<session-id>/` directory containing one subdirectory per repo it touches.
- Main clones (`pai-core/`, etc.) are **never** branched, committed to, or stashed in by an agent.

---

## Session Lifecycle

```
1. START            → create .worktrees/<session-id>/<repo>/ per repo you'll touch
2. EDIT/COMMIT      → inside the worktree, on feature/<slug>
3. PUSH             → git push -u origin feature/<slug>
4. PR → dev         → rebase-and-merge per BRANCHING.md
5. REFRESH MAIN     → in the MAIN clone of that repo: git pull --ff-only origin dev
6. CLEANUP          → git worktree remove .worktrees/<session-id>/<repo>
                       (in each repo), then delete .worktrees/<session-id>/
```

Step 5 is what makes this multi-agent-safe: the next session's worktree branches off the main clone's `dev`, which is now current. Without step 5, the next session starts behind and will need an extra `git fetch + rebase` cycle.

---

## Required Flow

### 1. Session start — create your worktrees

For each repo you'll modify, from the main clone of that repo:

```bash
cd /mnt/c/Users/rbell/PROJECTS/personifAI-dev/pai-core
git fetch origin
git worktree add \
  /mnt/c/Users/rbell/PROJECTS/personifAI-dev/.worktrees/<session-id>/pai-core \
  -b feature/<slug> origin/dev
```

Repeat for each repo. `cd` into the worktree to do your work.

### 2. Edit, commit, push — inside the worktree only

Standard BRANCHING.md flow. Nothing special; the worktree behaves like a normal checkout.

### 3. PR → `dev` — rebase-and-merge

Per BRANCHING.md §1. Once merged:

### 4. Refresh the main clone

```bash
cd /mnt/c/Users/rbell/PROJECTS/personifAI-dev/pai-core
git checkout dev              # no-op if already on dev
git pull --ff-only origin dev
```

Do this for every repo whose worktree had a PR merged. This is the step that keeps other agents' future worktrees current.

### 5. Clean up the worktree

> **Worktrees are NOT auto-removed when your PR merges.** You must clean up explicitly. Git has no "branch merged → prune worktree" hook, and rebase-and-merge changes SHAs so `git branch --merged` can't detect it. Use the helper script — it uses a **two-signal** rule to classify worktrees safely.

**Required cleanup step (run after your PR is merged and main clone is refreshed):**

```bash
# Dry-run — classifies every worktree and reports what would happen
pai-infra/scripts/prune-merged-worktrees.sh

# Actually remove MERGED worktrees (leaves LIVE/AMBIGUOUS/DIRTY alone)
pai-infra/scripts/prune-merged-worktrees.sh --yes
```

**Classification rules:**

| Label | Meaning | Action |
|---|---|---|
| `MERGED` | `git cherry origin/dev <branch>` is empty AND `origin/<branch>` no longer exists on the remote | Safe to remove (with `--yes`) |
| `LIVE` | Branch has commits not in `dev` | Reported, never removed |
| `AMBIGUOUS` | No unique commits, but `origin/<branch>` still exists | Reported — check the open PR before cleaning up manually |
| `DIRTY` | Would be MERGED, but the worktree has uncommitted/untracked files | **Never force-removed.** Inspect manually. |

Both signals matter: `git cherry` can flicker to "empty" mid-rebase or after an `amend`, so the second check (remote branch gone, which only happens after GitHub auto-deletes on merge) keeps us from pruning an active worktree. Dirty worktrees are always preserved — a manual inspection is safer than losing uncommitted work.

**Manual fallback** (if the script isn't available or you want fine control):

```bash
cd /mnt/c/Users/rbell/PROJECTS/personifAI-dev/pai-core
git worktree remove /mnt/c/Users/rbell/PROJECTS/personifAI-dev/.worktrees/<session-id>/pai-core
git branch -D feature/<slug>  # -D because rebase-and-merge leaves the local branch unmerged by SHA
```

After all repos' worktrees are removed, delete the empty `.worktrees/<session-id>/` directory.

---

## Hard Rules

1. **No committing or stashing in a main clone.** Main clones stay on `dev`, clean. `git pull --ff-only origin dev`, `git fetch origin`, and `git worktree add -b <branch>` are the only git write operations you should run in a main clone. (The `reference-transaction` hook permits branch creation specifically so `git worktree add -b` works; commits are still blocked by `pre-commit`.)
2. **One worktree per branch.** Git enforces this, but: don't try to work around it by checking the same branch out twice.
3. **One `session-id` per Claude session.** Don't reuse a session's worktree dir across unrelated tasks — create a new session-id.
4. **Always refresh the main clone after a merge.** The next agent depends on this.
5. **Never `pip install -e` a worktree.** The `pai` conda env has `pai-core` installed as editable from the **main clone only**. Installing from a worktree will silently point the env at the worktree, breaking every other session. See [Python / Conda Interaction](#python--conda-interaction) below.
6. **Clean up on session end.** Abandoned worktrees accumulate and confuse `git worktree list`. If you find orphans at session start, flag them before removing (they may be another live session's work).

---

## Python / Conda Interaction

This project installs `pai-core` into the `pai` conda env as editable (`pip install -e ./pai-core`). That install points at exactly **one** path — the main clone.

**Implication:** code you edit in a worktree is NOT picked up by `import pai_core` until your changes are merged to `dev` and the main clone is `git pull`'d (step 4 of the lifecycle). Your worktree is for *editing and committing*, not for *running*.

**If you need to run your worktree's version of pai-core before merging** (rare — usually the PR + pull is fast enough):

- **Preferred:** push your feature branch, check it out in the main clone *temporarily*, test, then switch main clone back to `dev`. Announce in session notes that the main clone is temporarily off `dev`.
- **Discouraged but allowed:** set `PYTHONPATH=/path/to/worktree/pai-core` for a single terminal. Never install the worktree with `pip install -e`.

Same principle applies to any other editable install (e.g. `pai-mobile-backend` if ever dev-installed).

---

## Claude Code Integration

Claude Code has first-class worktree support that aligns with this policy:

| Tool | Purpose |
|---|---|
| `EnterWorktree` | Creates a worktree for the current session and switches into it. Pair with `ExitWorktree` to merge or discard at session end. |
| `Agent({ isolation: "worktree", … })` | Spawns a subagent inside an auto-created worktree that's cleaned up automatically if no changes are made. Use this for any subagent that will edit/commit. |

When these tools are used, the harness handles creation and cleanup — but the **post-merge `git pull` in the main clone (step 4)** is still the session's responsibility. The tools don't do that for you.

If doing worktrees manually (multi-repo sessions, or coordinating with another live session), follow the commands in [Required Flow](#required-flow) above.

---

## Quick Reference Commands

```bash
# List all live worktrees for a repo (run from main clone)
git worktree list

# Detect orphaned worktrees (path missing on disk)
git worktree prune --dry-run

# Remove a worktree (after your branch is merged)
git worktree remove <path>
git branch -d feature/<slug>

# Emergency: force-remove a broken/locked worktree
git worktree remove --force <path>
```

```bash
# Full start-of-session setup for a single repo
SESSION=my-session-id
REPO=pai-core
SLUG=add-thing
ROOT=/mnt/c/Users/rbell/PROJECTS/personifAI-dev

cd $ROOT/$REPO
git fetch origin
git worktree add $ROOT/.worktrees/$SESSION/$REPO -b feature/$SLUG origin/dev
cd $ROOT/.worktrees/$SESSION/$REPO
# …edit, commit, push, PR, merge…

# After merge: refresh main clone
cd $ROOT/$REPO
git checkout dev && git pull --ff-only origin dev

# Clean up worktree
git worktree remove $ROOT/.worktrees/$SESSION/$REPO
git branch -d feature/$SLUG
```

---

## Why This Model

- **Isolated working trees** mean two Claude sessions can edit the same repo concurrently without fighting over the index, stash, or HEAD.
- **Main clone as canonical `dev` mirror** gives every new worktree a current base without requiring agents to coordinate fetches — the merge-then-pull step does it once, for everyone.
- **Single editable install** keeps the `pai` conda env deterministic. No session's running Python code silently picks up another session's half-written changes.
- **One `.worktrees/` root** makes orphan detection and cleanup trivial: `ls .worktrees/` is the list of live (or recently-live) sessions.

---

## Filesystem-Enforced Policy (Opt-In Hooks)

The policy above is backed by two git hooks that turn the rules into filesystem-level enforcement in each main clone. They're opt-in per machine — the files travel with each repo, but activation is a one-time `git config` per clone.

**What the hooks do (in main clones only; worktrees are unaffected):**

| Hook | Blocks |
|---|---|
| `pre-commit` | All commits. Main clones are read-only for new work. |
| `reference-transaction` | Deletion of `dev`/`staging`/`main`. Non-fast-forward updates to those three (catches `git reset --hard` and rebases on protected branches). |

**Non-protected branch operations are intentionally allowed in main clones** — you need `git worktree add -b <branch>` to work, and that creates a ref. `pre-commit` ensures no new work can accumulate regardless.

**Canonical source:** [`pai-infra/.githooks/`](./pai-infra/.githooks/) — checked into `pai-infra` so the hooks are versioned and reviewable.

### Installing / updating hooks

Run once on a fresh clone, and any time the canonical hooks change:

```bash
pai-infra/scripts/install-worktree-hooks.sh
```

This propagates `pai-infra/.githooks/` into each sibling `pai-*` repo's `.githooks/` and runs `git config core.hooksPath .githooks` per clone. Idempotent.

Options:
- `--dry-run` — preview without writing.
- `pai-core pai-web` — restrict to specific repos.

### Checking status

To see which clones have opted in and whether their hooks are current:

```bash
pai-infra/scripts/check-worktree-hooks.sh
```

Exit code is non-zero if any repo is missing hooks or running a stale version — useful in a shell prompt or pre-session sanity check.

### When a colleague clones fresh

A clone picks up `.githooks/` only after they've run the install script. Until then, the hooks are inert. That's intentional: a colleague working solo doesn't need multi-agent enforcement. Anyone running parallel Claude sessions on the same machine **should** run the install script after cloning.

### Known limitations

- Hooks respect `--no-verify`. Policy still says "don't skip hooks" — this is a belt for a worn policy, not a hard guarantee.
- Hooks only enforce in the main clone. If someone manually creates a second main-style clone elsewhere, that clone needs its own opt-in.
- True cross-machine enforcement lives in GitHub branch protection / rulesets, not git hooks.

---

## What To Do When Something Goes Wrong

- **`git worktree add` says the branch is already checked out elsewhere.** Another session owns it. Pick a different slug or coordinate explicitly — do not delete the other worktree.
- **Main clone is off `dev` (someone forgot to switch back after testing).** Check `git status` — if clean, `git checkout dev && git pull`. If dirty, stash or commit somewhere safe first; the dirtiness is not yours to discard.
- **`.worktrees/<session-id>/` exists but you don't remember creating it.** It's likely an orphan from a crashed session. Confirm no live session is using it (`git worktree list` in each repo), then `git worktree remove --force` and delete the dir.
- **`pip install -e` was run against a worktree and the conda env is now broken.** Reinstall from the main clone: `pip install -e /path/to/main/pai-core` from within the `pai` env.
- **Two sessions merged conflicting PRs into `dev`.** Standard git conflict resolution — the later rebase-and-merge will fail at the PR; rebase and resolve per BRANCHING.md. Worktrees don't change this.
