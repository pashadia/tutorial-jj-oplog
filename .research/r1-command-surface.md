# R1 — Complete user-facing surface of the operation log in jj 0.46.0

Research artifact for the op-log tutorial. **Ground truth = the v0.46.0 release.**

Binaries / sources used:

| What | Path / ref |
| --- | --- |
| Official 0.46.0 binary | `/home/bogdan/work/google-jj/tutorial-oplog/tools/jj` → reports `jj 0.46.0-7d382314f9420b4b8d932245b49c99492c812b9f` |
| Docs pinned to the release | `git -C /home/bogdan/work/google-jj/jj-upstream show v0.46.0:docs/...` |
| Source pinned to the release | `git -C ... show v0.46.0:cli/src/...` |
| Local clone state | `main` = `v0.46.0-203-gbdefa37df`; the `[Unreleased]` CHANGELOG block is **out of scope** |

All empirical output below was produced with the 0.46.0 binary inside throwaway `mktemp -d`
repos, always with `--color=never`. Nothing inside `/home/bogdan/work/google-jj` was mutated.

Notation: `⟨…⟩` marks a value interpolated by jj. Strings in `"double quotes"` are exact,
byte-for-byte jj output. Line breaks inside a message are shown as separate lines.

---

## 1. Command reference

### 1.1 Top-level shape

```
jj operation <COMMAND>            # canonical name
jj op <COMMAND>                   # built-in alias
```

Exact `jj op --help` body (v0.46.0):

```
Commands for working with the operation log

See the [operation log documentation] for more information.

[operation log documentation]: https://docs.jj-vcs.dev/latest/operation-log/

Usage: jj operation [OPTIONS] <COMMAND>

Commands:
  abandon    Abandon operation history
  diff       Compare changes to the repository between two operations
  integrate  Make an operation part of the operation log
  log        Show the operation log
  restore    Create a new operation that restores the repo to an earlier state
  revert     Create a new operation that reverts an earlier operation
  show       Show changes to the repository in an operation
```

There is **no** `jj op id`, `jj op gc`, `jj op export`, `jj op import`, or `jj op forget`.
`jj util gc` (not `jj op *`) is what actually deletes abandoned objects. Its help states:
*"To garbage-collect old operations and the commits/objects referenced by them, run
`jj op abandon ..<some old operation>` before `jj util gc`."* — and by default only objects/operations
older than 2 weeks are pruned (`--expire`).

Two commands live outside `jj op` but are part of the same surface: `jj undo` and `jj redo`.

### 1.2 `jj op log`

```
Usage: jj operation log [OPTIONS]

  -n, --limit <LIMIT>              Limit number of operations to show
                                   Applied after operations are reordered topologically,
                                   but before being reversed.
      --reversed                   Show operations in the opposite order (older operations first)
  -G, --no-graph                   Show a flat list of operations instead of a graph
  -T, --template <TEMPLATE>        Render each operation using the given template
                                   If not specified, this defaults to the `templates.op_log` setting.
  -d, --op-diff                    Show changes to the repository at each operation
  -p, --patch                      Show patch of modifications to changes (implies --op-diff)
```

Plus the whole "Diff Formatting Options" group (`-s/--summary`, `--stat`, `--types`,
`--name-only`, `--git`, `--color-words`, `--tool`, `--context`, `--ignore-all-space`,
`--ignore-space-change`, `--show-changes-in <REVSETS>`) and the global group.

Facts that matter for the tutorial (verified against `cli/src/commands/operation/log.rs`
at v0.46.0 and empirically):

- **Default limit is unlimited.** Source: `op_walk::walk_ancestors(...).take(args.limit.unwrap_or(usize::MAX))`.
  `jj op log -n 0` prints nothing and exits 0.
- `-n` is applied *after* topological reorder, *before* `--reversed`. So `--reversed -n 3`
  gives the **3 newest** ops, printed oldest-first (verified).
- `jj op log` **snapshots the working copy** by default, i.e. it can create an op. Its own
  help says: *"Like other commands, `jj op log` snapshots the current working-copy changes and
  reconciles divergent operations. Use `--at-op=@ --ignore-working-copy` to inspect the current
  state without mutation."*
- Any diff-format flag (e.g. bare `--stat`) **implies `--op-diff`**: `maybe_show_op_diff` is
  built when `args.op_diff || !diff_formats.is_empty()` (`log.rs`).
- `--op-diff`/`-d` and `-p` are silently skipped for merge (divergent-reconcile) operations:
  `if parent_ops.len() > 1 { return Ok(()); }` (`log.rs`), confirmed empirically — `jj op log -d`
  prints no diff block for a "reconcile divergent operations" op.
- Working-copy-writable check: when the repo is *not* writable (e.g. `--at-op`/`--ignore-working-copy`),
  `cmd_op_log` loads the workspace **without** loading the repo, so the op history can be inspected
  even when the repo is corrupted ("so you can find the first bad operation id to be abandoned").

### 1.3 `jj op show`

```
Usage: jj operation show [OPTIONS] [OPERATION]
Arguments:
  [OPERATION]  Show repository changes in this operation, compared to its parent(s) [default: @]
Options:
  -G, --no-graph
  -T, --template <TEMPLATE>     defaults to `templates.op_show`
  -p, --patch
      --no-op-diff              Do not show operation diff
                                (conflicts with --patch and with all diff-format flags)
```

- Prints the op rendered with `templates.op_show` **then** the op-diff (unless `--no-op-diff`).
- `--no-op-diff` `conflicts_with_all = ["patch", "DiffFormatArgs"]` — you cannot combine
  `--no-op-diff --stat`.
- For a merge op it prints the header and then **nothing** (no diff block, no message).
- Default template `templates.op_show` = `builtin_op_log_compact`, i.e. the same three lines as
  one op-log entry.

### 1.4 `jj op diff`

```
Usage: jj operation diff [OPTIONS]
      --operation <OPERATION>   compared to its parent   [alias: --op]
  -f, --from <FROM>             Show repository changes from this operation
  -t, --to <TO>                 Show repository changes to this operation
  -G, --no-graph
  -p, --patch
```

- `--from` conflicts with `--operation`; `--to` conflicts with `--operation`.
- Defaults (`diff.rs`): if neither `--from` nor `--to` is given, `to_op = --operation (default @)`
  and `from_ops = to_op.parents()`. If either is given, the **missing one defaults to `@`**:
  `from = args.from.unwrap_or("@")`, `to = args.to.unwrap_or("@")`.
- `--from` may resolve to several ops (all parents of a merge), which is why the output prints
  `From operation:` once per parent.
- Header lines are emitted unconditionally, even when the diff is empty.

### 1.5 `jj op restore`

```
Usage: jj operation restore [OPTIONS] <OPERATION>
Arguments:
  <OPERATION>   The operation to restore to
Options:
      --what <WHAT>  What portions of the local state to restore (can be repeated)
                     [default: repo remote-tracking] [possible values: repo, remote-tracking]
```

- Long help: *"This restores the repo to the state at the specified operation, effectively undoing
  all later operations. It does so by creating a new operation."*
- Op description written: `"restore to operation ⟨full 128-hex op id⟩"`.
- **No positional restriction beyond resolvability** — `jj op restore` accepts `@` and even the
  root operation (`jj op restore 000000000000` works, with a warning; see §2.6).
- `--what` is marked **EXPERIMENTAL** in help. Value docs, verbatim:
  - `repo`: "The jj repo state and local bookmarks"
  - `remote-tracking`: "The remote-tracking bookmarks. Do not restore these if you'd like to push after the undo"
- Semantics from `view_with_desired_portions_restored` (`cli/src/commands/operation/mod.rs`):
  `head_ids`, `local_bookmarks`, `local_tags`, `wc_commit_ids` come from the restored view when
  `repo` is included; `remote_views` comes from the restored view when `remote-tracking` is
  included; **`git_refs` and `git_heads` always come from the *current* view** — Git refs are never
  restored by `jj op restore`.
- `wc_commit_ids` being restored is what makes `jj op restore` restore `@` (and then check the
  files out).

### 1.6 `jj op revert`

```
Usage: jj operation revert [OPTIONS] [OPERATION]
Arguments:
  [OPERATION]   The operation to revert [default: @]
Options:
      --what <WHAT>   [default: repo remote-tracking] [possible values: repo, remote-tracking]
```

- Long help: *"This reverts an individual operation by applying the inverse of the operation."*
- Implementation merges `repo_at_target_op` with `repo_at_target_op_parent`, so only that one op's
  effect is inverted; later ops stay.
