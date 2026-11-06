# jj 0.46.0 — Operation Log Internals (source-verified research brief)

**Scope.** How the op log *works* in **jj 0.46.0** exactly: on-disk format, the view, locking, divergence
and healing, undo/redo/restore/revert, `op abandon`, `--at-operation`/`--no-integrate-operation`, the commit
index relationship, working-copy snapshots, and growth/GC.

**Method / how to reproduce every claim.**

* Source: `jj-upstream` at tag **v0.46.0** (`7d382314f`), read with
  `git -C /home/bogdan/work/google-jj/jj-upstream show v0.46.0:<path>`.
  All `path:line` citations below are **line numbers in the v0.46.0 blob**, not in upstream `main`
  (main is ~203 commits ahead — do not trust main line numbers).
* Binary: `/home/bogdan/work/google-jj/tutorial-oplog/tools/jj` → `jj 0.46.0-7d382314f9420b4b8d932245b49c99492c812b9f`.
  Every empirical run used `JJ_CONFIG=/dev/null` inside a fresh `mktemp -d` directory; nothing was run
  inside a live repo.
* Storage layouts, byte counts, file counts, and message transcripts marked **[measured]** come from those
  throwaway repos (`mktemp -d`, since deleted — each experiment is described well enough to re-run in a couple
  of commands; the path quoted next to a measurement is the temp dir it came from).

---

## 0. One-paragraph mental model

An **operation** is a small content-addressed protobuf file that stores (a) the id of a **view**, (b) the ids
of its **parent operations**, and (c) metadata (start/end timestamps, description, hostname, username,
`is_snapshot` flag, workspace name, free-form `attributes` such as the command line) plus an optional
**commit-predecessor** map. The **view** is a second small protobuf file that stores "how the repo looked at
the end of that operation": the set of visible head commits, local bookmarks/tags, remote-tracking
bookmarks/tags with their `Tracked`/`New` state, Git refs, per-workspace Git HEAD targets, and the
working-copy commit id for each workspace. Neither is stored in the commit backend (Git or simple); both live
in a dedicated file store under `.jj/repo/op_store/`, and `.jj/repo/op_heads/heads/` holds one empty
marker file per **current** op head. Every command starts by resolving those head markers to a single
operation (merging them if there is more than one), then works on an in-memory `MutableRepo`, and finally
writes a **new** view + operation + index segment and atomically flips the head marker while holding a
`flock` on `.jj/repo/op_heads/heads/lock`. Because views are snapshots (not deltas), "undo" is just
"write a new operation whose view is an older view".

Citations for the model: `core/src/op_store.rs:175` (`View`), `:295` (`Operation`), `:357`
(`OperationMetadata`), `:423` (`trait OpStore`), `lib/src/transaction.rs:135` (`Transaction::write`),
`lib/src/transaction.rs:231` (`UnpublishedOperation::publish`), `lib/src/op_heads_store.rs:85`
(`resolve_op_heads`).

---

## 1. Physical storage: what an operation *is* on disk

### 1.1 There is a dedicated op store, separate from the commit backend

`OpStore` is its own trait with its own `type` file, initialized next to the commit backend:
`core/src/op_store.rs:423` (`pub trait OpStore`), `lib/src/repo.rs:217` (`ReadonlyRepo::init`) creates
`store/`, `workspace_store/`, `op_store/`, `op_heads/`, `index/`, `submodule_store/`, each with a
`type` file holding the backend name (`lib/src/repo.rs:233`, `:242`, `:253`, `:261`, `:268`).

`.jj/repo/op_store/type` = `simple_op_store` ⇒ `lib/src/simple_op_store.rs:86` (`struct SimpleOpStore`,
`NAME = "simple_op_store"` at `:91`). This backend is **plain files**, written with
`NamedTempFile` + atomic rename (see §1.5). Operations are **not** commits: they are not in the Git object
database and do not appear in `git log`. **[measured]** In a colocated repo with 3 commits and 4 operations,
`git count-objects -v` reported 4 loose objects — 3 commits + 1 tree, no op objects, and `.jj/repo/op_store/` held
the op/view files.

### 1.2 Measured layout of a fresh repo

`jj git init --colocate` in a temp dir (`/tmp/oplay.9BHyFC`), then `jj describe -m one`:

```
.jj/.gitignore                     # "/*"
.jj/repo/op_store/type             # simple_op_store
.jj/repo/op_store/operations/<128-hex>   # one file per operation (root op is virtual, no file)
.jj/repo/op_store/views/<128-hex>        # one file per view     (root view is virtual, no file)
.jj/repo/op_heads/type             # simple_op_heads_store
.jj/repo/op_heads/heads/<128-hex>        # ZERO-BYTE marker file per current head
.jj/repo/index/type                # default
.jj/repo/index/op_links/<128-hex>        # op -> index segment association (see §8)
.jj/repo/index/segments/<128-hex>
.jj/repo/index/changed_paths/<128-hex>
.jj/repo/store/type                # git
.jj/repo/store/git_target          # "../../../.git"
.jj/repo/store/extra/<128-hex>           # stacked-table files: jj-only per-commit metadata (change id, …)
.jj/repo/workspace_store/type      # simple_workspace_store
.jj/repo/submodule_store/type      # default
.jj/working_copy/type              # local
.jj/working_copy/checkout          # protobuf: operation_id + workspace_name  (§9)
.jj/working_copy/tree_state        # protobuf: tree ids, file states, sparse patterns
```

Sizes **[measured]**: operation objects 222–329 bytes; view objects 57 bytes for a bare repo and 124–285 bytes
once bookmarks / remote-tracking refs exist (`/tmp/opbm.FAjQtS`). A 61-operation repo
(`/tmp/opsize.5HMk3e`, 30 × `jj describe`) had `op_store` = 21 816 bytes total ⇒ ≈ 360 bytes per operation
*including* its view.

The root operation/view are **virtual**: their ids are 64 zero bytes and both are synthesized on read
(`lib/src/simple_op_store.rs:115-116`, `:146-149` `read_view` → `View::make_root`, `:183-186`
`read_operation` → `Operation::make_root`; `core/src/op_store.rs:198`, `:325`).

`.jj/repo` is a **directory** in the workspace that owns the repo, and a **file** containing a relative path
(`../../main/.jj/repo`) in every other workspace (`lib/src/workspace.rs:374`
`init_workspace_with_existing_repo`, writing `jj_dir.join("repo")` at `:395`). **[measured]** in
`/tmp/opstale2.oahx6c/secondary/.jj/repo`.

### 1.3 The `Operation` payload (protobuf)

Wire schema `lib/src/protos/simple_op_store.proto` (`message Operation`):

| field | type | meaning |
|---|---|---|
| 1 | bytes | `view_id` |
| 2 | repeated bytes | `parents` (operation ids) |
| 3 | `OperationMetadata` | start/end `Timestamp`, `description`, `hostname`, `username`, `is_snapshot`, `optional workspace_name`, `map<string,string> attributes` |
| 4 | repeated `CommitPredecessors` | `commit_id` + `predecessor_ids` (rewrite tracking, since 0.30) |
| 5 | bool | `stores_commit_predecessors` |

The Rust mirror is `core/src/op_store.rs:295` (`Operation`) with doc:

> "Represents an operation (transaction) on the repo view, just like how a Commit object represents an
> operation on the tree." … "The operation history will almost always be linear. It will only have forks
> when parallel operations occurred. The parent is determined when the transaction starts. When the
> transaction commits, a lock will be taken and it will be checked that the current head of the operation
> graph is unchanged. If the current head has changed, there has been concurrent operation."

`commit_predecessors` doc (`:311-322`) explains `{commit: []}` = newly created, `{commit: [pred…]}` =
rewritten, transitive predecessors preserved. `Operation::make_root` sets `is_snapshot: false`,
`description: ""`, `workspace_name: None` (`:325-350`).

**[measured]** decoding raw op files with a hand-written protobuf reader (`/tmp/pbparse.py`) in a divergent
repo (`/tmp/opdiv.svw9vx`) printed exactly what the schema says:

```
33be1d3c7e33 parents=1 bytes=329 desc='describe commit e2c27bac…'
8fcb55b9c735 parents=2 bytes=259 desc='merge 2 operations'          <- written by `jj op log --op-diff`!
c9fc0d5dfe8f parents=2 bytes=299 desc='reconcile divergent operations'
cae2c283bfa0 parents=1 bytes=222 desc="add workspace 'default'"
f7922ea71f0d parents=1 bytes=316 desc='describe commit e2c27bac…'
```

### 1.4 Ids are content hashes

`OperationId` / `ViewId` are **64-byte** ids: `blake2b_hash` is `Blake2b512` (`core/src/content_hash.rs:25-30`)
and `OPERATION_ID_LENGTH = 64` / `VIEW_ID_LENGTH = 64` (`lib/src/simple_op_store.rs:71-72`), hence the 128 hex
digits in file names. The id types themselves are declared with `id_type!` (`core/src/op_store.rs:47-52`).
`write_view` computes `ViewId::new(blake2b_hash(view).to_vec())` (`lib/src/simple_op_store.rs:174`);
`write_operation` computes `OperationId::new(blake2b_hash(operation).to_vec())` (`:219`). Hashes are over the
`ContentHash`-derived canonical form, so **rewriting a parent changes the child's id** — this is why
`jj op abandon` produces *new* operation ids for reparented descendants (§6), and why identical content
written twice de-duplicates to the same file.

