# DRAFT d3c — lesson 03 additions (3.7 ...): `jj debug`, the working-copy pointer, gc mtime protection

Status: run on jj 0.46.0 in a throwaway copy (isolated HOME/JJ_CONFIG). Ids are from real runs and will differ.
Sources: /home/bogdan/work/google-jj/jj-upstream (`cli/src/commands/debug/`, `lib/src/protos/*.proto`, `lib/src/simple_op_store.rs`, `cli/src/commands/util/gc.rs`).

## Theory addendum

### `jj debug`: the structured way to read what 3.3 read with `strings`

`jj debug --help` ("Low-level commands not intended for users") lists, in 0.46: `copy-detection fileset index
index-changed-paths init-simple local-working-copy object reindex revset stacked-table template tree watchman working-copy`.
There is **no** `jj debug operation` — `jj debug operation` answers `error: unrecognized subcommand 'operation'`
(with a misleading "a similar subcommand exists: 'copy-detection'"). Operations live under
`jj debug object operation <ID>`. `jj debug object` has six subcommands: `commit file operation symlink tree view`.
Output is Rust `Debug` pretty-printing: stable enough to read, not a format to script against.
Ids must be **full-length** (128 hex for ops/views, 40 for commits): prefixes fail, see 3.9.

### What the working copy remembers

`.jj/working_copy/` has three files (`type` = `local`, `checkout`, `tree_state`) and, only during a mutation, a lock file.
`checkout` is the `Checkout` protobuf (`lib/src/protos/local_working_copy.proto`): `bytes operation_id = 2; string workspace_name = 3;`
— i.e. exactly "the operation the files were last synced to" plus the workspace name (75 bytes: `12 40 <64-byte op id> 1a 07 default`).
`tree_state` is the `TreeState` protobuf: `tree_ids`, per-file `FileState` (mtime, size, type), sparse patterns, watchman clock.
`jj debug working-copy` prints the former, `jj debug local-working-copy` both.

### gc and the mtime guard

`jj util gc` (`cli/src/commands/util/gc.rs`) computes `keep_newer = now - 2 weeks` (default) or `now` (`--expire now`),
then `SimpleOpStore::gc(head_ids = [the current op], keep_newer)` (`lib/src/simple_op_store.rs`): reachable ops are
found by walking from the single current op; every other op file is removed **unless its mtime is newer than
`keep_newer`** (`if mtime > keep_newer { not removing }`), and then the same for view files not referenced by a reachable op.
Consequences: a just-written object is safe from a concurrent gc, but an op and its view are judged **independently**.
Also: gc refuses `--at-op` (`Cannot garbage collect from a non-head operation`), and takes the *current* op as its only root, so it
reconciles a fork first.

## Exercises

**3.7** Which debug commands exist, and where is the operation one?

```console
jj debug --help | sed -n '/^Commands:/,/^$/p'
jj debug operation
jj debug object --help | sed -n '/^Commands:/,/^$/p'
```

Verified: the `Commands:` list above; `error: unrecognized subcommand 'operation'`; and for `object`: `commit  file  operation  symlink  tree  view`.