- Op description written: `"revert operation ⟨full 128-hex op id⟩"`.
- Refuses root and merge ops (see §2.6).
- Reverting may rebase descendants; jj prints `"Rebased ⟨n⟩ descendant commits."` (observed:
  `"Rebased 1 descendant commits."`).

### 1.7 `jj op integrate`

```
Usage: jj operation integrate [OPTIONS] <OPERATION>
Arguments:
  <OPERATION>   The operation to integrate
```

- Long help: *"By default, operations are automatically integrated into the operation log, but
  `--no-integrate-operation` or internal errors may cause that to not happen. This command can then
  be used for making such operations part of the operation log. Running this command on an operation
  that is already in the operation log (`jj op log`) has no effect."*
- Behaviour observed:
  - integrating an op that simply extends the current head → **no output**, exit 0;
  - integrating an op that is a *sibling* head → `"The specified operation has been integrated with other existing operations."`
    and a new merge op appears with description `"reconcile divergent operations"`;
  - re-integrating an already-integrated op → no output, exit 0 (idempotent).
- Only accepts a single operation id/`@`-relative expression, **not** a range.

### 1.8 `jj op abandon`

```
Usage: jj operation abandon [OPTIONS] <OPERATION>
Arguments:
  <OPERATION>   The operation or operation range to abandon
```

Long help, verbatim:

```
To discard old operation history, use `jj op abandon ..<operation ID>`. It will abandon the
specified operation and all its ancestors. The descendants will be reparented onto the root
operation.

To discard recent operations, use `jj op restore <operation ID>` followed by `jj op abandon
<operation ID>..@-`.

Previous versions of a change (or predecessors) are also discarded if they become unreachable from
the operation history. The abandoned operations, commits, and other unreachable objects can later be
garbage collected by using `jj util gc` command.
```

- Accepts either one op (`X`) or a range (`A..B`); an empty side means root / current heads
  (`op_walk`-level split on `".."`). `..X` = root..X.
- Single-op form: the op's parent becomes the new parent of its children.
- **Refuses** the root op, merge ops, and the *current* op (see §2.6).
- Prints `"Abandoned ⟨n⟩ operations and reparented ⟨m⟩ descendant operations."`, or
  `"Nothing changed."` when the range selects nothing.
- Descendants get **new operation ids** (their parent pointers changed). Observed: abandoning
  `@-` turned the then-current op `6d62025ec43d` into `06c79e7377c5`.
- `--at-op` is rejected: `"Error: --at-op is not respected"`.
- Does *not* delete objects; `jj util gc` does that later.

### 1.9 `jj undo`

```
Usage: jj undo [OPTIONS]
Options:
      --allow-cross-workspace   Allow undoing an operation that was performed in another workspace
```

Long help, verbatim (v0.46.0):

```
If used once after a normal (non-`undo`) operation, this will undo that last operation by restoring
its parent. If `jj undo` is used repeatedly, it will restore increasingly older operations, going
further back into the past.

There is also a complementary `jj redo` command that would instead move in the direction of the
future after one or more `jj undo`s.

Use `jj op log` to visualize the log of past operations, including a detailed description of any
past undo/redo operations. See also `jj op restore` to explicitly restore an older operation by its
id (available in the operation log).

By default, `jj undo` refuses to undo an operation that was performed in another workspace, since
that is usually not what you meant to undo. Pass `--allow-cross-workspace` to undo it anyway, or use
`jj op revert` to revert a specific operation.
```

Stack semantics (from the long comment in `cli/src/commands/undo.rs`, worth reproducing in the
tutorial because it is *the* mental model):

- undo a normal op → restore its parent;
- undo an `undo:` op → undo the op that that undo restored *away from* (i.e. keep stepping back);
- "jumping over" old undo-stacks: when the target of the undo is itself an undo-op, jj restores
  **directly** to the original op to avoid building a linked list.

`jj undo` uses `DEFAULT_REVERT_WHAT` = `[repo, remote-tracking]` — it is hard-coded, **not**
configurable, and there is no `--what` flag on `jj undo`.

Op description written: `"undo: restore to operation ⟨full 128-hex id of the restored-to op⟩"`.

Extra warnings (only on specific targets):

| Trigger | Warning | Hint |
| --- | --- | --- |
| target op is a push (`description` starts with `"push "`) | `Undoing a push operation often leads to conflicted bookmarks.` | `To avoid this, run \`jj redo\` now.` |
| target op `description` starts with `"remove workspace"` | `Undoing a workspace removal restores the workspace, but does not restore the workspace directory.` | `Run \`jj workspace forget\` then \`jj workspace add\` to recreate the directory.` |

### 1.10 `jj redo`

```
Usage: jj redo [OPTIONS]
Options:
      --allow-cross-workspace   Allow redoing an undo-operation that was performed in another workspace
```

Long help, verbatim:

```
This is the natural counterpart of `jj undo`. Repeated invocations of `jj undo` and `jj redo` act
similarly to Undo/Redo commands in a text editor.

Use `jj op log` to visualize the log of past operations, including a detailed description of any
past undo/redo operations. See also `jj op restore` to explicitly restore an older operation by its
id (available in the operation log).

By default, `jj redo` refuses to redo an undo-operation that was performed in another workspace,
since that is usually not what you meant to redo. Pass `--allow-cross-workspace` to redo it anyway,
or use `jj op revert` to revert a specific undo operation.
```

Redo direction (derived from `redo.rs` + verified): redo only accepts an `undo:` op as target;
it restores to that undo op's **parent**, i.e. the state that the undo threw away.
`jj redo` when the current op is not an `undo:`/`redo:` op → `Error: Nothing to redo`.

Op description written: `"redo: restore to operation ⟨full 128-hex id⟩"`.
Note asymmetry: `jj undo` prints **two** lines (`Undid operation:` + `Restored to operation:`),
`jj redo` prints **one** (`Restored to operation:`).

### 1.11 Global flags that matter for the op log

| Flag | Exact help text (v0.46.0) | Notes |
| --- | --- | --- |
| `--at-operation <AT_OPERATION>` (alias `--at-op`) | "Operation to load the repo at" | "By default, Jujutsu loads the repo at the most recent operation, or at the merge of the divergent operations if any." … "`--at-op=@` is pretty much the same as the default except that divergent operations will never be merged." … "Any unambiguous prefix of the operation ID is enough." … "When loading the repo at an earlier operation, the working copy will be ignored, as if `--ignore-working-copy` had been specified." … "It is possible to run mutating commands when loading the repo at an earlier operation." |
| `--ignore-working-copy` | "Don't snapshot the working copy, and don't update it" | "Loading the repository at a specific operation with `--at-operation` implies `--ignore-working-copy`." |
| `--no-integrate-operation` | "Run the command as usual but don't integrate any operations" | "The command will print the resulting operation ID. You can pass that to e.g. `jj --at-op` to inspect the resulting repo state, or you can pass it to `jj op restore` to restore the repo to that state. You can also pass the ID to `jj op integrate` to integrate the operation." … "Note that this does *not* prevent side effects outside the repo. For example, `jj git push --no-integrate-operation` will still perform the push." |
| `--ignore-immutable` | "Allow rewriting immutable commits" | unrelated to ops, but appears in every op command's global group |

### 1.12 Operation-set expression syntax (NOT revsets)

`docs/operation-log.md` "Introduction", verbatim:

```
When referring to operations, you can use `@` to represent the current
operation.

The following operators are supported:

* `x-`: Parents of `x` (e.g. `@-`)
* `x+`: Children of `x`
```

Implementation (`lib/src/op_walk.rs::resolve_single_op`): `op_str.trim_end_matches(['-','+'])`
then the remainder must be `@` or a **hex prefix**; the stripped suffix is walked one character at
a time (`-` → parents, `+` → children).

Consequences the tutorial must state explicitly:

- **`@-2` does not work.** `jj op diff --op @-2` → `Error: Operation ID "@-2" is not a valid hexadecimal prefix`.
  Two back is `@--`, four back is `@----`, N back is N literal hyphens.
- Any prefix of the 128-hex operation id is accepted (`jj op show 964ea300f95f`).
- There are **no** symbolic op names: `jj op revert 'root()'` → `Error: Operation ID "root()" is not a valid hexadecimal prefix`.
  The root op is `000000000000…` (128 zeros).