`write_operation` asserts `!operation.parents.is_empty()` (`:206`); `read_operation` back-fills the root as
parent for pre-root-operation repos (`:197-201`).

Id prefix resolution is a directory scan with a fast path for full-length ids
(`lib/src/simple_op_store.rs:228` `resolve_operation_id_prefix`).

### 1.5 Writes are atomic, no fsync-of-directory

`persist_content_addressed_temp_file` (`core/src/file_util.rs:248`) `sync_data()`s the temp file, then on Unix
`persist()`s (atomic `rename`, overwriting an existing identical file) `:270-276`; on Windows it uses
`persist_noclobber` and tolerates "already exists" `:255-269`. Both `write_view` and `write_operation` go
through it.

### 1.6 Op heads: one empty file per head

`SimpleOpHeadsStore` keeps the *set* of heads as the *set of file names* in `op_heads/heads/`
(`lib/src/simple_op_heads_store.rs:64` `init` creates `heads/` and adds the root op id; `:77`
`add_op_head` = `fs::write(path, "")`; `:82` `remove_op_head` = `remove_file`, and a `NotFound` is
explicitly tolerated:

> "It's fine if the old head was not found. It probably means that we're on a distributed file system where
> the locking doesn't work. We'll probably end up with two current heads. We'll detect that next time we
> load the view."

`get_op_heads` (`:135`) `read_dir`s, keeps names that decode as hex, sorts, and errors with
`"Corrupt repository: no head operation"` if empty.

`update_op_heads(old_ids, new_id)` (`:112`) adds the new marker **first**, then deletes the old ones —
so a crash can leave an extra (older or equal) head, never lose the new one.

---

## 2. The view: exactly what repo state an operation snapshots

`core/src/op_store.rs:175` `pub struct View`, doc: "Represents the way the repo looks at a given time, just
like how a Tree object represents how the file system looks at a given time."

| field | type | notes |
|---|---|---|
| `head_ids: HashSet<CommitId>` | protobuf field 1 | visible heads; "There should be at least one head commit" |
| `local_bookmarks: BTreeMap<RefNameBuf, RefTarget>` | 5 (legacy `Bookmark`) | `RefTarget = Merge<Option<CommitId>>` ⇒ a bookmark can be **conflicted** |
| `local_tags: BTreeMap<RefNameBuf, RefTarget>` | 6 | same |
| `remote_views: BTreeMap<RemoteNameBuf, RemoteView>` | 11 | per remote: `bookmarks`/`tags` maps of `RemoteRef { target, state: New or Tracked }` |
| `git_refs: BTreeMap<GitRefNameBuf, RefTarget>` | 3 | only a subset of Git refs ("does not include refs/notes/", proto comment) |
| `git_heads: BTreeMap<WorkspaceNameBuf, RefTarget>` | 13 | per-workspace Git HEAD target (colocated repos) |
| `wc_commit_ids: BTreeMap<WorkspaceNameBuf, CommitId>` | 8 | the commit that *should be* checked out |

Supporting types: `RefTarget` (`:72`), `RemoteRef` / `RemoteRefState` (`:76`, `:110`), `RemoteView` (`:212`).

**What is NOT in the view** (this matters for "what does undo restore"):

* No change-id → commits index. `ReadonlyRepo::change_id_index` is a `OnceCell` built lazily at runtime
  (`lib/src/repo.rs:164-172`, `:332`). So the view is *not* where "the new-change-id index" lives in 0.46.0.
* No working-copy *actual* state: the *desired* commit is in the view, the *checked-out* commit and the
  per-file state are in `.jj/working_copy/{checkout,tree_state}` (§9).
* No sparse patterns, no "current workspace", no config.

The runtime wrapper `lib/src/view.rs:46` adds `head_normalized: bool`; `store_view()` (`:634`) gives back the
`op_store::View` that gets hashed into a `ViewId`. Heads are normalized (reduced to the true antichain) before
persisting — `View::normalize_heads` (`:646`) and the `assert!(view.is_heads_normalized())` in
`Transaction::write` (`lib/src/transaction.rs:148`).

### 2.1 Consequences for merging (preview of §4)

Because the view is a flat snapshot, merging two operations means a **3-way merge per field**: heads as a
commit-DAG merge, refs as `Merge`-term merges that *can produce conflicts* (`lib/src/refs.rs:95`
`merge_ref_targets`), `wc_commit_ids` via `merge_wc_commit` (`lib/src/repo.rs:1674`).

**[measured]** A genuine bookmark conflict produced purely by concurrency (`/tmp/opbm5.actgqN`: one op moved
`main` to `X`, a sibling op deleted `main`; then the next command reconciled them):

```
Concurrent modification detected, resolving automatically.
main (conflicted):
  - zlkrlyxx 61d69f3d (empty) A
  + wvyrtnxy c392dcf9 (empty) X
  @git: wvyrtnxy c392dcf9 (empty) X
Hint: Some bookmarks have conflicts. Use `jj bookmark set <name> -r <rev>` to resolve.
```

---

## 3. Locking: which file, who takes it, blocking or error

### 3.1 Op-heads lock: `.jj/repo/op_heads/heads/lock`

`SimpleOpHeadsStore::lock` = `FileLock::lock(self.dir.join("lock"))`
(`lib/src/simple_op_heads_store.rs:162-166`), i.e. **`.jj/repo/op_heads/heads/lock`**.
`FileLock` is `flock(LOCK_EX)` in a retry loop (`lib/src/lock/unix.rs:32` `lock` → `:43` `lock_inner`;
`FlockOperation::LockExclusive` at `:46`); it is **blocking, not an error**. `Drop` removes the file and
unlocks (`:104-112`), so the lock file normally does *not* exist when no jj process is running.

Taken in exactly two places:

1. `UnpublishedOperation::publish` — `lib/src/transaction.rs:231-236`
   (`let _lock = self.op_heads_store.lock().await?; self.op_heads_store.update_op_heads(parent_ids, new_id)`).
   This is the last step of *every* mutating command.
2. `resolve_op_heads` — `lib/src/op_heads_store.rs:112` — only when `op_heads/heads/` has **more than one**
   entry, to avoid two processes reconciling the same divergence.

Trait doc on why it is not a correctness requirement (`lib/src/op_heads_store.rs:62-71`):

> "Optionally takes a lock on the op heads store. The purpose of the lock is to prevent concurrent processes
> from resolving the same divergent operations. It is not needed for correctness; implementations are free to
> return a type that doesn't hold a lock."

Errors: `OpHeadsStoreError::Lock` renders `"Failed to lock operation heads store"` (`:41-43`); the underlying
`FileLockError` renders `"{message}: {path}"` with messages `"Failed to open lock file"` / `"Failed to lock
lock file"` / `"failed to stat lock file"` (`lib/src/lock/mod.rs:39-46`, `lib/src/lock/unix.rs:53`, `:64`,
`:91`).

**[measured]** With `flock -x` held on `.jj/repo/op_heads/heads/lock` (`/tmp/oplock.FolDC2`):

* `jj log -r @` (no repo change ⇒ no publish) finished in **16 ms** — no contention.
* `jj new -m y` (publishes) blocked and finished in **2704 ms**, i.e. it waited out the 3 s holder.
  **No message was printed**; contention is invisible unless `--debug` tracing is on
  (`tracing::info!("Attempting to lock {path:?}")` at `lib/src/lock/unix.rs:44`).

### 3.2 Working-copy lock: `<workspace>/.jj/working_copy/working_copy.lock`

`LocalWorkingCopy::start_mutation` (`lib/src/local_working_copy.rs:2759-2765`) does
`FileLock::lock(self.state_path.join("working_copy.lock"))` and maps errors to `WorkingCopyStateError` with
message `"Failed to lock working copy"`. It then **re-reads** `checkout` and `tree_state` after acquiring the
lock (`:2766-2775`), which is why the freshness check afterwards is trustworthy.

Held for the whole "snapshot + checkout" window of a command. Contention ⇒ the process blocks; a *logical*
race (someone else changed the tree) produces the hard error `"Concurrent working copy operation. Try again."`
in two places: `cli/src/cli_util.rs:1526` (`start_working_copy_mutation`) and `:3092`
(`update_stale_working_copy`), both comparing `tree_ids_and_labels()`.

### 3.3 Git import/export lock: `.jj/repo/git_import_export.lock`

Colocated repos additionally take a repo-level lock before importing/exporting Git refs/HEAD, so that the
operation the command loaded is the operation whose refs are synced
(`cli/src/cli_util.rs:1013-1023`; path built at `:1018`; error `"Failed to take lock for Git import/export"` at `:1020`).
Order of operations in `workspace_helper_with_stats` (`cli/src/cli_util.rs:473-511`): load workspace → env →
**take git lock** → resolve op head → snapshot (`import git head` → wc snapshot → `import git refs`).
Comment at `:477-480`: "Acquire the lock to ensure that the loaded repo points to the head operation whose
refs should be synchronized with the Git repo. This prevents races with other processes during Git HEAD and
refs import/export."

### 3.4 What is *not* locked

`OpStore::write_operation` / `write_view` and `IndexStore::write_index` take no lock at all: they rely on
content addressing (same bytes ⇒ same filename ⇒ rename over itself). Only the head flip is serialized.

---

## 4. Divergent op heads and healing

### 4.1 How divergence arises

`update_op_heads(old_ids, new_id)` removes exactly `old_ids` = **the parents of the new operation**. If a
command starts from operation `O` while the real head is `H`, publishing `N` (`parent = O`) leaves
`{H, N}` — the classic fork. Concrete causes:

1. `--at-op=<old op>` + a mutating command ("equivalent to having run concurrent commands starting at the
   earlier operation", `--at-operation` help text, `cli/src/cli_util.rs:3821-3845`). **[measured]**:
   `jj new -m side --at-op=$OLD` → `heads=2`, and **no message at the time**; the next command reports it.
2. Two real processes (different machines / NFS, or just fast parallel commands) — see
   `lib/tests/test_bad_locking.rs` (`test_bad_locking_children`, which merges two directory trees to simulate a
   distributed FS) and `cli/tests/test_concurrent_operations.rs::test_git_head_race_condition`.
3. `jj op integrate <unintegrated op>`, which re-adds an old operation as a head
   (`cli/src/commands/operation/integrate.rs:38-46`).
4. `--no-integrate-operation` (the op is written but never published) *plus* later work — see §7.3.
5. A crash after `add_op_head(new)` but before `remove_op_head(old)` (leaves a *descendant+ancestor* pair, not a
   true fork; healed without creating an operation — `lib/tests/test_bad_locking.rs::test_bad_locking_interrupted`).

### 4.2 The reconciliation algorithm (`resolve_op_heads`)

`lib/src/op_heads_store.rs:85-160`, in order:

1. `get_op_heads()`. If exactly one → read it and return (**no lock taken**).
2. Otherwise take the op-heads lock and re-read (another process may have finished the job; comment at
   `:112-116`).
3. Still one → return it.
4. Read all head operations.
5. **Drop ancestors**: `dag_walk_async::heads(op_heads, …)` keeps only maximal elements (`:128-133`), and
   remembers the dropped ones as `ancestor_op_heads`.
6. If exactly one maximal head remains → `update_op_heads(ancestor_op_heads, that_head)` and return it —
   **no new operation is created** (this is the "interrupted update" case; asserted by
   `lib/tests/test_bad_locking.rs::test_bad_locking_interrupted`).
7. Else sort the heads by **end timestamp** (`op_heads.sort_by_key(|op| op.metadata().time.end.timestamp)`,
   `:149`) and call the caller-supplied `resolver(op_heads)`.
8. `update_op_heads(ancestor_op_heads ∪ new_op.parent_ids(), new_op.id())`.

Because it is the *caller* that decides how to merge, the "heal" is not in the store: the resolver is
`RepoLoader::merge_operations` (`lib/src/repo.rs:869`, 3-way merge of views) or a hard error.

### 4.3 The view merge (`MutableRepo::merge` / `merge_view`)

`lib/src/repo.rs:2041` `pub async fn merge(&mut self, base_repo, other_repo)`:

1. `self.index.merge_in(base.readonly_index())`, `merge_in(other.readonly_index())` — index first, "so we can
   take advantage of a valid index when merging the view" (`:2046-2049`).
2. `normalize_heads()`.
3. `merge_view(&base.view, &other.view)` (`:2063`), field by field:
   * `wc_commit_ids` via `diff_named_commit_ids` + `merge_wc_commit` (`:2064-2066`, `:1674`).
   * heads: on the **default index** it calls `record_rewrites(base_heads, own_heads)` and
     `record_rewrites(base_heads, other_heads)` (`:2080-2081`) so that commits rewritten by the other side are
     rebased and their old heads replaced; only then
     `for added_head in other.heads().difference(base.heads()) { add_head }` (`:2089-2091`). For non-default
     indexes there is a `HACK` branch that merely removes/readds heads (`:2077-2087`).
   * `local_bookmarks`, `local_tags`, `git_refs`, remote bookmarks, remote tags, `git_heads` — each via
     `diff_named_*` + `merge_ref_targets` / `merge_remote_refs` (`:2094-2127`).
   * Refs merge as **conflicts**, not failures (`lib/src/refs.rs:95-118`: `trivial_merge` first, then a
     `Merge` of terms with `resolve_trivial`, then `merge_ref_targets_non_trivial` removing ancestor/add pairs).
4. Refs in the merge that were *moved on one side only* fast-forward silently; conflicting ones become
   `RefTarget` conflicts stored in the view.

`Transaction::merge_operation` (`lib/src/transaction.rs:110-121`) loads the base and other repos, pushes
`other_op` onto `parent_ops`, and calls `self.repo_mut().merge(&base_op_repo, &other_repo)`.

### 4.4 Multi-head merges and the `merge N operations` description

`RepoLoader::merge_operations` (`lib/src/repo.rs:869-985`) handles 0/1/N operations:

* 0 → root repo; 1 → that repo (`:880-889`).
* N: iterative work-list (explicit comment: previously recursive, caused stack overflow, PR #9586,
  `:871-877`). For each next op it computes `op_walk::closest_common_ancestors(tx.parent_ops(), [other_op])`
  and:
  * single common ancestor → `tx.merge_operation(ancestor, other_op)` then
    `num_rebased += tx.repo_mut().rebase_descendants()` (`:963-967`);
  * several common ancestors → look up (or recursively compute) their merge first (`:944-975`).
* The written operation's description is the caller's (`transaction_description`), else
  `format!("merge {} operations", operations.len())` (`:920-923`). Workspace name and command-line
  attributes are copied onto it (`:893-899`, attributes from `cli/src/cli_util.rs:2955`
  `command_args_to_transaction_attribute`).
* These intermediate merges are written with `tx.write(...).leave_unpublished()` (`:924`) — they exist in the
  store but are not heads. **[measured]** `merge 2 operations` op id `8fcb55b9c735`, produced by
  `jj op log --op-diff`, not by the reconcile (see §10.3).

### 4.5 CLI: the exact messages and who prints them

`CommandHelper::resolve_operation` (`cli/src/cli_util.rs:798-834`):

* `--at-op` given → `op_walk::resolve_op_for_load` (no merging; may fail, see below).
* else → `op_heads_store::resolve_op_heads(..., async |op_heads| { … })` whose closure prints to **stderr**:

```
Concurrent modification detected, resolving automatically.
```

(`:813`) and then calls `merge_operations(Some(ui), …, Some(workspace_name),
Some("reconcile divergent operations"), string_args)` (`:816-824`).

`cli/src/cli_util.rs:853-880` `merge_operations` reports the rebase count when >0:

```
Rebased {num_rebased} descendant commits onto commits rewritten by other operation.
```

Descriptions used for the healing operation:

* `"reconcile divergent operations"` — CLI (`cli/src/cli_util.rs:816`), library-level head load
  (`lib/src/repo.rs:809`), `jj op integrate` (`cli/src/commands/operation/integrate.rs:56`).
* **Not** "reconcile concurrent operations" — that string does not exist in v0.46.0 (grep over `*.rs`, `*.md`
  finds only "reconcile divergent operations"; CHANGELOG mentions older wording only in history).
* `format!("merge {} operations", n)` when no description is supplied (`lib/src/repo.rs:921`).

### 4.6 `jj op log` and divergence

`jj op log` snapshots and reconciles first, then walks ancestors of the single resolved operation
(`cli/src/commands/operation/log.rs:107-121`, walk at `:238-239`). The fork is visible **after** the fact because
the reconcile operation has two parents, drawn by the graph log:

```
@    c9fc0d5dfe8f bogdan@nixos default@ now, lasted less than a microsecond
├─╮  reconcile divergent operations
│ │  args: jj op log
○ │  f7922ea71f0d … describe commit e2c27bac … args: jj describe -m base
│ ○  33be1d3c7e33 … describe commit e2c27bac … args: jj describe -m side '--at-op=@-'
├─╯
○  cae2c283bfa0 … add workspace 'default'
○  000000000000 root()
```
**[measured]**, `/tmp/opdiv.svw9vx`; same shape as `cli/tests/test_concurrent_operations.rs:120-145`.

To look at a divergent state *without* healing it you must name a head explicitly or use `--at-op=@`
which refuses to merge:

```
$ jj op log --at-op=@
Error: The "@" expression resolved to more than one operation
Hint: Try specifying one of the operations by ID: f7922ea71f0d, 33be1d3c7e33
```
**[measured]**; identical to `cli/tests/test_concurrent_operations.rs:30-40` and
`cli/tests/test_operations.rs:145-150`. Source: `lib/src/op_walk.rs:91-112` (`resolve_op_for_load` installs a
resolver that returns `OpsetResolutionError::MultipleOperations`), error at `lib/src/op_walk.rs:69-74`,
hint at `cli/src/command_error.rs:876-884`:

```
"Try specifying one of the operations by ID: {}"
```

`jj op log --at-op=<one head id>` works and prints that head's ancestry only. `--ignore-working-copy` still
reconciles (it only skips snapshotting) — **[measured]**.

### 4.7 When healing fails or is refused

* `--at-op=@` with >1 head → `MultipleOperations` error (above). `--at-op=@ --ignore-working-copy` gives the
  same error, so the doc comment "Use `--at-op=@ --ignore-working-copy` to inspect the current state without
  mutation" (`cli/src/commands/operation/log.rs:46-52`) only holds when there is a single head.
* Resolver error (any error from `merge_operations`) propagates and **no** head update happens: the divergence
  stays on disk.
* Op / view file missing: `OpStoreError::ObjectNotFound` renders `"Object {hash} of type {object_type} not
  found"` (`core/src/op_store.rs:385-392`), surfaced by the stale-working-copy path as
  `"Could not read working copy's operation."` (`cli/src/cli_util.rs:3070`) or
  `"Failed to read working copy's current operation; attempting recovery. Error message from read attempt: {e}"`
  (`:754`).
* Empty heads dir → `"Corrupt repository: no head operation"` (`lib/src/simple_op_heads_store.rs:155`).
* Concurrent processes doing the same merge are serialized by the lock; the loser re-reads and returns the
  winner's operation (`lib/src/op_heads_store.rs:112-121`).

### 4.8 What the tests pin down

| test | what it demonstrates |
|---|---|
| `cli/tests/test_concurrent_operations.rs::test_concurrent_operation_divergence` | `--at-op=@` error + hint; `--at-op=<id>` showing one side; then the reconcile message and forked log |
| `…::test_concurrent_operations_auto_rebase` | reconcile prints the `Rebased 1 descendant commits onto commits rewritten by other operation.` line; rewritten commit's child is reparented |
| `…::test_concurrent_operations_wc_modified` | merged view keeps **both** sides' `wc_commit_ids` as separate conflicts; the wc is then snapshotted on top of the reconcile op; `snapshot working copy` → `reconcile divergent operations` → two `new empty commit`s |
| `…::test_concurrent_snapshot_wc_reloadable` | the `WorkingCopyFreshness::Updated` reload: repo is re-loaded at the wc's operation before snapshotting, so the new commit lands on the right parent |
| `…::test_git_head_race_condition` | parallel `debug snapshot` vs `next/prev` must not produce divergent `import git head` ops |
| `cli/tests/test_op_integrate_command.rs::test_integrate_sibling_operation` | sibling (not ancestor) wc op ⇒ `Internal error: The repo was loaded at operation X, which seems to be a sibling of the working copy's operation Y` + integration hint; `jj op integrate` then produces a reconcile op |
| `cli/tests/test_operations.rs:280-360` | `op log --reversed` / `--limit` graph rendering across a fork |
| `lib/tests/test_bad_locking.rs` | distributed-FS simulation: merged op has exactly 2 parents and both children are visible; interrupted update is healed with no new operation |
| `lib/tests/test_view.rs::test_merge_three_operations`, `test_merge_views_criss_cross` | 3-way view merge semantics, criss-cross common ancestors |
| `lib/tests/test_merge_operations.rs::test_merge_operations_deep_criss_cross` | 14-level criss-cross in a 512 KiB stack (regression test for the iterative rewrite) |

---

## 5. undo / redo / restore / revert semantics

All four are "write a new operation whose view is built from an old view". The shared view-selection helper is
`view_with_desired_portions_restored` (`cli/src/commands/operation/mod.rs:93-116`):

```rust
head_ids, local_bookmarks, local_tags, wc_commit_ids   <- repo_source  (if `--what repo`)
remote_views                                           <- remote_source (if `--what remote-tracking`)
git_refs, git_heads                                    <- always current_view
```

`--what` is `Repo` ("The jj repo state and local bookmarks") and `RemoteTracking` ("The remote-tracking
bookmarks. Do not restore these if you'd like to push after the undo"), default both
(`mod.rs:76-88`). **Git refs and per-workspace Git HEAD are never restored** — they track the real Git repo.

### 5.1 `jj op restore <op>`

`cli/src/commands/operation/restore.rs:47-70`: resolve op → start transaction → `set_view(restore(target_op.view))`
→ print `"Restored to operation: "` + op summary → `tx.finish(ui, format!("restore to operation {}", target_op.id().hex()))`.

* Restores the repo to the target op's view, "effectively undoing all later operations. It does so by
  creating a new operation" (doc comment `:25-28`).
* **[measured]** restoring to an op before a bookmark was created removes the bookmark
  (`/tmp/opbm.FAjQtS`), and the op log gains `restore to operation <full hex>`.

### 5.2 `jj undo`

`cli/src/commands/undo.rs:57-215`. Algorithm (documented in a long comment `:66-104` with an ASCII diagram):
1. `target_op = current operation` (i.e. `@`).
2. If `target_op.description` starts with `"undo: restore to operation "`, parse the hex after it and use
   **that** operation as `target_op` (so a second `jj undo` undoes the *original* operation, not the undo op).
3. Refuse cross-workspace (`Refusing to undo operation {} because it was performed in workspace {}`,
   `:125`, hint `--allow-cross-workspace` / `jj op revert`).
4. Warn `"Undoing a push operation often leads to conflicted bookmarks."` + `"To avoid this, run `jj redo` now."`
   for push ops (`:136-141`); warn for `remove workspace` ops (`:143-153`).
5. `target_op_parent` = the unique parent:
   * none → `"Cannot undo root operation"` (`:160`);
   * several → `"Cannot undo a merge operation"` + hint `"Consider using `jj op restore` instead"` (`:160-165`).
6. If that parent's description is itself `"undo: restore to operation X"`, replace it with `X` (the
   "jump over old undo stacks" rule).
7. New view = `restore(target_op_parent.view)` with `DEFAULT_REVERT_WHAT`.
8. Prints `"Undid operation: "` + target summary and `"Restored to operation: "` + parent summary, then
   `tx.finish(ui, format!("{UNDO_OP_DESC_PREFIX}{}", target_op_parent.id().hex()))` where
   `UNDO_OP_DESC_PREFIX = "undo: restore to operation "` (`:55`, `:210`).

**[measured]** (`/tmp/opundo.ABCWBy`, commits A→B→C, then three undos):

```
Undid operation: 0c2f0cdcc26f … new empty commit
Restored to operation: 33a893456ce3 … new empty commit
Undid operation: 33a893456ce3 … new empty commit
Restored to operation: 58e8216a7331 … describe commit 72e2b5d7…
Undid operation: 58e8216a7331 … describe commit 72e2b5d7…
Restored to operation: f7a9c00fe47d … add workspace 'default'
```

### 5.3 `jj redo`

`cli/src/commands/redo.rs:52-196`, mirror image, `REDO_OP_DESC_PREFIX = "redo: restore to operation "` (`:50`):

* If current op's description is a redo-stack entry, jump to the operation it restored to.
* If the resulting target is **not** an undo operation → `Err(user_error("Nothing to redo"))` (`:129`).
* Cross-workspace refusal (`:137`) and "undo operation should have a single parent"
  (`internal_error("Undo operation should have a single parent")`, `:150`).
* The new view restores `target_op_parent.view()` — for an undo op, its parent is the state before the undo.
* **[measured]** after those three undos, `jj redo` created an operation described
  `redo: restore to operation 7751d3c6…` whose target is the **undo** operation `7751d3c6` (`undo: restore to
  operation f7a9c00f…`) — i.e. redo operates on the undo stack, not on the original operation directly.

### 5.4 `jj op revert <op>`

`cli/src/commands/operation/revert.rs:54-83` — "reverts an individual operation by applying the inverse of the
operation":

1. `target_op` = resolved op (default `@`).
2. Exactly one parent required:
   * `"Cannot revert root operation"` (`:63`),
   * `"Cannot revert a merge operation"` (`:64`).
   → **A reconcile op cannot be reverted** (`jj op revert @` on a reconcile op prints exactly that;
   **[measured]**), and `jj undo` of it fails with `"Cannot undo a merge operation"` instead.
3. `tx.repo_mut().merge(&load_at(target_op), &load_at(target_op_parent))` — i.e. it merges the *target* state
   onto the *parent* state (the "inverse" patch), then applies the same `--what` filtering.
4. Prints `"Reverted operation: "` + summary and commits with `format!("revert operation {}", hex)`.

Reverting an op whose parent is also a merge? Impossible — the parent must be unique, and the *target* is
non-merge, so `op revert` only works on linear ops.

---

## 6. `jj op abandon`

`cli/src/commands/operation/abandon.rs:51-160`. Doc comment (`:33-45`):

> "To discard old operation history, use `jj op abandon ..<operation ID>`. It will abandon the specified
> operation and all its ancestors. The descendants will be reparented onto the root operation." …
> "Previous versions of a change (or predecessors) are also discarded if they become unreachable from the
> operation history. The abandoned operations, commits, and other unreachable objects can later be garbage
> collected by using `jj util gc` command."

Mechanics:

1. Loads the **workspace only** ("Don't load the repo so that this command can be used to recover from
   corrupted repo state", `:58-59`), then works on `op_store` + `op_heads_store` directly.
2. `--at-op` is rejected: `cli_error("--at-op is not respected")` (`:63-66`) — "It doesn't make sense to create
   divergent operations that will be merged with the current head."
3. Parse `A..B` ranges; `..X` = root..X; `X..` = X..current heads. A bare `X` means "abandon `X`, reparent onto
   `X`'s unique parent" — with errors `"Cannot abandon the root operation"` (`:86`) and
   `"Cannot abandon a merge operation"` (`:88`) for that single-op form.
4. Refuses to abandon a **current head**: `"Cannot abandon the current operation {}"` (`:96-104`) with hint
   `"Run `jj undo` to revert the current operation, then use `jj op abandon`"`.
5. `op_walk::reparent_range(op_store, abandon_head_ops, current_head_ops, abandon_root_op)`
   (`lib/src/op_walk.rs:403-446`):
   * walks `root_ops..head_ops` (`walk_ancestors_range`),
   * for each op *in reverse*, clones its `op_store::Operation` and rewrites `parents` with
     `data.parents.iter().filter_map(|id| rewritten_ids.get(id).or_else(|| dest_once.take()))`: a parent that
     was itself reparented maps to its new id; otherwise **the first out-of-range parent becomes `dest_op`** and
     any *further* out-of-range parents are dropped (`:424-431`). It then **writes a new operation**
     (`op_store.write_operation`) — new content ⇒ new id,
   * returns `ReparentStats { new_head_ids, rewritten_count, unreachable_count }`.
6. Status output: `"Abandoned {} operations and reparented {} descendant operations."` (`:125-130`), or
   `"Nothing changed."` (`:122`). Then `op_heads_store.update_op_heads(old_head, new_head)` per head (`:133-140`).
7. Updates the workspace's recorded op id if it was one of the reparented heads; otherwise warns
   `"The working copy operation {} is not updated because it differs from the repo {}."` (`:144-150`).

**Storage growth:** abandoning does **not** delete anything. It *adds* operation objects (the rewritten
descendants). **[measured]** `/tmp/opaband2.Yre2z8`: 6 op files before, `Abandoned 3 operations and
reparented 3 descendant operations.`, 9 op files after, op log down to 3 ops + root. `jj util gc --expire now`
then pruned to 3 op files / 3 view files.

**Does GC ever remove abandoned ops?** Only if they are unreachable from the current head **and** older than
the `keep_newer` cutoff (§10) — `SimpleOpStore::gc` (`lib/src/simple_op_store.rs:274-357`) keeps everything
reachable from `head_ids` regardless of age, and keeps anything with mtime newer than `keep_newer`.

---

## 7. `--at-operation` and `--no-integrate-operation`

### 7.1 `--at-operation` / `--at-op`

Help text (`cli/src/cli_util.rs:3821-3845`):

> "Operation to load the repo at — … By default, Jujutsu loads the repo at the most recent operation, or at the
> merge of the divergent operations if any. … `--at-op=@` is pretty much the same as the default except that
> divergent operations will never be merged. … When loading the repo at an earlier operation, the working copy
> will be ignored, as if `--ignore-working-copy` had been specified. It is possible to run mutating commands
> when loading the repo at an earlier operation. Doing that is equivalent to having run concurrent commands
> starting at the earlier operation. There's rarely a reason to do that, but it is possible."

Mechanics:

* Resolution: `op_walk::resolve_op_for_load` (`lib/src/op_walk.rs:91-112`). Supported syntax:
  `@`, an unambiguous hex prefix, plus `-`/`+` suffixes for parent/child navigation
  (`resolve_single_op`, `lib/src/op_walk.rs:142-186`; `+` only works when head ops are known).
  Errors: `"The "{expr}" expression resolved to more than one operation"`, `"The "{0}" expression resolved to
  no operations"`, `"Operation ID "{0}" is not a valid hexadecimal prefix"`, `"No operation ID matching
  "{0}""`, `"Operation ID prefix "{0}" is ambiguous"` (`lib/src/op_walk.rs:65-89`).
* Read-only-ness: `is_at_head_operation()` is true only for `None | Some("@")` (`cli/src/cli_util.rs:784-793`);
  `is_working_copy_writable()` = `is_at_head_operation() && !ignore_working_copy` (`:779-782`);
  `load_from_workspace` passes that as `may_snapshot_working_copy` (`:559`).
  So at an old op: no snapshot, no wc update, and commands that need the wc fail with
  `"This command must be able to update the working copy."` + one of the hints `"Don't use
  --ignore-working-copy."` / `"Don't use --no-integrate-operation."` / `"Don't use --at-op."`
  (`cli/src/cli_util.rs:1299-1314`).
* Mutation at an old op is allowed and produces a **real fork** (no message at the time):
  **[measured]** `jj new -m side --at-op=$OLD` → `.jj/repo/op_heads/heads/` contains 2 files; the next
  command prints `Concurrent modification detected, resolving automatically.` and adds a reconcile op.
* `jj op abandon` and `jj util gc` refuse to run with `--at-op`
  (`"--at-op is not respected"`, `"Cannot garbage collect from a non-head operation"`).

### 7.2 `--no-integrate-operation`

Help text (`cli/src/cli_util.rs:3793-3808`):

> "Run the command as usual but don't integrate any operations — When this option is given, the operations will
> still be created as usual but they will not be integrated to the operation log. The working copy will also not
> be updated. The command will print the resulting operation ID. You can pass that to e.g. `jj --at-op` to
> inspect the resulting repo state, or you can pass it to `jj op restore` to restore the repo to that state. You
> can also pass the ID to `jj op integrate` to integrate the operation. Note that this does *not* prevent side
> effects outside the repo."

Implementation: `should_commit_transaction()` = `!no_integrate_operation` (`:424-426`);
`maybe_commit_transaction` (`:428-437`) always does `tx.write(description)` (which writes **view + operation +
index** and returns `UnpublishedOperation`) and then either `publish()` or `leave_unpublished()`
(`lib/src/transaction.rs:231`, `:239`). The `UnpublishedOperation` doc says exactly this (`:213-221`):
"A repo can be loaded at an unpublished Operation, but the Operation will not be visible in the op log if the
repo is loaded at head."

Printed messages:

* after a command: `"Operation left uncommitted because --no-integrate-operation was requested: {}"`
  (`cli/src/cli_util.rs:2437-2443`; the same message is also emitted from the `import git head` path at `:1431`);
* after a *snapshot* op: `"Snapshot operation left uncommitted because --no-integrate-operation was requested:
  {}"` (`:2234-2240`).

### 7.3 What exactly is left behind (important correction to a common belief)

**[measured]** (`/tmp/opnointeg.ZYQ4rj`): `jj --no-integrate-operation new -m unintegrated` prints the op id
(`8876804187aa`) and leaves **one** head marker (the *old* head `8a0f35ac…`), not two. The unintegrated
operation exists only in `op_store/operations` and as the recorded working-copy op; it is **not a head**, so
there is no divergence yet, and the next command does *not* print the concurrent-modification message.

Divergence appears when the unintegrated op is later *re-attached*:

```
$ jj describe -m base2                  # advances the head
$ jj op integrate 8876804187aa
Rebased 1 descendant commits onto commits rewritten by other operation.
The specified operation has been integrated with other existing operations.
$ jj op log
@    74fb4e630c1d …  reconcile divergent operations  args: jj op integrate 8876804187aa
├─╮
○ │  8876804187aa …  new empty commit   args: jj --no-integrate-operation new -m unintegrated
│ ○  411ec6e0ac66 …  describe commit …  args: jj describe -m base2
├─╯
○  8a0f35ac0708 …
```

`jj op integrate` (`cli/src/commands/operation/integrate.rs:38-75`) does
`update_op_heads(target_op.parent_ids(), target_op.id())` (adds a head for the op, removes its parents from the
head set) and then immediately runs `resolve_op_heads`, i.e. heals on the spot, printing
`"The specified operation has been integrated with other existing operations."` on success and
`"Running this command on an operation that is already in the operation log (`jj op log`) has no effect."`
(doc) / no output.

The other way to get a **sibling** op (rather than an unreachable one) is the working copy: after
`--no-integrate-operation`, `.jj/working_copy/checkout` still records the *unintegrated* op (or, if the wc was
not updated, an op that is no longer an ancestor of head). Then the freshness check reports
`SiblingOperation` and tells you to integrate (§9.4).

### 7.4 Interaction with `--ignore-working-copy`

* `--ignore-working-copy` alone: repo resolves at head **including** reconciliation; only snapshotting/updating
  is skipped. **[measured]** `jj op log --ignore-working-copy` on a 2-head repo printed
  `Concurrent modification detected, resolving automatically.` and created the reconcile op.
* `--at-op=<id>` implies ignoring the wc (`is_at_head_operation()` false) and skips reconciliation entirely
  (no merge of heads, single named op).
* `--at-op=@` is "at head" for wc purposes but still skips reconciliation → hard error if divergent.

---

## 8. Commit index vs operations

### 8.1 One index association per operation, written in the same transaction

`Transaction::write` (`lib/src/transaction.rs:135-174`) does, in order:

1. `base_repo.op_store().write_view(view.store_view())` → `ViewId` (`:153`),
2. `op_store.write_operation(&store_operation)` → `OperationId` (`:164-167`),
3. `base_repo.index_store().write_index(mut_index, &operation)` (`:170`) — "associates" the new op with the
   index state it produced.

`DefaultIndexStore` (`lib/src/default_index/store.rs`) layout (created in `init`, `:113`; dirs at `:166`,
`:171`, `:176`):

* `index/op_links/<opid hex>` — protobuf `SegmentControl { commit_segment_id,
  changed_path_start_commit_pos, changed_path_segment_ids }` (`associate_index_with_operation`, `:486-518`).
* `index/segments/<hex>` — immutable commit index segment files.
* `index/changed_paths/<hex>` — changed-path index segments.

`write_index` → `save_mutable_index` (`:458-483`) squashes the mutable segment with ancestors using a
size heuristic (`lib/src/default_index/mutable.rs:318-335`: squash while `2 * num_new_commits >=
parent.num_local_commits()`), saves a **new content-addressed segment file**, then writes the op link.
Old segment files are **not deleted** here (the only deletion path is `reinit`, `:127-155`).

### 8.2 Loading the index at an arbitrary operation

`IndexStore::get_index_at_op` (`lib/src/default_index/store.rs:521-562`):

1. Try `load_index_at_operation(op.id())` — read `op_links/<opid>`; missing file ⇒
2. `build_index_at_operation` (`:231`): walk ancestors until an op **with** an op link is found (logging
   `tracing::info!("scanning operations to index")`), take its index, then index the commits referenced by the
   unindexed ops (`op.all_referenced_commit_ids()` — i.e. `commit_predecessors` — plus
   `op.view().all_referenced_commit_ids()`), then write the new segments and op link.
3. Corrupt/old-format segment ⇒ `reinit()` + rebuild, with **user-visible** `eprintln!`s:
   * `"Found {kind} index format version {found_version}, expected version {expected_version}. Reindexing..."`
   * `"{err} (maybe the format has changed): {error}. Reindexing..."` (`:543-552`).

There is no "rebuilding index" banner for the *normal* missing-link case; it is silent (info-level tracing only).

Because `ReadonlyRepo::finish_load` always calls `get_index_at_op` (`lib/src/repo.rs:987-1000`), **every**
`--at-op` load and every reconcile potentially pays a partial reindex. The design intends it to be cheap:
"Pick the latest existing ancestor operation as the parent segment" and "There may be concurrent ops, so
revisit from the head. The parent op is usually shallow if existed." (`:239-256`).

Repo merging also merges the in-memory indexes: `self.index.merge_in(base)` / `merge_in(other)`
(`lib/src/repo.rs:2045-2048`).

### 8.3 `jj debug reindex`

`cli/src/commands/debug/reindex.rs:29-60`: resolves the op **without loading the repo** (comment: "The index
might have to be rebuilt while loading the repo"), then `DefaultIndexStore::reinit()` (clears `op_links/`,
legacy `operations/`, `segments/`, `changed_paths/`, `:127-155`) and `build_index_at_operation`, printing
`"Finished indexing {} commits."`. Non-default index ⇒ `"Cannot reindex indexes of type '{}'"`.

**[measured]** `/tmp/opaband2.Yre2z8` after gc: `links=8 segments=8` → `jj debug reindex` →
`Finished indexing 4 commits.` → `links=1 segments=1`. So `jj util gc` does **not** prune index files; only
`debug reindex` (or a format-change reinit) does.

---

## 9. Working-copy snapshots, staleness, `workspace update-stale`

### 9.1 When snapshot operations are created

At the start of every command that goes through `CommandHelper::workspace_helper`
(`cli/src/cli_util.rs:460-471` → `workspace_helper_with_stats` `:473-511` → `snapshot_impl` `:1326-1357`):

1. (colocated only) `import_git_head` — own op `"import git head"` (`:1412`, `:1441`);
2. `snapshot_working_copy` (`:2091-2276`);
3. (colocated only) `import_git_refs` — op `"import git refs"` (`:1482`).

A snapshot op is written **only if the tree changed**:
`if new_tree.tree_ids_and_labels() != wc_commit.tree().tree_ids_and_labels()` (`:2131`). It then either rewrites
the wc commit or, if the wc commit is immutable, creates a new commit on top and warns
`"The working-copy commit is immutable; a new commit has been created on top of it."` (`:2156-2162`);
rebases descendants (`"Rebased {num_rebased} descendant commits onto updated working copy."`, `:2181-2186`);
and commits with description **`"snapshot working copy"`** plus `tx.set_is_snapshot(true)` (`:2224-2228`).

`is_snapshot` is separate metadata (`core/src/op_store.rs:357-374`), surfaced to templates as `op.snapshot()`
and used by `templates.op_log` via `if(op.snapshot(), format_snapshot_operation(op), …)`
(`cli/src/config/templates.toml:266-274`); note `format_snapshot_operation(op) = format_operation(op)`
(`:462`), so today it only changes wording for template authors, not the default rendering.

At the **end** of a command, `WorkspaceCommandTransaction::finish` → `finish_transaction`
(`cli/src/cli_util.rs:2347-2460`) may create a *new* wc commit on top if the wc commit became immutable
(`"The working-copy commit became immutable; a new commit has been created on top of it."`, `:2386-2388`),
then publishes the op, then updates the working copy (`update_working_copy`, `:2280`), and finally prints the
`@` / `@-` summary lines.

### 9.2 Where the "current op of the working copy" lives

`.jj/working_copy/checkout` is protobuf `Checkout { bytes operation_id = 2; string workspace_name = 3; }`
(`lib/src/protos/local_working_copy.proto`, `message Checkout`) — **[measured]** the first bytes are `0x12 0x40`
(field 2, length 0x40 = 64) followed by the 64-byte op id.

`LocalWorkingCopy::operation_id()` returns it (`lib/src/local_working_copy.rs:2747-2749`); the
`LockedWorkingCopy` keeps `old_operation_id` from the moment the lock was taken (`:2961-2968`) and
`finish(op_id)` writes the new one (`lib/src/workspace.rs:492-503`).

So there are **two** op ids in play for every command: the repo's resolved op(s) and the wc's
`old_operation_id`. Their relationship *is* the staleness check.

### 9.3 Freshness classification

`WorkingCopyFreshness::check_stale` (`lib/src/working_copy.rs:345-401`), given the locked wc, the repo's
`wc_commit` (from the view) and the repo:

| condition | verdict | consequence |
|---|---|---|
| `wc.old_operation_id == repo.op_id()` | `Fresh` | proceed |
| repo op is the best common ancestor, wc op is a **descendant** | `Updated(wc_operation)` | **reload the repo at the wc's operation** and continue (this is the concurrent-snapshot race fix; `cli/tests/test_concurrent_operations.rs::test_concurrent_snapshot_wc_reloadable`) |
| wc op is an **ancestor** of repo op and the wc tree differs from the repo's `wc_commit` tree | `WorkingCopyStale` | error |
| wc op is an ancestor and trees match | `Fresh` (silent) | repo moved on but the checkout is still correct |
| neither is an ancestor of the other | `SiblingOperation` | "internal error" message with integrate hint |

Messages (`cli/src/cli_util.rs:3011-3080`):

```
The working copy is stale (not updated since operation {}).
Hint: Run `jj workspace update-stale` to update it.
See https://docs.jj-vcs.dev/latest/working-copy/#stale-working-copy for more information.
```
(`:3041-3050`; identical text in `cli/tests/test_workspaces.rs:742-743`)

```
Internal error: The repo was loaded at operation {}, which seems to be a sibling of the working copy's operation {}
Hint: Run `jj op integrate {}` to add the working copy's operation to the operation log.
```
(`:3053-3066`; `cli/tests/test_op_integrate_command.rs::test_integrate_sibling_operation`)

```
Could not read working copy's operation.
Hint: Run `jj workspace update-stale` to recover.
See https://docs.jj-vcs.dev/latest/working-copy/#stale-working-copy for more information.
```
(`:3067-3076`)

`snapshot.auto-update-stale` (default **false**, `cli/src/config/misc.toml:62`) makes the ordinary command run
the recovery automatically instead of erroring (`cli/src/cli_util.rs:500-511`; comment explains it must run
"up here, not at a lower level … to avoid recursive locking of the working copy").

### 9.4 `jj workspace update-stale` mechanics

`cmd_workspace_update_stale` (`cli/src/commands/workspace/update_stale.rs:29-40`) → `recover_stale_working_copy`
→ `recover_stale_working_copy_impl` (`cli/src/cli_util.rs:626-767`):

1. Read the wc's recorded op id and `load_operation` it.
2. Load the repo **at that op** and snapshot the current working copy on top of it (so local edits become a
   commit on the stale line). Comment at `:648-651`: "Snapshot the current working copy on top of the last known
   working-copy operation, then merge the divergent operations. The wc_commit_id of the merged repo wouldn't
   change because the old one wins, but it's probably fine if we picked the new wc_commit_id."
3. Re-load at (new) head — which **reconciles** the divergent ops (so the usual
   `Concurrent modification detected, resolving automatically.` appears here).
4. If still stale/sibling: (colocated) `reset git head` op if needed, then `update_stale_working_copy`
   (`:3081-3109`) which re-checks
   `if stale_commit.tree()… != locked_ws.locked_wc().old_tree()… { "Concurrent working copy operation. Try
   again." }`, checks out the desired commit, `locked_ws.finish(op_id)`, and prints
   `"Updated working copy to fresh commit {}"` (`:723`).
5. If no longer stale: `"Attempted recovery, but the working copy is not stale."` (`:678`).
6. If the wc's op cannot be read at all: `"Failed to read working copy's current operation; attempting
   recovery. Error message from read attempt: {e}"` (`:754`) then
   `create_and_check_out_recovery_commit`, which commits with the description
   (`cli/src/cli_util.rs:1544-1550`):

```
RECOVERY COMMIT FROM `jj workspace update-stale`

This commit contains changes that were written to the working copy by an
operation that was subsequently lost (or was at least unavailable when you ran
`jj workspace update-stale`). Because the operation was lost, we don't know
what the parent commits are supposed to be. That means that the diff compared
to the current parents may contain changes from multiple commits.
```

and prints `"Created and checked out recovery commit {}"`.

**[measured]** end-to-end (`/tmp/opstale2.oahx6c`, main + secondary workspace, main squashes so the secondary's
wc commit is rewritten):

```
$ cd secondary && jj st
Error: The working copy is stale (not updated since operation 688f349c7a39).
Hint: Run `jj workspace update-stale` to update it.
See https://docs.jj-vcs.dev/latest/working-copy/#stale-working-copy for more information.
[exit status: 1]

$ jj workspace update-stale
Concurrent modification detected, resolving automatically.
Rebased 1 descendant commits onto commits rewritten by other operation.
Working copy  (@) now at: ypupunom/2 a3a40833 (divergent) (empty) (no description set)
Parent commit (@-)      : xlpsltmq 78b76b2c (no description set)
Added 0 files, modified 1 files, removed 0 files
Updated working copy to fresh commit a3a40833f8d0
$ jj op log   # note the colocated "reset git head" op
92a0c528bf3b  reset git head
576c9ddbcd8d  reconcile divergent operations
b33ce6f04b79  squash commits into 7b9e500de3…
7a814e9b4245  snapshot working copy
4ff4654ee8b1  snapshot working copy
688f349c7a39  create initial working-copy commit in workspace secondary
```

Same transcript as `cli/tests/test_workspaces.rs:761-780` (which additionally shows the resurrected
`(divergent)` commit pair).

---

## 10. Growth, pruning, and performance notes

### 10.1 Growth is one op + one view + one index segment per state-changing command

* Every mutating command writes ≥1 operation; a snapshot doubles that (`snapshot working copy` + the command's
  own op) — **[measured]** 30 × `jj describe` produced **61** operations.
* Objects are tiny: **222–329 bytes** per operation, **57 bytes** per view at first, ~360 B/op total
  (**[measured]** 21 816 B for 61 ops).
* Views grow with the number of refs/workspaces, since each view is a full snapshot of all refs.
* Nothing is overwritten: `op_store` is append-only apart from `gc` (§10.2).
* The index duplicates growth: one `index/op_links/<opid>` per op, plus content-addressed segment files that
  are re-squashed repeatedly and whose older generations are never deleted. **[measured]** same repo: 62
  op_links, 62 segment files (84 B … 2 480 B), 25 563 B total index vs 21 816 B op store.

### 10.2 `jj util gc`

`cli/src/commands/util/gc.rs:33-70`:

* Doc: "To garbage-collect old operations and the commits/objects referenced by them, run
  `jj op abandon ..<some old operation>` before `jj util gc`."
* Refuses off-head: `"Cannot garbage collect from a non-head operation"` (`:51`).
* `--expire` accepts only `"now"`, else `"--expire only accepts 'now'"`; default cutoff is
  `SystemTime::now() - 14 days` (`:54-59`).
* Calls `repo.op_store().gc(&[repo.op_id()], keep_newer)` and (git feature) `git_backend.gc(index, keep_newer)`.

`SimpleOpStore::gc` (`lib/src/simple_op_store.rs:274-357`):

* Computes `reachable_ops` by DFS from `head_ids` and `reachable_views` from those ops; logs
  `tracing::info!(reachable_op_count, reachable_view_count, "collected reachable objects")`.
* Deletes any op/view file whose id is unreachable **and** whose mtime is `<= keep_newer`
  (`remove_file_if_not_new`, `:283-297`).
* Trait doc explains why the mtime rule exists (`core/src/op_store.rs:448-454`): "objects created after
  `keep_newer` will be preserved. This mitigates a risk of deleting new heads created concurrently by another
  process." (TOCTOU is acknowledged in a comment at `:288-290`.)
* Does **not** touch `op_heads/heads/*`, `index/`, or the working copy.

**[measured]** after `jj op abandon ..X` + `jj util gc --expire now`: ops 9 → 3, views 9 → 3, index
op_links/segments unchanged.

### 10.3 Read-only commands can write operation objects

`jj op log --op-diff` / `jj op show` reconstruct the parent repo with
`merge_operations(None, repo_loader, parent_ops, …, transaction_description: None, …)`
(`cli/src/commands/operation/log.rs:179-196`, `show.rs`), which writes **unpublished** merge operations (only for
merge ops, since `if parent_ops.len() > 1 { return Ok(()) }` follows at `log.rs:212-213`).
**[measured]** `/tmp/opdiv.svw9vx`: op file count 4 → 5 after `jj op log --op-diff`, the extra one being
`desc='merge 2 operations'` with `parents=2` and the *same* view id (views stayed at 4). These orphans are only
removed by `jj util gc`.

Other op-writing paths that are easy to forget: `import git head`, `import git refs`, `export git refs`,
`reset git head`, `forget workspace …`, `remove workspace …`, `add workspace '…'`,
`create initial working-copy commit in workspace …`, `snapshot working copy`
(`lib/src/workspace.rs:148`; `cli/src/commands/workspace/{add,forget,remove}.rs`;
`cli/src/cli_util.rs:703`, `:1412`, `:1482`, `:2227`).

### 10.4 Performance notes found in source/docs

* Op walking is lazy and timestamp-heuristic: `walk_ancestors` uses
  `dag_walk_async::topo_order_reverse_lazy` with `OperationByEndTime` ordering and the comment
  "Lazily load operations based on timestamp-based heuristic. This works so long as the operation history is
  mostly linear." (`lib/src/op_walk.rs:263-289`; ordering type at `:246-261`).
* `closest_common_ancestors` "Uses the end timestamp as a heuristic" and carries a TODO to make it a method on
  `OpStore` instead of relying on heuristics (`lib/src/op_walk.rs:357-380`).
* `find_child_ops` (for `op+`) is documented as slow: "This will be slow if the `root_op_id` is far away (or
  unreachable) from the `head_ops`." (`:226-230`).
* `merge_operations` had to be rewritten from recursion to an explicit stack because of stack overflow in
  deep criss-cross histories (`lib/src/repo.rs:871-877`, referencing PR #9586; regression test
  `lib/tests/test_merge_operations.rs`).
* `docs/operation-log.md` frames the design as "lock-free concurrency": "you can run concurrent `jj` commands
  without corrupting the repo, even if you run the commands on different machines that access the repo via a
  distributed file system (as long as the file system guarantees that a write is only visible once previous
  writes are visible)".
* There is **no op-log compaction** in 0.46.0: no `jj op simplify-parents`, no automatic pruning. The only
  tools are `jj op abandon` (manual history surgery) and `jj util gc` (2-week default age guard). The FAQ
  mentions polling the op log (`jj operation log --limit 1`) rather than watching files
  (`docs/FAQ.md:93`, `:629`), which is consistent with "the op log grows; don't watch it, query it".

---

## Appendix A — exact user-visible strings (verbatim, with source)

| string | source |
|---|---|
| `Concurrent modification detected, resolving automatically.` | `cli/src/cli_util.rs:813` |
| `Rebased {num_rebased} descendant commits onto commits rewritten by other operation.` | `cli/src/cli_util.rs:875` |
| `reconcile divergent operations` | `cli/src/cli_util.rs:816`, `lib/src/repo.rs:809`, `cli/src/commands/operation/integrate.rs:56` |
| `merge {} operations` | `lib/src/repo.rs:921` |
| `The "@" expression resolved to more than one operation` | `lib/src/op_walk.rs:69` |
| `Try specifying one of the operations by ID: {}` | `cli/src/command_error.rs:882` |
| `The "{0}" expression resolved to no operations` / `No operation ID matching "{0}"` / `Operation ID prefix "{0}" is ambiguous` / `Operation ID "{0}" is not a valid hexadecimal prefix` | `lib/src/op_walk.rs:76-87` |
| `Corrupt repository: no head operation` | `lib/src/simple_op_heads_store.rs:155` |
| `Failed to lock operation heads store` | `lib/src/op_heads_store.rs:42` |
| `Failed to lock working copy` | `lib/src/local_working_copy.rs:2762` |
| `Failed to take lock for Git import/export` | `cli/src/cli_util.rs:1020` |
| `Concurrent working copy operation. Try again.` | `cli/src/cli_util.rs:1526`, `:3092` |
| `The working copy is stale (not updated since operation {}).` | `cli/src/cli_util.rs:3043` |
| `Run `jj workspace update-stale` to update it.` + docs URL | `cli/src/cli_util.rs:3046-3049` |
| `The repo was loaded at operation {}, which seems to be a sibling of the working copy's operation {}` | `cli/src/cli_util.rs:3056` |
| `Run `jj op integrate {}` to add the working copy's operation to the operation log.` | `cli/src/cli_util.rs:3062` |
| `Could not read working copy's operation.` | `cli/src/cli_util.rs:3070` |
| `Attempted recovery, but the working copy is not stale.` | `cli/src/cli_util.rs:678` |
| `Updated working copy to fresh commit {}` | `cli/src/cli_util.rs:723` |
| `Failed to read working copy's current operation; attempting recovery. Error message from read attempt: {e}` | `cli/src/cli_util.rs:754` |
| `Created and checked out recovery commit {}` | `cli/src/cli_util.rs:1557` |
| `RECOVERY COMMIT FROM `jj workspace update-stale`` … | `cli/src/cli_util.rs:1544-1550` |
| `Snapshot operation left uncommitted because --no-integrate-operation was requested: {}` | `cli/src/cli_util.rs:2234` |
| `Operation left uncommitted because --no-integrate-operation was requested: {}` | `cli/src/cli_util.rs:2437` |
| `The specified operation has been integrated with other existing operations.` | `cli/src/commands/operation/integrate.rs:68` |
| `Cannot abandon the current operation {}` + `Run `jj undo` to revert the current operation, then use `jj op abandon`` | `cli/src/commands/operation/abandon.rs:96-104` |
| `Abandoned {} operations and reparented {} descendant operations.` / `Nothing changed.` | `abandon.rs:125-130`, `:122` |
| `Cannot abandon the root operation` / `Cannot abandon a merge operation` | `abandon.rs:86`, `:88` |
| `--at-op is not respected` | `abandon.rs:65` |
| `The working copy operation {} is not updated because it differs from the repo {}.` | `abandon.rs:144-150` |
| `Cannot revert root operation` / `Cannot revert a merge operation` | `revert.rs:63`, `:64` |
| `Cannot undo root operation` / `Cannot undo a merge operation` / `Consider using `jj op restore` instead` | `undo.rs:160`, `:162-163` |
| `Refusing to undo operation {} because it was performed in workspace {}` | `undo.rs:125` |
| `Refusing to redo operation {} because it was performed in workspace {}` | `redo.rs:137` |
| `Nothing to redo` | `redo.rs:129` |
| `Undoing a push operation often leads to conflicted bookmarks.` / `To avoid this, run `jj redo` now.` | `undo.rs:136-141` |
| `Undoing a workspace removal restores the workspace, but does not restore the workspace directory.` / `Run `jj workspace forget` then `jj workspace add` to recreate the directory.` | `undo.rs:143-153` |
| `Undid operation: ` / `Restored to operation: ` / `Reverted operation: ` | `undo.rs:200-205`, `restore.rs:62`, `revert.rs:81` |
| `undo: restore to operation ` / `redo: restore to operation ` | `undo.rs:55`, `redo.rs:50` |
| `restore to operation {}` / `revert operation {}` | `restore.rs:67`, `revert.rs:50-52` |
| `This command must be able to update the working copy.` | `cli/src/cli_util.rs:1310` |
| `Finished indexing {} commits.` / `Cannot reindex indexes of type '{}'` | `cli/src/commands/debug/reindex.rs:49`, `:54` |
| `Found {kind} index format version {}, expected version {}. Reindexing...` | `lib/src/default_index/store.rs:544-551` |
| `Cannot garbage collect from a non-head operation` / `--expire only accepts 'now'` | `cli/src/commands/util/gc.rs:51`, `:57` |
| `snapshot working copy` / `import git head` / `import git refs` / `reset git head` / `export git refs` | `cli/src/cli_util.rs:2227`, `:1412`, `:1482`, `:703`; `cli/src/commands/git/{import,export}.rs` |
| `add workspace '{}'` | `lib/src/workspace.rs:148` |
| `root()` (op log node for the root op) | `cli/src/config/templates.toml:467-469` (`format_root_operation`) |

## Appendix B — quick reference: who writes what

| action | files touched |
|---|---|
| any mutating command | `op_store/views/<hash>`, `op_store/operations/<hash>`, `index/segments/<hash>`, `index/op_links/<opid>`, then `op_heads/heads/<newid>` added and `<parentid>` removed (under `heads/lock`) |
| reconcile | same, plus the reconcile op has one parent per head; may also write intermediate `merge N operations` ops |
| snapshot | as above, with `description = "snapshot working copy"`, `is_snapshot = true` |
| `--no-integrate-operation` | everything except `publish()` ⇒ no `op_heads` change |
| `jj op abandon` | new `op_store/operations/*` for each reparented descendant; `op_heads/heads/*` swapped |
| `jj util gc` | deletes unreachable, old `op_store/{operations,views}/*` (and git objects) |
| `jj debug reindex` | deletes `index/op_links/*`, `index/segments/*`, `index/changed_paths/*`, rewrites them |
| `--ignore-working-copy` | repo may still be reconciled (op written); wc files untouched |

---

## Gaps & uncertainties

1. **Multi-head (≥3) reconcile op shapes.** I verified the 2-head case end-to-end and the *algorithm*
   (`closest_common_ancestors`, cached sub-merges, `merge N operations` default description) from source, but I
   did not empirically enumerate which intermediate unpublished ops are produced for 3+ heads. `lib/tests/
   test_view.rs::test_merge_three_operations` and `test_merge_operations.rs` pin the *semantics* (single final
   view, wc commit selection), not the intermediate object set.
2. **Exact write ordering / crash windows.** I describe the ordering from code (`add` then `remove`; view → op →
   index → publish). I did not strace a real interrupted command; the "interrupted update" behaviour is inferred
   from `lib/tests/test_bad_locking.rs::test_bad_locking_interrupted` plus the `NotFound`-tolerant
   `remove_op_head`.
3. **`jj util gc` vs stale `op_heads` markers.** `gc` never inspects or prunes `op_heads/heads/*`. I did not test
   what happens when a head marker survives but its op file was pruned (expected:
   `OpStoreError::ObjectNotFound` → `"Object … of type operation not found"`), so treat that as unverified.
4. **Index file garbage.** I measured that old segment files are not deleted (62 files for 61 ops) and that only
   `reinit` removes them, but I did not quantify steady-state disk usage on a large repo, nor test whether
   squashing eventually stabilises the *number* of *live* files (old generations keep accumulating regardless).
5. **`--what` corner cases.** `view_with_desired_portions_restored` restores `local_tags` under `repo` and
   `remote_views` under `remote-tracking`, while `git_refs`/`git_heads` are always kept current. I did not test
   `jj op restore --what=repo` on a repo with tags/remotes to confirm the user-visible effect.
6. **Cross-workspace undo/redo refusal** is new in 0.46.0 (CHANGELOG "Breaking changes"), and it keys off
   `OperationMetadata::workspace_name`. Ops created by the *reconcile* path set the workspace name of the
   invoking workspace (`merge_operations(..., Some(workspace_name), ...)`), so a reconcile op is "in" whichever
   workspace ran it — I did not test how that interacts with `--allow-cross-workspace`.
7. **Performance numbers** (op-log load time, reconcile cost on a big op log) are not measured here; only the
   algorithmic notes and heuristics from comments are reported.
8. **Version drift.** Everything here is pinned to `v0.46.0`. `main` is ~203 commits ahead and some of what this
   brief touches has certainly changed there (this review did not diff `main` against the tag beyond noting the
   distance, so do not assume any specific upstream change). Re-verify any claim against the tag before
   publishing the tutorial as version-specific.
9. **`op log --op-diff` orphan ops.** Measured once (4 → 5 op files, `merge 2 operations`). I did not test
   whether repeated `--op-diff` runs de-duplicate (they cannot, since `time.end` is part of the hash) or whether
   they can accumulate unboundedly — they can in principle until `jj util gc`.
