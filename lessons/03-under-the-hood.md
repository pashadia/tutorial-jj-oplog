# Lesson 03 — Under the hood

## Theory

### What an operation *is* on disk

The op log is **not** stored in the commit backend. It is a separate,
plain-file, content-addressed store (`.jj/repo/op_store/`, backend name
`simple_op_store`), invisible to `git log`:

```
.jj/repo/op_store/type               # "simple_op_store"
.jj/repo/op_store/operations/<128-hex>   # one file per operation
.jj/repo/op_store/views/<128-hex>        # one file per view
.jj/repo/op_heads/type               # "simple_op_heads_store"
.jj/repo/op_heads/heads/<128-hex>        # ZERO-BYTE marker per head
.jj/repo/index/op_links/<128-hex>        # op → index segment
.jj/repo/index/segments/<128-hex>
.jj/repo/index/changed_paths/<128-hex>
.jj/working_copy/checkout            # protobuf: op id + workspace name
.jj/working_copy/tree_state          # the checked-out tree
```

An **operation** is a small protobuf (typically ~220–450 bytes; a
`describe`-family op with a 128-hex id embedded in its description runs
a little larger): view id, parent
op id(s), and metadata (timestamps, description, hostname, username,
`is_snapshot`, workspace name, the `args` attribute, and since 0.30 a
commit-predecessor map for rewrite tracking). A **view** (small — about 450 bytes in this sandbox, but growing with
every bookmark, tag and remote the repo tracks)
is the full repo state: head commits, local bookmarks/tags,
remote-tracking bookmarks/tags, git refs, per-workspace git HEAD, and
one working-copy commit **per workspace**.

Ids are 64-byte **BLAKE2b-512 content hashes** — hence the 128 hex
digits. Consequence: same content ⇒ same file (identical views
*deduplicate* — a repo can have fewer view files than op files), and
changing a parent changes the child's id (that's why `op abandon`
rewrites descendant ids). The **root op is virtual**: 64 zero bytes,
synthesized on read — no file at all.

Writes are temp-file + atomic rename, so a half-written op can never be
observed.

### Head markers, and why crashes are safe

`op_heads/heads/` holds one *empty file per current head* — the file's
*name* is the op id. Publishing is: **add the new marker first, then
remove the old one**. Every crash window therefore leaves at most a
*stale extra head*, never a lost one — and the next load heals it. The
unlink is even tolerant of the file already being gone, with a comment
that says exactly why:

> "It's fine if the old head was not found. It probably means that
> we're on a distributed file system where the locking doesn't work.
> We'll probably end up with two current heads. We'll detect that next
> time we load the view."

An empty `heads/` dir is the one unrecoverable state — the full
error chain is `Internal error: Unexpected error from operation heads
store`, caused by `Failed to read operation heads` →
`Corrupt repository: no head operation`.

### Three locks, and one non-lock

| Lock | Path | Taken by | Contention |
|---|---|---|---|
| op-heads lock | `.jj/repo/op_heads/heads/lock` | publishing any op; reconciling divergent heads | **blocks silently** (measured: a `jj new` waited 2.7 s with no message) |
| working-copy lock | `.jj/working_copy/working_copy.lock` *(created on demand — absent while idle)* | snapshot + checkout | blocks; a *lost tree race* errors: `Concurrent working copy operation. Try again.` |
| git import/export lock | `.jj/repo/git_import_export.lock` | colocated ref syncing | blocks |

What is **not** locked: writing op/view/index *objects*. They're
content-addressed and immutable — two processes writing the same bytes
produce the same filename and the rename just overwrites itself. Only
the head flip (and healing) is serialized. That's the whole "lock-free
concurrency" design in one sentence.

### The commit index is op-linked

Each op gets `index/op_links/<op-id>` pointing at the index segment that
matches its view. Loading a repo at an op with no link file (very old
op, abandoned-and-reparented history, `--at-op` into unfamiliar
territory) triggers a **silent partial rebuild** — walking ancestors
until a link is found, indexing the gap. `jj debug reindex` throws the
whole index away and rebuilds (`Finished indexing N commits.`) — the
escape hatch when things look wrong after crashes or version changes.

### Growth and garbage collection