- `x+` resolves children by walking down from the current heads, so it errors when there are
  several children (`Error: The "@-" expression resolved to more than one operation` +
  `Hint: Try specifying one of the operations by ID: ⟨a⟩, ⟨b⟩`) or none
  (`Error: The "@+" expression resolved to no operations`).
- Resolution error strings (`lib/src/op_walk.rs::OpsetResolutionError`):
  - `Operation ID "⟨s⟩" is not a valid hexadecimal prefix`
  - `No operation ID matching "⟨s⟩"`
  - `Operation ID prefix "⟨s⟩" is ambiguous`
  - `The "⟨expr⟩" expression resolved to more than one operation`
  - `The "⟨expr⟩" expression resolved to no operations`

---

## 2. Exact UI strings and default output formats

### 2.1 What `templates.op_log` actually is in 0.46.0

`settings.get_string("templates.op_log")` → `builtin_op_log_compact`. Its definition, from
`jj config list --include-defaults` (ground truth for the shipped defaults):

```toml
templates.op_log = 'builtin_op_log_compact'
templates.op_show = 'builtin_op_log_compact'
templates.op_log_node = '''
if(
  config("ui.graph.style").as_string().starts_with("ascii"),
  builtin_op_log_node_ascii,
  builtin_op_log_node
)
'''

template-aliases.builtin_op_log_compact = 'builtin_op_log_compact(self)'
template-aliases."builtin_op_log_compact(op)" = '''
label(if(op.current_operation(), "current_operation"),
  coalesce(
    if(op.snapshot(), format_snapshot_operation(op)),
    if(op.root(), format_root_operation(op)),
    format_operation(op),
  )
)
'''
template-aliases.builtin_op_log_comfortable = 'builtin_op_log_compact ++ "\n"'
template-aliases.builtin_op_log_oneline = 'builtin_op_log_oneline(self)'
template-aliases.builtin_op_log_redacted = 'builtin_op_log_redacted(self)'

template-aliases."format_operation(op)" = '''
concat(
  separate(" ",
    format_short_operation_id(op.id()),
    op.user(),
    op.workspace_name(),
    format_time_range(op.time()),
  ), "\n",
  op.description().first_line(), "\n",
  surround("", "\n", op.attributes()),
)
'''
template-aliases."format_root_operation(root)" = '''
join(" ", root.id().short(), label("root", "root()")) ++ "\n"
'''
template-aliases."format_short_operation_id(id)" = 'id.short()'
template-aliases."format_time_range(time_range)" = '''
time_range.end().ago() ++ label("time", ", lasted ") ++ time_range.duration()
'''
template-aliases."format_timestamp(timestamp)" = 'timestamp.local().format("%Y-%m-%d %H:%M:%S")'
template-aliases.builtin_op_log_node = '''
coalesce(
  if(current_operation, label("current_operation", "@")),
  "○",
)
'''
template-aliases.builtin_op_log_node_ascii = '''
coalesce(
  if(current_operation, label("current_operation", "@")),
  "o",
)
'''
```

So a single `jj op log` entry is **exactly three physical lines**:

```
⟨node⟩  ⟨12-char op id⟩ ⟨username⟩@⟨hostname⟩ ⟨workspace⟩@ ⟨relative time⟩, lasted ⟨duration⟩
⟨graph gutter⟩⟨description, first line only⟩
⟨graph gutter⟩args: ⟨shell-quoted command line⟩
```

- Line 1 is emitted by `format_operation`; the node glyph + gutter come from the graph renderer.
- Line 2/3 gutter: `│  ` for a mid-history node, `   ` for the last node in the printed range.
- `--no-graph` removes both the node and the gutters, so the entry is still 3 lines but flush-left.
- The `args:` line exists **only when `attributes` is non-empty** (`surround("", "\n", …)`), and the
  only attribute 0.46.0 writes is `args`. Some operations genuinely have no args recorded — e.g.
  `add workspace '⟨name⟩'` (created by a lib-level transaction) prints no third line.
- Root op is special: `"⟨12 zeros⟩ root()"` on one line and nothing else.
- Operation ids are **truncated to 12 hex chars, always** — not "shortest unique".
  `OperationId::short()`'s default length is `12` (`cli/src/operation_templater.rs`), and
  `cli_util::short_operation_hash` is `format!("{operation_id:.12}")`.

### 2.2 Real captured output, default template

Fresh `jj git init` (0.46.0 default is colocated — `git.colocate = true`):

```
@  5aed5795bb14 bogdan@nixos default@ now, lasted 1 millisecond
│  import git head
│  args: jj git init --colocate
○  1a9cb7806bc4 bogdan@nixos default@ now, lasted 1 millisecond
│  import git refs
│  args: jj git init --colocate
○  39b3e7a0a66b bogdan@nixos now, lasted 3 milliseconds
│  add workspace 'default'
○  000000000000 root()
```

Note `add workspace 'default'` has **no workspace field** (op not created from a workspace →
`workspace_name()` returns the empty string) and no `args:` line.

Mixed sample showing all field shapes:

```
@  3ca9af4e554e bogdan@nixos default@ now, lasted 19 milliseconds
│  push bookmark main to git remote origin
│  args: jj '--color=never' git push -b main
○  788ebd66f53e bogdan@nixos default@ now, lasted 3 milliseconds
│  create bookmark main pointing to commit fc7c02fbb11e90e6f761f801aa986e5d7a4352a3
│  args: jj '--color=never' bookmark create main -r @-
○  bf5b6ac2a224 bogdan@nixos ws2@ 2 seconds ago, lasted 1 millisecond
│  create initial working-copy commit in workspace ws2
│  args: jj '--color=never' workspace add ../ws2
○  e5b5fd0dfe8c bogdan@nixos 2 seconds ago, lasted 1 millisecond
│  add workspace 'ws2'
○  f59e73ab9396 bogdan@nixos default@ now, lasted 17 milliseconds
│  fetch from git remote(s) origin
│  args: jj '--color=never' git fetch
```

Time field renderings observed: `now, lasted 3 milliseconds`, `now, lasted 1 millisecond`,
`12 seconds ago, lasted 1 millisecond`, `now, lasted less than a microsecond`.
Duration is jj's humanized duration (`time.duration()`).

### 2.3 Graph glyphs and divergence

- Node glyphs: `@` for the current operation, `○` for all others (curved and square styles are
  identical for the op log); `o` with `ui.graph.style = "ascii"` (and `|` instead of `│`).
- Edges: `│`, `├─╮`, `├───╮`, `├─╯`.
- Graph style comes from `ui.graph.style`; the node template can be overridden with
  `templates.op_log_node` (must be a *template expression*, e.g. `'"*"'`, not a bare string —
  `--config 'templates.op_log_node="• "'` is a `Failed to parse template: Syntax error`).

Divergence capture (two heads merged):

```
@    5cfe49c4c1b7 bogdan@nixos default@ now, lasted less than a microsecond
├─╮  reconcile divergent operations
│ │  args: jj '--color=never' op integrate e96c096a7519
○ │  f8edf3e2cc6c bogdan@nixos default@ 4 seconds ago, lasted 2 milliseconds
│ │  new empty commit
│ │  args: jj '--color=never' --no-integrate-operation new -m detached
│ ○  e96c096a7519 bogdan@nixos default@ 4 seconds ago, lasted 2 milliseconds
├─╯  new empty commit
│    args: jj '--color=never' --no-integrate-operation new -m detached2
```

`--no-graph` flattens this to lines with no edges (children still appear in topological order;
`--reversed` is usually what you want there).

### 2.4 `jj op show` / `jj op log -d` / `jj op log -p`

`jj op show` = op header (3 lines, default `builtin_op_log_compact`) + blank line + diff sections.

```
9c75e786ed16 bogdan@nixos default@ 3 seconds ago, lasted 16 milliseconds
snapshot working copy
args: jj '--color=never' status

Changed commits:
○  + stnlsypr e44404a7 BBB
   - stnlsypr/1 7dd688da (hidden) (empty) BBB

Changed working copy default@:
+ stnlsypr e44404a7 BBB
- stnlsypr/1 7dd688da (hidden) (empty) BBB
```

With `-p` the file diffs are appended under the changed commit inside the "Changed commits" graph
(with `JJ-COMMIT-DESCRIPTION` treated as a pseudo-file when only the description changed):

```
│  Changed commits:
│  ○  + stnlsypr e44404a7 BBB
│     - stnlsypr/1 7dd688da (hidden) (empty) BBB
│     Added regular file snap.txt:
│             1: aaa
│             2: bbb
```

