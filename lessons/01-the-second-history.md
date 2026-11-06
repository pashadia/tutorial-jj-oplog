# Lesson 01 — The second history

## Theory

### Two histories, one repo

Main-tutorial lesson 06 introduced the split: **change IDs** identify
commits; **operation IDs** identify repo *states*. This tutorial is about
the second history. The analogy jj's own docs use
(`docs/technical/concurrency.md`): the operation log is *like a commit DAG*
— but each "commit" is an **operation**, and each "tree" is a **view**:

- The **view** is a complete snapshot of repo state: the set of head
  commits, every bookmark and tag (and git ref, in git-backed repos), and
  the working-copy commit of *every* workspace.
- The **operation** points at one view, plus parent operation(s), plus
  metadata: start/end timestamps, username, hostname, description, a
  snapshot flag, and the workspace it ran from.

The very first operation is the **root op**, displayed as
`000000000000 root()` — an empty repo, before any workspace existed.

Why a second history at all? Because it records *atomic updates of all
refs at once* — "the operation log replaces reflogs" (`git-comparison.md`),
but per-ref, pieced-together reflog archaeology becomes one browsable DAG.

### Every command is a sandwich

Almost every jj command runs in three steps (`docs/working-copy.md`):

1. **Snapshot** the working copy — recorded as an operation.
2. Compute the command's changes in memory — recorded as a new operation.
3. **Update** the working copy to the new state.

Consequences you can *see* in the op log:

- Read-only commands still write ops: a `jj st` with dirty files creates
  a `snapshot working copy` op — attributed (with the *canonical* name)
  to `jj status`, even though you typed the `st` alias.
- `jj op log` itself snapshots by default — the *first jj command you
  run* with dirty files gets the credit. To inspect without mutating:
  `jj op log --at-op=@ --ignore-working-copy`.
- `jj commit` produces *two* ops: the snapshot, then the commit.
- Steps 1–3 can skip step 3 (another workspace rewrote your commit) —
  that's the *stale working copy* of lesson 04.

Manual/periodic snapshots: `jj util snapshot` (prints `No snapshot
needed.` when clean). Scripts that run jj commands should sandwich them
with `jj util snapshot` so the file-capture op stays separate from the
script's own ops (a documented recipe in `jj util snapshot --help`).

Snapshot filtering: `snapshot.auto-track` (default `all()`) and
`snapshot.max-new-file-size` (default 1 MiB) — an untracked or oversized
file produces *no* operation at all.

### Reading an entry

A default `jj op log` entry is **three lines** (the exceptions below
prove the rule):

```text
@  3ca9af4e554e bogdan@nixos default@ now, lasted 19 milliseconds
│  push bookmark main to git remote origin
│  args: jj git push -b main
```

- Line 1: node glyph (`@` current, `○` others), 12-hex op id (always 12 —
  truncation, not shortest-unique), `user@host`, `workspace@`, relative
  end time + duration.
- Line 2: description, first line only.
- Line 3: `args:` — the shell-quoted command line that created the op.
  Only present when the op has attributes; ops created by lib-level
  transactions (e.g. `add workspace 'default'`) have neither a workspace
  field nor an `args:` line.

A colocated repo initialized on top of an existing git history is born
as: `root()` → `add workspace 'default'` → `import git refs` → `import
git head` — then everything you did. (An empty directory skips the
imports: there is nothing to import. Your sandbox was seeded with git
first, so it shows the full chain — exercise 1.1.)

### Attribution — and privacy

The `user@host` column comes from `operation.username` /
`operation.hostname` (overridable via `$JJ_OP_USERNAME` /
`$JJ_OP_HOSTNAME` — useful for the two-user exercises of lesson 06).
The `args:` attribute records *your full command line*. For screenshots
and demos there's a built-in redacted template:
`jj op log -T builtin_op_log_redacted` prints `user-64dc workspace-ab88@`
and `(redacted)` instead.

### The op-set grammar — not revsets!

Operation arguments are *not* revsets. The grammar is: `@`, any
unambiguous hex prefix of the 128-hex op id, and `x-` / `x+` for
parents/children — **repeated literally**: `@-` is one back, `@--` two,
`@----` four. There are no symbolic names:

```console
jj op show @-2
# Error: Operation ID "@-2" is not a valid hexadecimal prefix
jj op revert 'root()'
# Error: Operation ID "root()" is not a valid hexadecimal prefix
```

`@+` walks children from the current heads, so it errors with
`resolved to more than one operation` (with a hint listing candidates)
or `resolved to no operations`. `--at-op` accepts the same grammar.

### Diffing operations

- `jj op show [<op>]` — one op vs its parent(s); default target `@`.
- `jj op log -d` / `-p` — per-op diffs down the log (`-p` implies `-d`;
  any diff-format flag like `--stat` implies it too).
- `jj op diff --from <op> --to <op>` (or `--op <op>` for op-vs-parent;
  a missing `--from`/`--to` side defaults to `@`).