**3.8** Read an operation and its view as structured data (compare with 3.3's `strings`):

```console
OPID=$(jj op log -n 1 --no-graph -T 'id')
jj debug object operation $OPID
VID=$(jj debug object operation $OPID | grep -A1 view_id | tail -1 | tr -d ' ",')
jj debug object view $VID
ls -l .jj/repo/op_store/operations/$OPID .jj/repo/op_store/views/$VID
```

Verified (op created by `jj bookmark create demo -r @-`):

```text
Operation {
    view_id: ViewId("43b77c9fc3fd8934f1d2f5343b2b7911b8...f1"),
    parents: [ OperationId("7f2461aafc4a9e663e52634b7835d29000e8...f2") ],
    metadata: OperationMetadata {
        time: TimestampRange { start: ... MillisSinceEpoch(1793956244195), tz_offset: 60 ...
                               end:   ... MillisSinceEpoch(1793956244196), tz_offset: 60 ... },
        description: "create bookmark demo pointing to commit 9af976d252381da4022e95dfaeca175f4ce6ae69",
        hostname: "host",
        username: "tut",
        is_snapshot: false,
        workspace_name: Some(WorkspaceNameBuf("default")),
        attributes: { "args": "jj bookmark create demo -r @-" },
    },
    commit_predecessors: Some({}),
}
```

(Real output is fully expanded, one field per line.) Everything 3.3 showed via `strings` is here: description,
hostname, username, `args`; plus what `strings` can't show — millisecond start/end, `is_snapshot`, and the
`commit_predecessors` map (0.30+; `Some({})` here because this op rewrote no commit; after a `jj describe` the same
command shows `{ CommitId("b5943d2d..."): [ CommitId("118756b8...") ] }` — new commit -> its predecessor, stored in the **op**, not in the commit).
The view prints `head_ids`, `local_bookmarks` (`demo`, `main` as `Resolved(Some(CommitId(...)))`), `local_tags`,
`remote_views` (note the pseudo-remote **`git`**: `main@git`/`demo@git` are real entries with `state: Tracked`), `git_refs`
(`refs/heads/demo`, `refs/heads/main`), `git_heads` and `wc_commit_ids { "default": ... }`. Sizes on disk: op file 300 bytes, view file 439 bytes.
A conflicted bookmark prints as `Conflicted([ Some(CommitId(..)), Some(CommitId(..)), None ])` instead of `Resolved(Some(..))`:
alternating add / remove / add terms (here: + Y, - X, + absent, from 2.9's revert) — the data model behind `topic (conflicted)`, and it is repeated under `remote_views` for the `git` remote.

**3.9** Commits, trees, files — and the one place ids are strict:

```console
jj debug object commit $(jj log -r @ --no-graph -T commit_id)
jj debug object tree -r @- ''
jj debug object tree -r @- src
jj debug object file -r @- README.md
jj debug tree -r @-
git cat-file -p $(jj log -r @ --no-graph -T commit_id)
```

Verified highlights:

```text
Commit {
    parents: [ CommitId("9af976d252381da4022e95dfaeca175f4ce6ae69") ],
    predecessors: [],
    root_tree: Resolved(TreeId("941a598030bd4a7dc7f91b8b9eb241c934a26599")),
    conflict_labels: Resolved(""),
    change_id: ChangeId("ea2afc845b2241d786577906c1e9a156"),
    description: "second\n",
    author: Signature { name: "Tut User", email: "tut@example.com", ... },
    committer: Signature { ... },
    secure_sig: None,
}
```

`debug object tree -r @- ''` lists `README.md`, `f.txt` as `File { id: FileId("7d9bddc4..."), executable: false, copy_id: CopyId("") }` and `src` as `Tree(TreeId(...))`;
`... tree -r @- src` lists `greet.py`; `... tree -r @- .` fails: `Error: The path is not a single tree in the commit`.
`jj debug tree -r @-` flattens: `src/greet.py: Ok(Resolved(Some(File { id: FileId("18a36554..."), executable: false, copy_id: CopyId("") })))`.
`change_id` is raw hex here (`ea2afc84...`); `jj log -T change_id` shows the same 16 bytes as z-k letters (`change_id.normal_hex()` gives the hex).
And because this repo is Git-backed, the same commit is a plain Git object — `git cat-file -p` prints an ordinary commit with one extra header:

```text
tree 941a598030bd4a7dc7f91b8b9eb241c934a26599
parent 9af976d252381da4022e95dfaeca175f4ce6ae69
author Tut User <tut@example.com> 1793956244 +0100
committer Tut User <tut@example.com> 1793956271 +0100
change-id lpxpknrvuoxxvymsrtussqztnylqpyut

second, reworded
```

The `tree` hash equals `root_tree`: same object. `change-id` is the jj-only header (z-k alphabet, full length). After a `jj describe`, `debug object commit` shows
`predecessors: [ CommitId("118756b8...") ]` although the Git object has no such header: predecessors come from the **operation**'s map (3.8), which is why they die with `abandon`+`gc`.
Strictness: `jj debug object operation 5e79aefaca84` -> `Internal error: Failed to load an operation` / `Object 5e79aefaca84 of type operation not found`;
`... operation @` -> `Error: Invalid hex operation id: "@"`; `... commit 7d2b191c` -> `Invalid hash length for object of type commit (expected 20 bytes, got 4 bytes)`.
The **root** operation is virtual (3.1) but readable: `debug object operation 000...0` (128 zeros) prints an `Operation` with `parents: []`, timestamps `MillisSinceEpoch(0)`,
and a `view_id` of 128 zeros; `debug object view 000...0` prints a view whose only head is `CommitId("0000000000000000000000000000000000000000")` (the root commit).

**3.10** Working-copy pointer, tree state, and why it can disagree with the log:

```console
cat .jj/working_copy/type; echo
wc -c .jj/working_copy/checkout .jj/working_copy/tree_state          # 75 and ~99 bytes here
od -An -tx1 -v .jj/working_copy/checkout | tr -d ' \n' | cut -c1-24    # 12402dacf45b6ac2b8961e3b
jj debug working-copy
jj op log -n 1 --no-graph -T 'id.short(16)'
jj debug local-working-copy
```

Verified:

```text
local
 75 .jj/working_copy/checkout
 99 .jj/working_copy/tree_state
12402dacf45b6ac2b8961e3b          <- 0x12 = field 2 (operation_id), 0x40 = 64 bytes, then the op id: 2dacf45b6ac2...
Type: "local"
Current operation: OperationId("2dacf45b6ac2b8961e3bcb90b29567eb98561bb666840fe742a1d55ea41fb07e664074d71c42b22ffb401c5f96ea78d30a993329c88d43f1d7b860a00459b747")
Current tree: MergedTree { tree_ids: Resolved(TreeId("941a598030bd4a7dc7f91b8b9eb241c934a26599")), labels: Unlabeled, .. }
2dacf45b6ac2b896
Normal { exec_bit: ExecBit(false) }            65 1793956244094 None "README.md"
Normal { exec_bit: ExecBit(false) }             3 1793956244171 None "f.txt"
Normal { exec_bit: ExecBit(false) }            94 1793956244104 None "src/greet.py"
```

Read it: the `checkout` bytes literally begin with the head op id; the `tree` is the very `root_tree` of 3.9; each file line
is (file type, size, mtime in ms, conflict-marker data, path) — jj's snapshot fast path compares size+mtime with disk.
`.jj/working_copy/*.lock` does not exist while idle (lesson 03's table). In a single workspace `Current operation` always equals the head op.
In a two-workspace repo (lesson 04) the *other* workspace's pointer lags the head: that gap is what 2.10 turns into the
`sibling` error when the pointer's op gets abandoned. `jj debug working-copy` does **not** snapshot (verified with a dirty tree: op count 11 -> 11), so it is safe to run
first when a workspace acts stale. `jj debug local-working-copy` **does** (11 -> 12, and the new file shows up in its list); add
`--ignore-working-copy` to look without touching (verified: new file absent, op count unchanged; then it prints the *recorded* state).

**3.11** The index, from the inside:

```console
jj debug index
ls .jj/repo/index/segments | wc -l; ls .jj/repo/index/op_links | wc -l; ls .jj/repo/index/changed_paths | wc -l
jj debug index-changed-paths
jj debug index
jj debug reindex
ls .jj/repo/index/segments | wc -l; ls .jj/repo/index/op_links | wc -l; ls .jj/repo/index/changed_paths | wc -l
jj debug index
```

Verified (repo with 9 commits after a few `describe`/`new` ops):

```text
=== Commits ===
Number of commits: 9
Number of merges: 0
Max generation number: 4
Number of heads: 5
Number of changes: 6
Stats per level:
  Level 0:
    Number of commits: 9
    Name: 0be0948969c286462d5a10de99da89f1121024cb1916223f790e7051b2cfd48735ddca21bece5a9fe4c707602bc5dd22185e99b0966ced1869c806d353683f91
=== Changed paths ===
Indexed commits: none
Stats per level:
```

Directory counts before: segments 8, op_links 9, changed_paths 0. `jj debug index-changed-paths` (the optional changed-path index; it was empty until we ran this) prints
`Finished indexing 0..9 commits.` and a second `debug index` now shows `Indexed commits: 0..9`, `Number of changed paths: 4`, `Number of paths: 3`, and one `changed_paths/<name>` file.
Then `jj debug reindex` -> `Finished indexing 9 commits.` and the counts become **segments 1, op_links 1, changed_paths 0**, and the
`Changed paths` section is back to `Indexed commits: none`: reindex throws away the optional changed-path index too.
`Number of commits: 9` / `heads: 5` / `changes: 6` are larger than what `jj log` shows: the index also holds rewritten (hidden) predecessors, which is why hidden commits stay addressable by id.
The `Name:` hash is the segment file name in `index/segments/`; each op's `op_links/<op>` file names the segment that
matches that op's view (lesson 03's "op-linked" paragraph).

`jj debug stacked-table -n <KEY_SIZE> <DIR>` reads the same on-disk format for any table store; the Git backend's commit-extras table is one:
`jj debug stacked-table -n 20 .jj/repo/store/extra` -> `Number of entries: 8` / `Level 0:` / `Name: def8464774...`. Caveat discovered: a wrong key size **panics**
(`-n 64` there: `thread 'main' panicked at lib/src/stacked_table.rs:117:27: 'at' split index (is 544) should be <= len (is 418)`), and `.jj/repo/index/segments` is not a table dir
(`Failed to load table heads`). A debugging command, so be gentle. Not for the lesson body; mention as an aside at most.

**3.12** gc's mtime guard, deterministically (mtime in the future = "an object some other process just wrote"):

```console
for i in 1 2 3 4 5 6; do jj describe -m "w$i" >/dev/null 2>&1; done
OPD=.jj/repo/op_store/operations; VD=.jj/repo/op_store/views
ls $OPD | wc -l                                   # 9
jj op abandon ..@---                              # Abandoned 6 operations and reparented 3 descendant operations.
ls $OPD | wc -l                                   # 12: abandon unlinks, it does not delete (9 + 3 reparented)
jj op log --no-graph -T 'id ++ "\n"' | sort > /tmp/reach.txt
ls $OPD | sort > /tmp/all.txt
comm -13 /tmp/reach.txt /tmp/all.txt > /tmp/unreach.txt; wc -l < /tmp/unreach.txt     # 9 unreachable op files
KEEP=$(head -1 /tmp/unreach.txt)                  # (pick one whose view is not shared; see below)
touch -d '+1 hour' $OPD/$KEEP                     # pretend it was written "just now"
jj util gc --expire now
ls $OPD | wc -l; ls $VD | wc -l                   # 4 and 3
```

Verified: `ops=9 views=9` at the start; after abandon `ops=12` while `jj op log` shows 4 lines (3 ops + the virtual root);
`gc --expire now` is silent (exit 0) and leaves `ops=4 views=3` — the three reachable ops **plus the touched one**. Every untouched unreachable op is gone.
Details worth teaching:

- The protected op's **view** was *not* protected (we only touched the op). Loading it:

```text
$ jj --at-op=48f1e78cd933 log
Internal error: Failed to load the repo
Caused by:
1: Object f57ee739c39debfc42297a1b213cce913d6cf98d471e47331e2a058f3844ba1f0168a935934ed58955ac86600e6a5e3bc13d675ad258dfbb13a47066d3a1d9df of type view not found
```

  — a half-kept op: `jj op log --at-op=<it>` can still print its description, but anything that needs the view fails.
  Touch both (`touch -d '+1 hour' $OPD/$KEEP $VD/$KV`; `KV` from `jj debug object operation $KEEP`) and `jj --at-op=<it> log` works after gc (verified: `ops=4 views=4`).
- Views are content-addressed and shared: the 3 reparented ops reuse the views of the originals, so an unreachable op whose view equals a reachable op's view
  keeps its view regardless of mtime (our first attempt, picking the oldest unreachable op, left `--at-op=<it> log` working for exactly this reason).
- `jj util gc` (no flag) uses a 2-week cutoff and removes nothing here (`ops` stays 4). `jj util gc --expire yesterday` -> `Error: --expire only accepts 'now'`.
  `jj --at-op=@- util gc` -> `Error: Cannot garbage collect from a non-head operation`.
- In real life the guard protects the window between a process writing a new op/view and publishing the head, not hand-edited mtimes; `touch` is the tutorial's stand-in.

## check.sh additions (sketch; all read-only)

```bash
  maybe "3.7  jj debug has no 'operation' subcommand, but debug object operation works" \
    "! jj --ignore-working-copy debug operation >/dev/null 2>&1 && jj --ignore-working-copy debug object operation \$(jj --ignore-working-copy op log -n1 --no-graph -T id) | grep -q 'view_id'" \
    "jj debug object operation <full 128-hex id>"
  maybe "3.10 the working copy's recorded op is the head op (single workspace)" \
    "jj --ignore-working-copy debug working-copy | grep -q \"\$(jj --ignore-working-copy op log -n1 --no-graph -T id)\"" \
    "jj debug working-copy (in a multi-workspace repo this can legitimately differ)"
  maybe "3.10 checkout file starts with the op-id field" \
    "od -An -tx1 -v .jj/working_copy/checkout | tr -d ' \\n' | grep -q \"^1240\$(jj --ignore-working-copy op log -n1 --no-graph -T id)\"" \
    "head op id should follow bytes 12 40"
  maybe "3.11 reindex left one segment and one op_link" \
    "[ \"\$(ls .jj/repo/index/segments | wc -l)\" -eq 1 ]" "jj debug reindex"
  info  "3.12 gc mtime demo is destructive of old ops; run after 3.5"
```