**Section headers** emitted by `show_op_diff` (`cli/src/commands/operation/diff.rs`), in this order:

| Header | When |
| --- | --- |
| `Changed commits:` | any commit added/removed from the visible set |
| `Changed working copy ⟨name⟩@:` | the workspace's `@` moved |
| `Changed local bookmarks:` | local bookmark targets changed (`⟨name⟩:` then `+`/`-` lines) |
| `Changed local tags:` | local tags changed |
| `Changed remote bookmarks:` | remote-tracking bookmarks changed |
| `Changed remote tags:` | remote tags changed |
| `   (Elided ⟨n⟩ revisions)` | elided counts, e.g. `   (Elided 3 newly added and 1 newly removed revisions)`; the ` and ` join means both parts present |

Ref-target summary markers: `+` / `-` prefix, then either a commit summary, or `(absent)`, or
`(added) ⟨summary⟩` / `(removed) ⟨summary⟩` for conflicted targets.

Real captured example (bookmark created):

```
Changed local bookmarks:
bm1:
+ lvrztqkx 2ecc6928 bm1 | (no description set)
- (absent)
```

Elision is controlled by `revsets.op-diff-changes-in` (default `mutable() | immutable_heads()`) or
`--show-changes-in`. If the revset cannot be resolved, `show_op_diff` prints:

```
Warning: Could not resolve revset expression for elision: ⟨err⟩
   (Use --show-changes-in=all() to see all changes)
```

### 2.5 `jj op diff` header formatting

```
From operation: c2d4c94f590c (2026-11-05 14:08:58) rebase commit f38d61a8c9f0c15133e8402cf5d0cec1027db16c
  To operation: 9c75e786ed16 (2026-11-05 14:09:08) snapshot working copy
```

Exact literals: `"From operation: "` and `"  To operation: "` (**two** leading spaces).
Both formatted with `templates.op_summary`, whose 0.46.0 default is:

```toml
templates.op_summary = '''
separate(" ",
  self.id().short(),
  if(root,
    label("root", "root()"),
    surround("(", ")", format_timestamp(self.time().end())),
  ),
  self.description().first_line(),
)
'''
```

Note: `op_summary` prints the absolute local timestamp `%Y-%m-%d %H:%M:%S`
(`format_timestamp` default), **not** the relative `… ago, lasted …` used by `op_log`.

### 2.6 Messages printed by the mutating commands

`jj undo`:

```
Undid operation: ⟨12-hex⟩ (⟨%Y-%m-%d %H:%M:%S⟩) ⟨description first line⟩
Restored to operation: ⟨12-hex⟩ (⟨%Y-%m-%d %H:%M:%S⟩) ⟨description first line⟩
```

`jj redo`:

```
Restored to operation: ⟨12-hex⟩ (⟨%Y-%m-%d %H:%M:%S⟩) ⟨description first line⟩
```

`jj op restore`:

```
Restored to operation: ⟨12-hex⟩ (⟨%Y-%m-%d %H:%M:%S⟩) ⟨description first line⟩
```
(plus the usual working-copy update lines: `Working copy  (@) now at: …`,
`Parent commit (@-)      : …`, `Added 2 files, modified 0 files, removed 1 files`)

`jj op revert`:

```
Reverted operation: ⟨12-hex⟩ (⟨%Y-%m-%d %H:%M:%S⟩) ⟨description first line⟩
```

`jj op abandon`:

```
Abandoned 1 operations and reparented 1 descendant operations.
Nothing changed.
```

`jj op integrate`:

```
The specified operation has been integrated with other existing operations.
```

`--no-integrate-operation`:

```
Operation left uncommitted because --no-integrate-operation was requested: ⟨12-hex⟩
```

`jj util snapshot`:

```
No snapshot needed.
Snapshot complete.
```

Divergent heads found on normal load:

```
Concurrent modification detected, resolving automatically.
```

`jj op restore` to an op predating the workspace:

```
Warning: The current workspace 'default' no longer exists after this operation. The working copy was left untouched.
Hint: Restore to an operation that contains the workspace (e.g. `jj undo` or `jj redo`).
```

Prefix convention: when stderr is not a terminal jj prefixes warnings with `"Warning: "` and hints
with `"Hint: "`; the underlying message bodies are the strings quoted above without those prefixes.

### 2.7 Error strings (all verified with the 0.46.0 binary)

| Command | Condition | Exact message (+ hint) |
| --- | --- | --- |
| `jj op abandon` | target is root | `Error: Cannot abandon the root operation` |
| `jj op abandon` | target is a merge | `Error: Cannot abandon a merge operation` |
| `jj op abandon` | target is the current op | `Error: Cannot abandon the current operation ⟨12-hex⟩` + `Hint: Run \`jj undo\` to revert the current operation, then use \`jj op abandon\`` |
| `jj op abandon` | with `--at-op` | `Error: --at-op is not respected` |
| `jj op revert` | target is root | `Error: Cannot revert root operation` |
| `jj op revert` | target is a merge | `Error: Cannot revert a merge operation` |
| `jj undo` | current op is root | `Error: Cannot undo root operation` |
| `jj undo` | current op is a merge | `Error: Cannot undo a merge operation` + `Hint: Consider using \`jj op restore\` instead` |
| `jj undo` | op from another workspace | `Error: Refusing to undo operation ⟨12-hex⟩ because it was performed in workspace ⟨name⟩` + `Hint: Use \`--allow-cross-workspace\` to undo it anyway, or use \`jj op revert\` to revert a specific operation` |
| `jj redo` | nothing to redo | `Error: Nothing to redo` |
| `jj redo` | undo op from another workspace | `Error: Refusing to redo operation ⟨12-hex⟩ because it was performed in workspace ⟨name⟩` + `Hint: Use \`--allow-cross-workspace\` to redo it anyway, or use \`jj op revert\` to revert a specific undo operation` |
| any op arg | bad hex | `Error: Operation ID "⟨s⟩" is not a valid hexadecimal prefix` |
| any op arg | unknown | `Error: No operation ID matching "⟨s⟩"` |
| any op arg | ambiguous | `Error: Operation ID prefix "⟨s⟩" is ambiguous` |
| any op arg (`@±`) | fan-out | `Error: The "⟨sub-expr⟩" expression resolved to more than one operation` + `Hint: Try specifying one of the operations by ID: ⟨a⟩, ⟨b⟩` |
| any op arg (`@+`) | no child | `Error: The "@+" expression resolved to no operations` |

The 0.46.0 CHANGELOG "Breaking changes" confirms the cross-workspace refusal is new in this release:
*"`jj undo` and `jj redo` now refuse to undo/redo an operation that was performed in another
workspace. Use `--allow-cross-workspace` to undo/redo it anyway."*

### 2.8 Operation-description catalogue (strings the tutorial should show)

Every description is `format!`-built in `cli/src`. Verified where marked ✔ (produced by the binary).

