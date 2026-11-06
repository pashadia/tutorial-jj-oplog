# jj Mini-Tutorial — The Operation Log

A focused, hands-on deep-dive into **one thing**: the jj (Jujutsu)
**operation log** — the second history jj keeps, the one that records
every repo state you've ever been in and makes almost nothing
destructive.

It is written as a companion to the main jj tutorial (the `tutorial/`
series this one is meant to sit beside; its lessons 01–10, and in
particular lesson 06, which introduced `jj op log` and `jj undo`, and
lesson 08, which introduced workspaces). This mini-tutorial assumes that
background and goes *much* deeper: the storage, the healing, the
locking, the multi-user and multi-machine behavior, and the edges where
it bends.

**Requires jj 0.46.0 or newer** — check with `jj --version`, and see
[jj's install page](https://docs.jj-vcs.dev/latest/install-and-setup/) if you need a
newer one. The scripts refuse to run on older jj rather than silently
producing different output. The helper scripts
(`reset-sandbox.sh`, `check.sh`, `new-lab.sh`) have a `bash` hashbang and
run fine from any shell, fish included. **Type the lesson snippets in
bash or zsh**, though: they use `VAR=$(…)`, `<(…)`, `for … do … done`
and `name() { … }` functions, which fish doesn't speak. If fish is your
login shell, just run `bash` first and `exit` when you're done.
Several exercises use behavior that changed recently — most notably:
`jj undo`/`jj redo` refusing cross-workspace operations (new in
0.46), `jj op abandon`/`revert`/`integrate`/`--no-integrate-operation`
(post-0.41), the removed `jj git push --allow-new`, and
`jj util gc --expire` accepting only the literal string `now`.

## Structure

- **Lessons**: `lessons/01-*.md` … `lessons/08-*.md`. Theory first,
  then exercises you run in a real repo, then `./check.sh`.
- **Labs**: `./new-lab.sh lab-<name>` makes a fresh seeded repo
  (`lab-ops`, `lab-forks`, `lab-internals`) for destructive or
  timing-sensitive experiments, so they never touch the sandbox.
- **Sandbox**: `sandbox/` — a disposable colocated jj+git repo,
  recreated by `./reset-sandbox.sh`, which also creates the empty
  "team remote" `shared-remote.git` for lesson 06.
- **Checks**: `./check.sh <NN>` inspects the sandbox after each
  lesson: PASS/FAIL per exercise, hints on failure, re-runnable. It
  won't touch your commits or bookmarks (though, like any jj command,
  it may snapshot a dirty working copy — which only adds an op).

## How to use

```bash
cd ~/work/google-jj/tutorial-oplog
./reset-sandbox.sh          # fresh sandbox + shared-remote.git
$EDITOR lessons/01-the-second-history.md
# do the exercises in sandbox/ as you read
./check.sh 01               # verify
```

Lessons build on each other — do them in order the first time.
`./reset-sandbox.sh` wipes `sandbox/`, `side-task/` (and lesson 04's
extra workspace dirs) and `colleague/`,
so every lesson can start from a clean slate if you get lost
(and notice: resetting is itself exactly the op-log skill being
taught).

## Conventions

- Commands run inside `tutorial-oplog/sandbox/` unless a lesson says
  otherwise (lesson 04 uses `../side-task`, lesson 06 `../colleague`).
- Commands to type are fenced `console` blocks; expected output is
  elided or shown as illustrative fragments (your hashes/timestamps
  will differ).
- Exact quoted strings (messages, op descriptions, errors) are
  **jj 0.46.0 output**, verified against the v0.46.0 release.
- Lessons mark facts that come from jj's docs, its source, or
  experiments; where behavior is version-sensitive, the lesson says
  so.

## Lessons

1. [The second history](lessons/01-the-second-history.md) — operations
   vs commits, views vs trees; the snapshot/command/update sandwich;
   reading `jj op log`; `args:` attribution; the op-set grammar
   (`@--`, not `@-2`); diffing ops; op templates.
2. [The undo toolbox](lessons/02-the-undo-toolbox.md) —
   `undo`/`redo` stack semantics; `op restore` (and the
   snapshot-safety net that saves uncommitted work);
   `op revert`; merge ops as second-class citizens;
   `op abandon` + `jj util gc` — the only true deletion;
   `--at-op`; detached operations and `op integrate`; then a lab:
   `op restore --what`, reverting an op others depend on, abandoning
   the op a workspace points at, `--reversed`/`op show`/`op diff`
   flags, the `at_operation()` revset, and when `--at-op=@` snapshots.
3. [Under the hood](lessons/03-under-the-hood.md) — the op store's
   on-disk anatomy; BLAKE2b content addressing; head-marker files and
   the crash-safe add-first protocol; the three locks; the op-linked
   commit index; growth and garbage collection; then a lab with
   `jj debug object`, the working-copy pointer, the index internals and
   gc's mtime guard.
4. [Workspaces: one repo, many working copies, one
   log](lessons/04-workspaces-one-log.md) — shared vs per-workspace
   state; per-op attribution; stale working copies and the four
   freshness outcomes; `update-stale`; cross-workspace undo; the
   workspace lifecycle (`forget`, `remove`, `rename`, name re-use, sibling
   and recovery-commit paths, `snapshot.auto-update-stale`).
5. [Forks and healing](lessons/05-forks-and-healing.md) — how
   divergent op heads arise (on purpose and by accident); the 3-way
   view merge; `reconcile divergent operations`; bookmark conflicts
   born from concurrency; racing processes, safely; then a lab:
   who wins a conflict (deterministic reconcile with pinned clocks),
   reword-vs-child and reword-vs-reword, conflicts born inside a
   reconcile, tie-breaking, reading mid-fork, the silent crash-window
   heal, a real `Concurrent working copy operation`, and the sibling
   working copy.
6. [Two users, one remote](lessons/06-two-users-one-remote.md) — why
   the op log never travels; what `fetch`/`push`/`clone` write into
   *your* log; divergence by design; conflicted bookmarks and
   divergent changes across the wire; `jj converge`.
7. [One repo directory, two machines](lessons/07-shared-directory.md) —
   NFS/Dropbox/rsync: what jj documents, what the protocol actually
   guarantees, what is genuinely unsafe (working copies, the git
   backend), and the policy that falls out; then a hands-on lab that
   merges two *real* op logs at the file level (what is union-safe, what
   errors partial syncs give, why `rsync --delete` loses data, the
   pull-run-push rule), plus a fetch racing local ops and `jj undo` of a
   push.
8. [True op-log sync: jj Commit Cloud](lessons/08-commit-cloud.md) —
   a code-reading capstone: the extension that *relocates* the op log
   to a server; server-side reconciliation with jj's own merge
   machinery; contention, divergence, and dropped fields; costs and
   open questions.

## What you will be able to do afterwards

- Read the op log fluently: every field, every description string,
  every template keyword — and use it as a forensic tool.
- Recover from anything: bad rebase, bad fetch, bad `git` afternoon,
  interrupted commands, stale working copies, racing processes.
- Explain *why* it's safe: content addressing, atomic head markers,
  tolerant unlinks, healing merges — and where the guarantees end.
- Predict multi-user behavior: what converges (change IDs), what
  never does (op logs), what conflicts look like, and how each kind
  of conflict is resolved.
- Know the one true deletion path (`op abandon` + `util gc`), the
  display quirks (merge ops diff to nothing), and the version
  boundaries (0.41 vs 0.46).