Sections you'll see, in order: `Changed commits:`,
`Changed working copy <ws>@:`, `Changed local bookmarks:`,
`Changed local tags:`, `Changed remote bookmarks:`,
`Changed remote tags:`. Ref changes print `+`/`-` lines, or `(absent)`,
or `(added) …`/`(removed) …` for conflicted targets. Description-only
changes appear as a pseudo-file diff (`Modified JJ-COMMIT-DESCRIPTION:`).

Boring revisions are elided into `   (Elided N …)` counts — controlled
by `revsets.op-diff-changes-in` (default `mutable() | immutable_heads()`)
or per-invocation `--show-changes-in=all()`.

Merge ops (reconciled divergent operations — lesson 05) are deliberately
silent here: `op show`/`op log -d` print *no diff* for them.

### Templates for operations

All ten `Operation` methods: `current_operation()`, `description()`,
`id()`, `attributes()`, `time()`, `user()`, `snapshot()`,
`workspace_name()`, `root()`, `parents()`. Gotchas worth knowing:
`user` is already `user@host`; `workspace_name` already has a trailing
`@` (but `json(self)` gives the bare name); `parents.len() > 1` detects
merge ops; `id.short()` truncates (never disambiguates). Built-in
templates: `builtin_op_log_compact` (default),
`builtin_op_log_comfortable`, `builtin_op_log_oneline`,
`builtin_op_log_redacted`. `json(self)` works — handy for scripting.

## Exercises

Do these in `sandbox/` after `./reset-sandbox.sh`.

**1.1** Read your repo's birth certificate:

```console
jj op log
```

Identify: the root op, `add workspace 'default'` (no workspace field, no
args — why?), and the two `import git …` ops (the sandbox history was
seeded with plain `git` *before* `jj git init --colocate .` — that's
what those ops are importing; `main` arrives as a bookmark inside the
`import git refs` op — see it with `jj op show <that op>`). Match every
`args:` line to a command in `reset-sandbox.sh`. Nothing was snapshotted
at birth — the working copy was clean.

**1.2** Watch a snapshot happen:

```console
echo 'draft' >> src/greet.py
jj st                        # the snapshot happens HERE — jj st is the first
                            # jj command to see the dirty file
jj op log -n 2               # top op: "snapshot working copy", args: jj status
jj st                        # nothing left to snapshot
jj op log -n 2               # unchanged — no new op
jj util snapshot             # No snapshot needed.
```

Two details to notice: the `args:` line records the **canonical** name
(`jj status`), not the alias you typed — and had the first command you
run been `jj op log` instead, *it* would have written the snapshot op
(with `args: jj op log -n 2`). The op log credits whichever command got
there first.

**1.3** Anatomy and templates:

```console
jj op log -T builtin_op_log_oneline
jj op log -T builtin_op_log_redacted      # privacy view
jj op log --no-graph -T 'id.short() ++ " " ++ time.end().ago() ++ "  " ++ workspace_name ++ " " ++ description.first_line() ++ "\n"'
jj op log --no-graph -n 1 -T 'json(self)'
```

Note the trailing `@` on `workspace_name` and the bare name in JSON.

**1.4** Diff operations:

```console
jj op show            # the latest op (vs its parent)
jj op log -p -n 4     # snapshots and their file diffs
jj op log -d -n 6 2>/dev/null | grep -A2 'Changed local bookmarks:'
jj op diff --from @-- --to @
```

Push a revision's noise down with `--show-changes-in=all()` if elision
hides something you care about. The `2>/dev/null` is a precaution: the
birth ops (`add workspace`, the imports) diff against views that predate
your workspace, and if your `revsets.log` contains a bare `@` (for
example `visible_heads() | @ | …`) jj prints a *wall* of
`Failed to load short-prefixes index` template warnings on stderr for
those — the same degenerate state lesson 02 will show you on purpose.
With jj's default config you will see no warnings at all. Either way
stdout stays clean; only the noise is stderr.

**1.5** Learn the grammar the honest way:

```console
jj op show @-
jj op show @--
jj op show @-2        # Error: Operation ID "@-2" is not a valid hexadecimal prefix
jj op show 0000       # root op by prefix (with a bare-`@` revsets.log: the same warning wall as 1.4)
jj op show @+         # Error: The "@+" expression resolved to no operations
```

**1.6** Attribution:

```console
echo 'more draft' >> src/greet.py     # something for the next command to snapshot
JJ_OP_USERNAME=colleague JJ_OP_HOSTNAME=laptop jj op log -n 2
```

The new top op (the snapshot this very command triggered!) is attributed
to `colleague@laptop`. That's the identity mechanism lesson 06 exploits.

Going further: the FAQ's live-monitor recipe —
`watch --color jj --ignore-working-copy log --color=always`, or
`watchexec --watch=.jj/repo/op_heads/heads -- jj --ignore-working-copy log`.

## Verify

```console
./check.sh 01
```