| Command / trigger | Description written |
| --- | --- |
| snapshot of the working copy | `snapshot working copy` ✔ |
| `jj new` | `new empty commit` ✔ |
| `jj describe` (1 commit) | `describe commit ⟨40-hex commit id⟩` ✔ |
| `jj describe` (n>1) | `describe commit ⟨hex⟩ and ⟨n-1⟩ more` |
| `jj commit` | `commit ⟨40-hex⟩` |
| `jj squash` | `squash commits into ⟨40-hex of destination⟩` ✔ |
| `jj rebase -r X` | `rebase commit ⟨hex⟩` ✔ |
| `jj rebase -r X -r Y …` | `rebase commit ⟨hex⟩ and ⟨n⟩ more` |
| `jj rebase -s/-b X` | `rebase commit ⟨hex⟩ and descendants` |
| `jj rebase -s/-b` (n>1) | `rebase ⟨n⟩ commits and their descendants` |
| `jj abandon` | `abandon commit ⟨hex⟩` / `abandon commit ⟨hex⟩ and ⟨n⟩ more` |
| `jj bookmark create` | `create bookmark ⟨names⟩ pointing to commit ⟨hex⟩` ✔ |
| `jj bookmark set` / `move` / `advance` | `point bookmark ⟨names⟩ to commit ⟨hex⟩` |
| `jj bookmark delete` | `delete bookmark ⟨names⟩` |
| `jj bookmark forget` | `forget bookmark ⟨names⟩` |
| `jj bookmark rename` | `rename bookmark ⟨old⟩ to ⟨new⟩` |
| `jj bookmark track` / `untrack` | `track remote bookmark ⟨names⟩` / `untrack remote bookmark ⟨names⟩` |
| `jj tag set`/`delete`/`track`/`untrack` | analogous `… tag …` strings |
| `jj file track` / `untrack` | `track paths` ✔ / `untrack paths` |
| `jj file chmod` | `chmod ⟨…⟩ in commit ⟨hex⟩`-style (format string in `file/chmod.rs`) |
| `jj file delete` | `delete paths in commit ⟨hex⟩` |
| `jj file edit` | `edit paths in commit ⟨hex⟩`-style (`file/edit.rs`) |
| `jj split` | `split commit ⟨hex⟩` |
| `jj duplicate` | `duplicate ⟨n⟩ commit(s)` |
| `jj edit` / `jj diffedit` / `jj metaedit` | `edit commit ⟨hex⟩` / `edit commit ⟨hex⟩` / `edit commit metadata for commit ⟨hex⟩` |
| `jj absorb` | `absorb changes into ⟨n⟩ commits` |
| `jj fix` | `fixed ⟨n⟩ commits` |
| `jj resolve` | `Resolve conflicts in commit ⟨hex⟩` (capital R) |
| `jj restore` (file restore) | `restore into commit ⟨hex⟩` |
| `jj simplify-parents` | `simplify ⟨n⟩ commits` |
| `jj parallelize` | `parallelize ⟨n⟩ commits` |
| `jj arrange` | `arrange revisions` |
| `jj run` | `run: rewrite ⟨n⟩ commits` / `run: nothing changed` |
| `jj bisect run` | `Updated to revision ⟨hex⟩ for bisection` |
| `jj workspace add` (repo-level op) | `add workspace '⟨name⟩'` ✔ |
| `jj workspace add` (WC op) | `create initial working-copy commit in workspace ⟨name⟩` ✔ |
| `jj workspace forget` | `forget workspace ⟨name⟩` / `forget workspaces ⟨a, b⟩` ✔ |
| `jj workspace remove` | `remove workspace ⟨name⟩` / `remove workspaces ⟨a, b⟩` ✔ |
| `jj git init` (colocated) | `import git refs` ✔, `import git head` ✔ |
| `jj git import` | `import git refs` |
| `jj git export` | `export git refs` |
| `jj git fetch` | `fetch from git remote(s) ⟨remotes⟩` ✔ (`fetch from git remote(s) origin`) |
| `jj git clone` (empty repo) | `fetch from git remote into empty repo` |
| `jj git clone` (checkout) | `check out git remote's branch: ⟨name⟩` |
| `jj git push -b X` | `push ⟨names⟩ to git remote ⟨remote⟩` ✔ (`push bookmark main to git remote origin`) |
| `jj git push --all` | `push all bookmarks/tags to ⟨remotes⟩` |
| `jj git push --tracked` | `push all tracked bookmarks/tags to ⟨remotes⟩` |
| `jj git push --deleted` | `push all deleted bookmarks/tags to ⟨remotes⟩` |
| multiple remotes | `… to git remotes ⟨a, b⟩` |
| `jj git remote add/remove/rename` | `add git remote ⟨name⟩` / `remove git remote ⟨name⟩` / `rename git remote ⟨old⟩ to ⟨new⟩` |
| `jj git colocation enable/disable` | `set git head to working copy parent` / `remove git head reference` |
| `jj undo` | `undo: restore to operation ⟨128-hex⟩` ✔ |
| `jj redo` | `redo: restore to operation ⟨128-hex⟩` ✔ |
| `jj op restore` | `restore to operation ⟨128-hex⟩` ✔ |
| `jj op revert` | `revert operation ⟨128-hex⟩` ✔ |
| divergent-heads merge | `reconcile divergent operations` ✔ |

Note that `undo:`/`redo:`/`restore to operation`/`revert operation` descriptions embed the **full
128-hex** id, which is why those op-log lines are extremely long (and why `op_summary` still shows
only the first line).

---

## 3. Config knobs

All keys below were verified to exist in **0.46.0** via `jj config list --include-defaults` and/or
`cli/src/config-schema.json` at tag `v0.46.0`, and/or `cli/src/config/misc.toml`.

### 3.1 `operation.*` — op metadata

| Key | Default | Source |
| --- | --- | --- |
| `operation.username` | from OS user (`bogdan` here) | `config-schema.json` `properties.operation.properties` |
| `operation.hostname` | from OS hostname (`nixos` here) | same |

These two are the only keys in the `operation` section. Schema has **no description** for either.
The only prose in `docs/config.md` is the env-var table ("Environment variable overrides"):
`$JJ_OP_HOSTNAME` → `operation.hostname`, `$JJ_OP_USERNAME` → `operation.username`.
They feed `Operation.user()`, i.e. the `⟨username⟩@⟨hostname⟩` column of `jj op log`.

### 3.2 `templates.*` — op rendering

| Key | Default in 0.46.0 | Doc |
| --- | --- | --- |
| `templates.op_log` | `builtin_op_log_compact` | schema: "`jj op log`'s output"; `docs/config.md` "### Default Template" |
| `templates.op_show` | `builtin_op_log_compact` | schema: "`jj op show`'s output" |
| `templates.op_summary` | the multi-line block quoted in §2.5 | schema: "The operation summary used by many commands"; used by `jj op diff` headers and the `undo`/`redo`/`restore`/`revert` status lines |
| `templates.op_log_node` | the `if(config("ui.graph.style")…)` block in §2.1 | `docs/config.md` "#### Node style", and its example `op_log_node = 'if(current_operation, "@", "○")'` — **not** present in `config-schema.json` (schema gap) |

Built-in alternates you can assign to `templates.op_log`: `builtin_op_log_compact`,
`builtin_op_log_comfortable`, `builtin_op_log_oneline`, `builtin_op_log_redacted`
(verified: `--config 'templates.op_log="builtin_op_log_oneline"'` works, as does passing the alias
name directly to `-T`).

`builtin_op_log_redacted` output (privacy-preserving demo, real capture):

```
@  212219d9a15a user-64dc workspace-ab88@ 5 seconds ago, lasted 4 milliseconds
│  snapshot working copy
│  (redacted)
```

Operation ids can be shortened/extended by redefining the alias
`'format_short_operation_id(id)'` — `docs/config.md` shows `'format_short_operation_id(id)' = 'id.short(12)'`.

### 3.3 `revsets.op-diff-changes-in` — op-diff elision

- Default (0.46.0): `"mutable() | immutable_heads()"`.
- `docs/config.md` "### Default revisions for operation diffs": *"You can configure the set of
  revisions that are considered "interesting" when showing the difference between two operations
  (e.g. in `jj op show`, `jj op diff`, or `jj op log -p`). Revisions that are not in this set are
  elided into a summary count."*
- Overridable per-invocation with `--show-changes-in <REVSETS>` (exists on `op log`, `op show`,
  `op diff`).
- Read via `settings.get("revsets.op-diff-changes-in")` in `parse_op_diff_changes_in`
  (so it is real), but it is **missing from `config-schema.json`'s `revsets` properties** — schema gap.

### 3.4 `snapshot.*` — what the "snapshot working copy" op captures

| Key | Default | Notes |
| --- | --- | --- |
| `snapshot.auto-track` | `"all()"` (fileset) | schema: "Fileset pattern describing what new files to automatically track on snapshotting. By default all new files are tracked." Set to `"none()"` to stop auto-tracking new files; then use `jj file track`. |
| `snapshot.auto-update-stale` | `false` | schema: "Whether to automatically update the working copy if it is stale." `docs/config.md` "### Automatic update of stale working copies" |
| `snapshot.max-new-file-size` | `"1MiB"` | files above this are silently not snapshotted; `0` disables the limit |

`docs/config.md` "## Snapshot settings" covers all three. Relevant op-log consequence: an
untracked/oversized file produces **no** operation, and `jj util snapshot` reports
`No snapshot needed.`

### 3.5 `git.*` — and the absent `git.auto-import`

**0.46.0 has no `git.auto-import` / `git.auto-local-bookmark`.** They are gone:

- `jj config list --include-defaults | grep auto-import` → no match;
- `git grep -i "auto.import" v0.46.0 -- cli/src docs` → no match (only `emacs auto-import`-style
  unrelated hits);
- the `git` schema section in `cli/src/config-schema.json` at v0.46.0 contains exactly:
  `abandon-unreachable-commits`, `fetch`, `private-commits`, `push`, `record-synthetic-predecessors`,
  `sign-on-push`, `track-default-bookmark-on-clone`, `write-change-id-header`, `executable-path`,
  `colocate`, `object-hash`.