Growth is ~one op + one view + one index segment per mutating command —
measured: 20 `jj describe`s on a clean working copy → exactly +20 ops
(~315 bytes per op *including* the view); a command that also
snapshots dirty files (or a colocated repo's git-side activity) adds
its extra ops on top. Nothing is ever overwritten; the
store is append-only. Two surprises:

- **Read-only commands can write op objects**: `jj op log --op-diff` /
  `jj op show` on a *merge* op reconstructs the parent state by writing
  unpublished `merge 2 operations` objects — orphans that linger until
  `gc` (lesson 05).
- `jj util gc` prunes unreachable ops/views older than 2 weeks
  (`--expire` accepts exactly `"now"`), guarded by file mtime to avoid
  deleting a head another process just created — but it never touches
  `op_heads/` or the `index/` directory. Only `jj debug reindex`
  shrinks the index.

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

**3.1** Map your repo:

```console
find .jj/repo -maxdepth 2 -type d | sort
for d in op_store op_heads index; do echo "$d/type: $(cat .jj/repo/$d/type)"; done
ls .jj/repo/op_heads/heads/            # one empty marker per head
wc -c .jj/repo/op_store/operations/* | tail -1
```

**3.2** Watch content addressing work:

```console
jj op log -n 1 --no-graph -T 'id ++ "\n"'     # 128 hex chars
ls .jj/repo/op_store/operations/ | wc -l
ls .jj/repo/op_store/views/ | wc -l            # fewer: identical views dedupe
```

**3.3** Read an op with `strings` — the metadata is plaintext protobuf:

```console
strings .jj/repo/op_store/operations/$(ls .jj/repo/op_store/operations | head -1)
```

You'll see the description, your hostname, your username, and the
`args` key. (Now you know what `builtin_op_log_redacted` is for.)

**3.4** Feel the lock (two terminals in `sandbox/`; `flock` is a
Linux/util-linux tool — on macOS hold the lock with a background `jj`
process instead):

```console
# terminal 1: hold the op-heads lock for 3 seconds
flock -x .jj/repo/op_heads/heads/lock sleep 3
# terminal 2, immediately:
jj new -m "blocked?"     # silently waits, then succeeds
```

No message, no error — contention is invisible without `--debug`.

**3.5** Measure growth and collect garbage:

```console
for i in $(seq 1 20); do jj describe -m "churn $i" >/dev/null 2>&1; done
ls .jj/repo/op_store/operations | wc -l
jj op abandon ..@----                   # drop all but the last few ops
jj util gc --expire now                 # actually delete unreachable ones
ls .jj/repo/op_store/operations | wc -l
ls .jj/repo/index/op_links | wc -l       # ...notice: the index did NOT shrink
```

(`--expire` in 0.46 accepts only the literal string `now`; the default
cutoff is two weeks. `2>&1` matters in the loop: jj prints its
working-copy lines on *stderr*.)

Note what you just did to earlier lessons' evidence: everything below
the abandoned range — the undo ops from 2.1, the snapshot from 1.2,
even the sandbox's birth ops — is gone from the log. Re-run
`./check.sh 01` (or `02`) now and watch it fail *honestly*: the ops it looks for
no longer exist. That's the one-way door, not a bug — and exactly why
each lesson's checks are meant to run when you finish that lesson.
(`./reset-sandbox.sh` restores everything, including the birth ops.)

**3.6** Rebuild the index:

```console
ls .jj/repo/index/op_links | wc -l
jj debug reindex         # Finished indexing N commits.
ls .jj/repo/index/op_links | wc -l      # 1
```

This is the companion to 3.5: `gc` reclaims op/view objects but never
touches `index/` — `jj debug reindex` is the only thing that throws
index segments away and starts over.

The next exercises (3.7–3.12) run in a **fresh lab repo** (3.12 deletes
old operations on purpose): from `sandbox/`, `cd .. && ./new-lab.sh
lab-internals && cd lab-internals`, then make a few ops
(`jj describe -m a; jj new -m b; jj bookmark create demo -r @-`) so there
is something to read. Bash required; ids are from one run.
(The op counts in 3.12's comments are from one run; yours will differ with the
number of ops you made in 3.8-3.11. Watch the relationships, not the absolute
numbers.)

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

`debug object tree -r @- ''` lists `README.md` as `File { id: FileId("7d9bddc4..."), executable: false, copy_id: CopyId("") }` and `src` as `Tree(TreeId(...))`;
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
wc -c .jj/working_copy/checkout .jj/working_copy/tree_state          # 75 and ~80-100 bytes here
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

Directory counts before (they vary with how many ops you made): segments 8, op_links 9, changed_paths 0. `jj debug index-changed-paths` (the optional changed-path index; it was empty until we ran this) prints
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
KEEP=$(jj op log --no-graph -T 'id ++ "\n"' | sed -n 4p)   # @---: about to be abandoned, and its view is not shared
jj op abandon ..@---                              # Abandoned 6 operations and reparented 3 descendant operations.
ls $OPD | wc -l                                   # 12: abandon unlinks, it does not delete (9 + 3 reparented)
jj op log --no-graph -T 'id ++ "\n"' | sort > /tmp/reach.txt
ls $OPD | sort > /tmp/all.txt
comm -13 /tmp/reach.txt /tmp/all.txt > /tmp/unreach.txt; wc -l < /tmp/unreach.txt     # 9 unreachable op files
grep -c $KEEP /tmp/unreach.txt                    # 1: it is one of them
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

## Verify

```console
./check.sh 03
```