There is therefore **no way in 0.46.0 to disable automatic Git-ref import on every command**; the
`import git refs` operation will appear whenever the underlying Git repo changed. Defaults observed:
`git.abandon-unreachable-commits = true`, `git.colocate = true`,
`git.record-synthetic-predecessors = true`, `git.write-change-id-header = true`,
`git.object-hash = "sha1"`, `git.private-commits = "none()"`, `git.sign-on-push = false`,
`git.track-default-bookmark-on-clone = true`.

### 3.6 `ui.*` — display

| Key | Default | Effect on op log |
| --- | --- | --- |
| `ui.graph.style` | `"curved"` | `curved`/`square` → `○`; `ascii`/`ascii-large` → `o` and `\|` edges (via `templates.op_log_node`) |
| `ui.log-word-wrap` | `false` | `docs/config.md` "### Wrap log content": *"If enabled, `log`/`evolog`/`op log` content will be wrapped based on the terminal width."* |
| `ui.log-synthetic-elided-nodes` | `true` | commit-log only |
| `ui.paginate` / `ui.pager.command` | `"auto"` / `["less","-FRXK"]` | `jj op log` calls `ui.request_pager()` |
| `ui.color` | `"auto"` | |
| `ui.quiet` | `false` | silences the status lines (`Restored to operation:` etc.) |

Colour labels for the op log (`cli/src/config/colors.toml` @ v0.46.0):

```
"operation id" = "blue"
"operation user" = "yellow"
"operation time" = "cyan"
"operation attributes" = "magenta"
"operation current_operation" = { bold = true }
"operation current_operation id" = "bright blue"
"operation current_operation user" = "yellow"
"operation current_operation time" = "bright cyan"
"operation current_operation attributes" = "bright magenta"
"node current_operation" = { fg = "green", bold = true }
"node elided" = { fg = "bright black" }
```

`docs/templates.md` "## Color labels" explains the automatic labels: `jj op log -T 'self.id().short()'`
is labeled `op_log operation id short`, and `--color=debug` reveals the actual labels.

### 3.7 Not configurable

- There is **no** config key for `jj op log`'s default `--limit` (unlimited), for the 12-char id
  length of the `op log` column (only `format_short_operation_id` alias), or for `undo`'s `--what`.
- `jj undo`/`jj redo` take `DEFAULT_REVERT_WHAT` from a compile-time constant, so
  `--what=repo,remote-tracking` cannot be changed by config.

---

## 4. Operation template keywords

From `docs/templates.md` @ v0.46.0, section "### `Operation` type":

```
_Conversion: `Boolean`: no, `Serialize`: yes, `Template`: no_

This type cannot be printed. The following methods are defined.

* `.current_operation() -> Boolean`
* `.description() -> String`
* `.id() -> OperationId`
* `.attributes() -> String`
* `.time() -> TimestampRange`
* `.user() -> String`
* `.snapshot() -> Boolean`: True if the operation is a snapshot operation.
* `.workspace_name() -> String`: The name of the workspace the operation was
  created from. An empty string if the operation wasn't created from a
  workspace.
* `.root() -> Boolean`: True if the operation is the root operation.
* `.parents() -> List<Operation>`
```

"## Keywords" adds: *"In `jj op log`, `self` is the `Operation` type, so `current_operation` is
equivalent to `self.current_operation()`."* So all ten 0-argument methods are usable as bare
keywords — but a bare keyword only, **not** as a function call:
`snapshot()` → `Error: Failed to parse template: Function \`snapshot\` doesn't exist`.

Documented return-type details (`docs/templates.md`):

- `### `OperationId` type` — `_Conversion: Boolean: no, Serialize: yes, Template: yes_`;
  `.short([len: Integer]) -> String`. Operations' ids are 64 bytes → 128 hex chars; `.short()`
  defaults to **12** characters and truncates unconditionally (no uniqueness logic).
- `### `TimestampRange` type` — `.start() -> Timestamp`, `.end() -> Timestamp`,
  `.duration() -> String` (humanized, e.g. `2 milliseconds`, and `less than a microsecond`).
- `### `Timestamp` type` — `.ago()`, `.format(strftime)`, `.utc()`, `.local()`, `.after(date)`,
  `.before(date)`, `.since(start) -> TimestampRange`.
- `OperationId` is `Template: yes`, so `id` prints the full 128 hex; `Operation` is `Template: no`,
  so `-T '… ++ self ++ …'` fails.

Values not explicit in the docs but verified with the binary:

| Keyword | Real value |
| --- | --- |
| `user` | `"⟨username⟩@⟨hostname⟩"` — e.g. `bogdan@nixos`. Built as `format!("{}@{}", username, hostname)` (`cli/src/operation_templater.rs`). |
| `workspace_name` | `"⟨name⟩@"` — **includes a trailing `@`** — or `""` when the op was not created from a workspace. Code: `.map(|name| format!("{}@", name.as_symbol())).unwrap_or_default()`. |
| `attributes` | `"key: value"` pairs joined by `\n`. Only key in 0.46.0 is `args` (the shell-quoted command line). |
| `id` | full 128 hex chars |
| `parents` | `List<Operation>` — its length reveals merge (divergent) ops |

**Deprecated alias:** `operation.tags()` still exists but emits a warning:
`operation.tags() is deprecated; use .attributes() instead`, with a source `TODO: Remove in jj 0.47+`.
It is not documented in `docs/templates.md`. Do not teach it.

`json(self)` works on an operation (`Serialize: yes`), which is useful for scripting. Real capture:

```
{"id":"5a10272342467b7107356bb347164276c25f15928d15273153af283d9a944fcd2129435501203cf0e2e115a1f1d2ddfc03cf2827ae6bcd77a67c7f14ddc00ed8","parents":["dbca849883a6…"],"time":{"start":"2026-11-05T14:12:20.497+01:00","end":"2026-11-05T14:12:20.499+01:00"},"description":"undo: restore to operation 21163d9f…","hostname":"nixos","username":"bogdan","is_snapshot":false,"workspace_name":"default","attributes":{"args":"jj '--color=never' undo"}}
```

Note `workspace_name` is `"default"` in JSON (no trailing `@`) and `is_snapshot` is the serialized
name of `snapshot()`.

### 4.1 Useful example templates

**(a) Compact one-liner with relative time — good default for teaching**

```sh
jj op log -T 'id.short() ++ " " ++ time.end().ago() ++ "  " ++ workspace_name ++ " " ++ description.first_line() ++ "\n"'
```
(drop `--no-graph` if you want the `@`/`○` node; you cannot get the node glyph from `-T`
alone — that comes from `templates.op_log_node`.)

**(b) Machine-readable / greppable**

```sh
jj op log --no-graph -T 'id ++ "\t" ++ time.end().format("%Y-%m-%dT%H:%M:%S") ++ "\t" ++ workspace_name ++ "\t" ++ description.first_line() ++ "\n"'
```

**(c) Flag suspicious history — divergent ops, cross-workspace ops, legacy tag-style attributes**

```sh
jj op log --no-graph -T 'if(parents.len() > 1, "MERGE ", "") ++ id.short() ++ " " ++ workspace_name ++ " " ++ description.first_line() ++ "\n"'
```

**(d) Rewrite the `@` marker** (`docs/config.md` "#### Node style" example, verbatim):

```toml
[templates]
op_log_node = 'if(current_operation, "@", "○")'
```

**(e) Show the raw `args:` attribute inline**

```sh
jj op log --no-graph -T 'id.short() ++ " " ++ description.first_line() ++ if(attributes, "  ⟨" ++ attributes ++ "⟩", "") ++ "\n"'
```

---

## 5. Key doc quotes

### 5.1 `docs/operation-log.md` (the whole file is 65 lines — quote it liberally)

> **# Operation log**
>
> **## Introduction**
>
> Jujutsu records each operation that modifies the repo in the "operation log".
> You can see the log with `jj op log`. Each operation object contains a snapshot
> of how the repo looked at the end of the operation. We call this snapshot a
> "view" object. The view contains information about where each bookmark, tag, and
> Git ref (in Git-backed repos) pointed, as well as the set of heads in the repo,
> and the current working-copy commit in each workspace. The operation object also
> (in addition to the view) contains pointers to the operation(s) immediately
> before it, as well as metadata about the operation, such as timestamps,
> username, hostname, description.
>
> The operation log allows you to undo operations one-by-one (`jj undo`) or even
> revert a specific one which isn't the most recent operation (`jj op revert`). It
> also lets you restore the entire repo to the way it looked at an earlier point
> (`jj op restore`).
>
> When referring to operations, you can use `@` to represent the current
> operation.
>
> The following operators are supported:
>
> * `x-`: Parents of `x` (e.g. `@-`)
> * `x+`: Children of `x`
>
> **## Divergent operations**
>
> One benefit of the operation log (and the reason for its creation) is that it
> allows lock-free concurrency -- you can run concurrent `jj` commands without
> corrupting the repo, even if you run the commands on different machines that
> access the repo via a distributed file system (as long as the file system
> guarantees that a write is only visible once previous writes are visible). When
> you run a `jj` command, it will start by loading the repo at the latest
> operation. It will not see any changes written by concurrent commands. If there
> are conflicts, you will be informed of them by subsequent `jj st` and/or
> `jj log` commands.
>
> As an example, let's say you had started editing the description of a change and
> then also update the contents of the change (maybe because you had forgotten the
> editor). When you eventually close your editor, the command will succeed and
> e.g. `jj log` will indicate that the change has diverged.
>
> **## Loading an old version of the repo**
>
> The top-level `--at-op`/`--at-operation` option allows you to load the repo at a
> specific operation. This can be useful for understanding how your repo got into
> the current state. It can be even more useful for understanding why someone
> else's repo got into its current state.
>
> When you use `--at-op`, the automatic snapshotting of the working copy will not
> take place. When referring to a revision with the `@` symbol (as many commands
> do by default), that will resolve to the working-copy commit recorded in the
> operation's view (which is actually how it always works -- it's just the
> snapshotting that's skipped with `--at-op`).
>
> As a top-level option, `--at-op` can be passed to any command. However, you
> will typically only want to run read-only commands. For example, `jj log`,
> `jj st`, and `jj diff` all make sense. It's still possible to run e.g.
> `jj --at-op=<some operation ID> describe`. That's equivalent to having started
> `jj describe` back when the specified operation was the most recent operation
> and then let it run until now (which can be done for that particular command by
> not closing the editor). There's practically no good reason to do that other
> than to simulate concurrent commands.

### 5.2 `docs/technical/concurrency.md` — "## Operation log"

> The most important piece in the lock-free design is the "operation log". That is
> what allows us to detect and merge divergent operations.
>
> The operation log is similar to a commit DAG (such as in Git's object model),
> but each commit object is instead an "operation" and each tree object is instead
> a "view". The view object contains the set of visible head commits, bookmarks,
> tags, and the working-copy commit in each workspace. The operation object
> contains a pointer to the view object (like how commit objects point to tree
> objects), pointers to parent operation(s) (like how commit objects point to
> parent commit(s)), and metadata about the operation. These types are defined
> in `op_store.proto` The operation log is normally linear.
> It becomes non-linear if there are divergent operations.
>
> When a command starts, it loads the repo at the latest operation. Because the
> associated view object completely defines the repo state, the running command
> will not see any changes made by other processes thereafter. When the operation
> completes, it is written with the start operation as parent. The operation
> cannot fail to commit (except for disk failures and such). It is left for the
> next command to notice if there were divergent operations. […]
>
> It is possible to load the repo at a particular operation with
> `jj --at-operation=<operation ID> <command>`. If the command is mutational, that
> will result in a fork in the operation log. That works exactly the same as if
> any later operations had not existed when the command started. In other words,
> running commands on a repo loaded at an earlier operation works the same way as
> if the operations had been concurrent. This can be useful for simulating
> divergent operations.

### 5.3 `docs/technical/concurrency.md` — "### Merging divergent operations" and "### Storage"

> If Jujutsu tries to load the repo and finds multiple heads in the operation log,
> it will do a 3-way merge of the view objects based on their common ancestor
> (possibly several 3-way merges if there were more than two heads). Conflicts
> are recorded in the resulting view object. For example, if bookmark `main` was
> moved from commit A to commit B in one operation and moved to commit C in a
> concurrent operation, then `main` will be recorded as "moved from A to B or C".
> See the `RefTarget` definition in `op_store.proto`.
>
> Because we allow bookmarks (etc.) to be in a conflicted state rather than just
> erroring out when there are multiple heads, the user can continue to use the
> repo, including performing further operations on the repo. […] `jj new main`
> when `main` is in a conflicted state will result in an error telling you that
> `main` resolved to multiple revisions.
>
> **### Storage**
>
> The operation objects and view objects are stored in content-addressed storage
> just like Git commits are. That makes them safe to write without locking.
>
> We also need a way of finding the current head of the operation log. We do that
> by keeping the ID of the current head(s) as a file in a directory. The ID is the
> name of the file; it has no contents. When an operation completes, we add a file
> pointing to the new operation and then remove the file pointing to the old
> operation. Writing the new file is what makes the operation visible (if the old
> file didn't get properly deleted, then future readers will take care of that).
> This scheme ensures that transactions are atomic.

Verified on disk: `.jj/repo/op_heads/heads/<128-hex>` (one zero-byte file per live head — two files
during divergence), `.jj/repo/op_store/operations/<128-hex>` and
`.jj/repo/op_store/views/<128-hex>` (content-addressed; identical views dedupe — 15 ops shared 6
views in one test repo).

### 5.4 `docs/technical/architecture.md` — "### Transaction" and "### GitBackend"

> The `Transaction` object has a `MutableRepo` and metadata that will go into the
> operation log. When the transaction commits, the `MutableRepo` becomes a view
> object in the operation log on disk, and the `Transaction` object becomes an
> operation object.

> To prevent GC from deleting commits that are still reachable from the operation
> log, the `GitBackend` stores a ref for each commit in the operation log in
> the `refs/jj/keep/` namespace.

### 5.5 `docs/working-copy.md` — "## Stale working copy" (the three-step model)

> Almost all commands go through three main steps:
>
> 1. Snapshot the working copy (which gets recorded as an operation)
> 2. Create new commits etc. "in memory" and record that as a new operation
> 3. Update the working copy to match the new operation, i.e. to the commit that
>    the operation says that `@` should point to
>
> If step 3 doesn't happen for some reason, the working copy is considered
> "stale". We can detect that because the working copy (`.jj/working_copy/`)
> keeps track of which operation it was last updated to. When the working copy is
> stale, use `jj workspace update-stale` to update the files in the working copy.
>
> A common reason that step 3 doesn't happen for a working copy is that you
> rewrote the commit from another workspace. When you modify workspace A's
> working-copy commit from workspace B, workspace A's working copy will become
> stale.

### 5.6 `docs/git-comparison.md`, `docs/git-experts.md`, `README.md`

> **The operation log replaces reflogs.** The operation log is similar to
> reflogs, but is much more powerful. It keeps track of atomic updates to all
> refs at once (Jujutsu thus improves on Git's per-ref history much in the same
> way that Subversion improved on RCS's per-file history). The operation log
> powers e.g. the undo functionality.
> — `docs/git-comparison.md`, "## The index"/reflog bullet list

> ## Undo is more powerful than using the reflog
>
> Git's reflog is powerful, but it's per-ref and can be awkward to use when
> multiple refs and operations are involved.
>
> Jujutsu's operation log records the state of the entire repository: Every change
> is an operation you can inspect, and you can restore to any earlier state with
> one command.
>
> Common uses of the operation log:
>
> - `jj undo` reverts the last operation in one step, without needing to figure
>   out which ref to reset. You can repeat `jj undo` to continue stepping backwards
>   in time.
>
> - `jj op log -p` shows operations with diffs so you can inspect what happened.
>
> - `--at-operation ID` lets you run commands as if the repository were in a
>   previous state.
> — `docs/git-experts.md`

> - **Operation log & undo**: Jujutsu records every operation that is performed on the
>   repository, from commits, to pulls, to pushes. This makes debugging problems like
>   "what just happened?" or "how did I end up here?" easier, *especially* when
>   you're helping your coworker answer those questions about their repository!
>   And because everything is recorded, you can undo that mistake you just made
>   with ease. Version control has finally entered [the 1960s][undo-history]!
> — `README.md`

### 5.7 `docs/sapling-comparison.md` — why snapshotting makes undo cover the working copy

> * **Undo:** jj's undo is powered by the operation log, which records how the repo
>   has changed over time. […] Thanks to jj snapshotting the working
>   copy, it's possible to undo changes to the working copy. For example, if
>   you `jj undo` a `jj commit`, `jj diff` will show the same changes as
>   before `jj commit`, but if you `sl undo` a `sl commit`, the working copy will
>   be clean.

### 5.8 `docs/glossary.md`

> **## Operation**
>
> A snapshot of the visible commits and bookmarks at a given point in time
> (technically a view object), together with some metadata. The metadata includes
> the username, hostname, timestamps, and pointers to the operation's parents.
>
> **## Operation log**
>
> The operation log is the DAG formed by operation objects, much in the same way
> that commits form a DAG, which is sometimes called the "commit history". When
> operations happen in sequence, they form a single line in the graph. Operations
> that happen concurrently from jj's perspective result in forks and merges in
> the DAG.

### 5.9 `docs/FAQ.md` — monitoring and manual snapshots

> ### Can I monitor how `jj log` evolves?
>
> […] `watch --color jj --ignore-working-copy log --color=always` […] The
> `--ignore-working-copy` option avoids conflicts with manual operations during the
> creation of snapshots.
>
> […] `watchexec --quiet --clear --restart --watch=.jj/repo/op_heads/heads --ignore-nothing --wrap-process=none -- jj --ignore-working-copy log`

(The `--watch=.jj/repo/op_heads/heads` path is a documented, stable-ish hook — great tutorial demo.)

> ### How can I manually trigger (e.g., periodic) snapshots?
>
> Most `jj` commands will automatically snapshot the working copy at the start of
> the command if needed. […] you can run `jj util snapshot`. By default this
> command will print whether a snapshot was taken, which you can silence with the
> global `--quiet` flag. […]
>
> If you want to see the ID of the current operation after this command, it would
> be simpler to run `jj operation log --limit 1` directly, since that command also
> takes a snapshot if needed.

### 5.10 `jj util snapshot --help` — the canonical "sandwich" recipe

> ### Example of programmatic snapshotting
>
> Consider the following:
>
> ```bash
> $ echo content > new-file.txt
> # At this point, `jj` does not know about `new-file.txt`.
> $ ./my-script-that-runs-jj-commands
> # Since the script ran `jj` commands, the changes to `new-file.txt` have
> # been snapshotted in an operation, which you can see with:
> $ jj operation log --patch
> ```
>
> If `my-script-that-runs-jj-commands` has a "sandwich" of `jj util snapshot`
> at the beginning and end of the script, then the operation that captures
> `new-file.txt` will be distinct from the operations created by the `jj`
> commands in that script. […] without `jj util snapshot`, these operations
> will be mixed together in the operation log.

---

## 6. Gaps, uncertainties, and things the tutorial must say carefully

1. **There is no doc page called `docs/technical/operations.md` or `transactions.md`.**
   `docs/technical/` at v0.46.0 contains exactly: `architecture.md`, `concurrency.md`,
   `conflicts.md`, `revset-evaluation.md`, `types.svg`. Operation/transaction internals live in
   `concurrency.md` (op log, divergence, storage) and `architecture.md` (`### Transaction`,
   `### ReadonlyRepo`). `docs/design/jj-converge-command.md` discusses the op log in passing.

2. **`docs/config.md` has no "operation log" section.** The `operation.*` keys are documented only
   as environment-variable overrides (`$JJ_OP_HOSTNAME`, `$JJ_OP_USERNAME`) and have empty schema
   descriptions. `templates.op_log_node` is documented in prose but absent from `config-schema.json`.
   `revsets.op-diff-changes-in` is documented in prose and read by the code but also absent from
   the schema. Treat `jj config list --include-defaults` as the authoritative key list.

3. **No "almost nothing is destructive" sentence exists in the v0.46.0 docs.** The closest
   documented safety claims are:
   - `docs/technical/concurrency.md` §"Syncing with rsync, NFS, Dropbox, etc": *"no changes to the
     repo will be lost (added commits, moved bookmarks, etc.)"*;
   - `README.md` "Operation log & undo": *"because everything is recorded, you can undo that mistake
     you just made with ease"*;
   - `docs/git-experts.md`: *"you can restore to any earlier state with one command"*.
   There is also a documented **corruption** caveat right next to the "nothing is lost" text:
   *"with the Git backend, repository corruption is possible because the backend is not entirely
   lock-free … there is an easy recovery path: `jj debug reindex`"*.

4. **`jj op restore` snapshot-then-restore is not documented anywhere.** Verified empirically:
   `jj op restore` snapshots the working copy first, so *uncommitted* work becomes a
   `snapshot working copy` operation **before** the restore op is written — i.e. it stays in the op
   log and is recoverable with `jj op restore <that snapshot op>`. The tutorial should demonstrate
   this, since it is the strongest practical safety statement available.

5. **`jj op restore` does *not* restore Git refs.** `view_with_desired_portions_restored` copies
   `git_refs`/`git_heads` from the *current* view unconditionally. `--what=repo` / `--what=remote-tracking`
   only choose between the restored view's `head_ids`+`local_bookmarks`+`local_tags`+`wc_commit_ids`
   and its `remote_views`. Not stated in help text.

6. **Divergent (merge) operations are second-class in the display commands.** `jj op show` and
   `jj op log -d`/`-p` silently emit *no* diff for them (`if parent_ops.len() > 1 { return Ok(()) }`
   in `log.rs`, `show.rs`; `diff.rs` delegates to a `merge_operations`-built parent). `jj undo`,
   `jj redo` and `jj op revert` all refuse them by design (`Cannot undo a merge operation`,
   `Cannot revert a merge operation`), leaving `jj op restore` as the only tool. Confirmed
   empirically.

7. **`@-2`-style op expressions do not exist.** Very easy to get wrong in a tutorial. Only `@`,
   hex prefixes, and repeated `-`/`+`. `--at-op` accepts the same grammar (`jj --at-op @--` works;
   `jj --at-op @-2` fails).

8. **`workspace_name` returns `"⟨name⟩@"`**, i.e. it already includes the `@` that appears in the
   `op log` column, while the JSON serialization (`json(self)`) has the bare name. This inconsistency
   is real in 0.46.0 and worth a footnote.

9. **Index rebuild cost is real but unmeasured here.** Each operation is associated with an index
   segment through `.jj/repo/index/op_links/<128-hex>` (`lib/src/default_index/store.rs`). Loading a
   repo at an operation with no link file (a `--no-integrate-operation` op, an op reached only by
   `--at-op` into abandoned history, or after `jj op abandon` reparenting) requires building the
   index up to that operation. I could not benchmark this (no `/usr/bin/time` on this machine), so
   the tutorial should describe the *mechanism* and cite `op_links`, not a specific timing.
   `jj debug reindex --help` = "Rebuild commit index"; it clears `op_links/` (`reinit()`).

10. **`jj op abandon` silently rewrites descendant ids.** Abandoning `X` gives every descendant a new
    operation id, because the operation object's parent pointer (and therefore its content hash)
    changes. Anyone who scripted against a captured op id will be surprised. Document it.

11. **`--no-integrate-operation` leaves a real operation that is invisible to `jj op log`** until
    integrated. While unintegrated it *is* reachable via `--at-op <id>` and *is* restorable. If two
    such ops exist as sibling heads, any subsequent load prints
    `Concurrent modification detected, resolving automatically.` and creates a
    `reconcile divergent operations` op (whose `args:` is the *later* command line). Verified.

12. **There is no `_full_description` op-log template.** `--config
    'templates.op_log="builtin_op_log_compact_full_description"'` →
    `Error: Failed to parse template: Keyword \`builtin_op_log_compact_full_description\` doesn't exist`.
    Only the commit-log side has `builtin_log_compact_full_description`. The op-log equivalents are
    exactly the four listed in §3.2.

13. **The documented disposal workflow is `jj op abandon` → `jj util gc`.** `jj util gc --help`
    states verbatim: *"To garbage-collect old operations and the commits/objects referenced by them,
    run `jj op abandon ..<some old operation>` before `jj util gc`."* and *"By default, only obsolete
    objects and operations older than 2 weeks are pruned."* (`--expire <EXPIRE>` overrides). `jj op *`
    itself never deletes anything.

14. **`--quiet` suppresses the mutating commands' status lines.** `jj --quiet undo` prints nothing
    (verified), which matters for scripted demos.

15. **Not investigated (out of scope / low value):**
    - `jj op log` behaviour on Windows / non-UTF8 hostnames.
    - `jj debug operation` / snapshot-store debug subcommands beyond `jj debug reindex`.
    - Performance characteristics of very long op logs (thousands of ops) in `jj op log` without
      `-n`.
