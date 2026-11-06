# R3 — The op log with multiple workspaces, Git interop, and multiple users/machines

Research artifact for the op-log tutorial. **Ground truth = the v0.46.0 release.**

| What | Path / ref |
| --- | --- |
| Official 0.46.0 binary | `/home/bogdan/work/google-jj/tutorial-oplog/tools/jj` (`jj 0.46.0-7d382314f9420b4b8d932245b49c99492c812b9f`) |
| Docs pinned to the release | `git -C /home/bogdan/work/google-jj/jj-upstream show v0.46.0:docs/...` |
| Source pinned to the release | `git -C ... show v0.46.0:cli/src/... , lib/src/...` |
| Local clone | `main` = `v0.46.0-203-gbdefa37df`; the `[Unreleased]` CHANGELOG block is **out of scope** |

Every empirical transcript below was produced with the 0.46.0 binary inside throwaway
`mktemp -d` directories (`/tmp/jjoplog.*`), including a bare `file://` remote and several
clones/workspaces. Nothing under `/home/bogdan/work/google-jj` was modified.

Notation: `⟨…⟩` marks an interpolated value; full 64-hex op ids are shortened to 12 chars and
commit hashes to 8 (`git show` citations are exact). `"double quotes"` = exact jj output.
**Empirical** = observed on the binary; **Source** = read from the pinned tree;
**Reasoning** = my inference from source, not documented behaviour.

---

## 0. Cheat sheet — every op description this note touches

| Op description (exact string, v0.46.0) | Produced by | Source |
| --- | --- | --- |
| `add workspace '⟨name⟩'` | repo/workspace init **and** every `jj workspace add` | `lib/src/workspace.rs:148` |
| `create initial working-copy commit in workspace ⟨name⟩` | `jj workspace add` | `cli/src/commands/workspace/add.rs:273` |
| `forget workspace ⟨name⟩` / `forget workspaces ⟨a⟩, ⟨b⟩` | `jj workspace forget` | `cli/src/commands/workspace/forget.rs:106,109` |
| `remove workspace ⟨a⟩` / `remove workspaces ⟨a⟩, ⟨b⟩` | `jj workspace remove` | `cli/src/commands/workspace/remove.rs:154` |
| `Renamed workspace '⟨old⟩' to '⟨new⟩'` | `jj workspace rename` | `cli/src/commands/workspace/rename.rs:75` |
| `snapshot working copy` | any snapshotting command | `cli/src/cli_util.rs:2227` |
| `import git refs` | `jj git import`, init, automatic import | `cli/src/commands/git/import.rs:58`, `cli_util.rs:1482`, `git/init.rs:324` |
| `import git head` | colocated HEAD moved; init | `cli_util.rs:1412,1441`, `git/init.rs:268` |
| `export git refs` | `jj git export` (non-colocated only) | `cli/src/commands/git/export.rs:50` |
| `fetch from git remote(s) ⟨names,⟩` | `jj git fetch` | `cli/src/commands/git/fetch.rs:257` |
| `fetch from git remote into empty repo` | `jj git clone` | `cli/src/commands/git/clone.rs:457` |
| `add git remote ⟨name⟩` | `jj git clone`, `jj git remote add` | `clone.rs:352`, `git/remote/add.rs:63` |
| `check out git remote's branch: ⟨name⟩` | `jj git clone` | `git/clone.rs:316` |
| `push ⟨names⟩ to git remote ⟨name⟩` (+ `all bookmarks/tags …`) | `jj git push` | `git/push.rs:272,639-650` |
| `reconcile divergent operations` | healing of divergent op heads | `cli_util.rs:816` |
| `undo: restore to operation ⟨full op id⟩` | `jj undo` | `cli/src/commands/undo.rs:55` |
| `restore to operation ⟨full op id⟩` | `jj op restore` | `cli/src/commands/operation/restore.rs` |
| `revert operation ⟨full op id⟩` | `jj op revert` | `cli/src/commands/operation/revert.rs:50` |

---

## 1. Multiple workspaces

### 1.1 What the three commands do

**Docs.** `docs/working-copy.md` (v0.46.0), section “Workspaces”:

> You can have multiple working copies backed by a single repo. Use `jj workspace add` to
> create a new working copy. The working copy will have a `.jj/` directory linked to the main
> repo. The working copy and the `.jj/` directory together is called a "workspace". Each
> workspace can have a different commit checked out.
>
> When you're done using a workspace, use `jj workspace forget` to make the repo forget about
> it. The workspace directory and files are left on disk.
>
> Use `jj workspace remove` to forget a workspace and remove its directory from disk. Tracked
> changes are snapshotted before the directory is removed, but ignored files in that directory
> are deleted. The main workspace cannot be removed.

`docs/glossary.md:253-262`:

> A workspace is a working copy and an associated repository. There can be multiple workspaces
> for a single repository. Each workspace has a `.jj/` directory, but the commits and
> **operations** will be stored in the initial workspace; the other workspaces will have
> pointers to the initial workspace. … This is what Git calls a "worktree".

**Command list in 0.46.0** (`cli/src/commands/workspace/mod.rs:44-58`) is larger than the docs'
prose suggests:

```
Add(WorkspaceAddArgs)
Forget(WorkspaceForgetArgs)
List(WorkspaceListArgs)
Remove(WorkspaceRemoveArgs)
Rename(WorkspaceRenameArgs)
Root(WorkspaceRootArgs)
UpdateStale(WorkspaceUpdateStaleArgs)
```

`jj workspace rename` is the *only* one of these whose name is user-visible in the op log in
Title case (`Renamed workspace 'a' to 'b'`), unlike the lower-case `add/forget/remove`.

**Source.** `jj workspace add` (`cli/src/commands/workspace/add.rs:180-278`):

1. rejects a duplicate name — `"Workspace named '⟨name⟩' already exists"` (`add.rs:135`)
   and an empty name — `"New workspace name cannot be empty"` (`add.rs:129`);
2. rejects a non-empty destination — `"Destination path exists and is not an empty directory"`
   (`add.rs:143`);
3. in a colocated repo (and `git.colocate = true`), runs `git worktree add --orphan` on a
   random branch `jj-worktree-⟨16 hex⟩` and prints `"Created Git worktree for the new
   workspace."` (`add.rs:161`, `lib/src/git.rs:1870`);
4. creates the workspace dir, writes `.jj/repo` (a text file holding the *relative* path to the
   main workspace's `.jj/repo`, `lib/src/workspace.rs:393-394`) and commits
   `add workspace '⟨name⟩'` (`lib/src/workspace.rs:148`);
5. prints `Created workspace in "⟨path⟩"` (`add.rs:179`) and, if the destination argument
   contained no path separator, the warning (`add.rs:187`):

   ```
   Workspace created inside current directory. If this was unintentional, delete the "⟨dest⟩"
   directory and run `jj workspace forget ⟨name⟩` to remove it.
   ```
6. copies (or clears) sparse patterns, then creates the working-copy commit and commits
   `create initial working-copy commit in workspace ⟨name⟩`.

`_ = `jj workspace forget` bundles all requested workspaces into **one** transaction “so that
e.g. undo correctly restores all of them at once” (`forget.rs:92-94`); the recorded path in the
workspace store is deliberately *not* deleted (`forget.rs:96-100`, fixed in 0.46.0 per
`CHANGELOG.md` §0.46.0 “`jj undo` of `jj workspace forget` now correctly preserves the
workspace's recorded path”, issue #9991). `jj workspace remove` snapshots each workspace
*before* deleting its directory (`remove.rs:126-146`) and refuses to remove the workspace that
contains the repo — `Cannot remove workspace '⟨name⟩' because it contains the repository`
(`remove.rs:109`) — or a directory now owned by another repo —
`Cannot remove workspace '⟨name⟩' because it belongs to another repository` (`remove.rs:118`).

### 1.2 Shared vs per-workspace state

**Empirical** — layout after `jj workspace add ../ws-b` in a colocated repo:

```
a1/.jj/                 # the *main* workspace
  repo/                 # <-- the whole repository
    store/  op_store/  op_heads/  index/  workspace_store/  submodule_store/
  working_copy/         # per-workspace working-copy state
ws-b/.jj/
  repo                  # small text file holding the relative path: "../../a1/.jj/repo"
  working_copy/
```

| State | Scope | Where | Evidence |
| --- | --- | --- | --- |
| commit objects / Git objects | shared | `.jj/repo/store` | `lib/src/repo.rs:230` |
| **operation & view objects** | **shared** | `.jj/repo/op_store/{operations,views}` | `lib/src/simple_op_store.rs:128,132` |
| **op-log heads** | **shared** | `.jj/repo/op_heads/heads/⟨op hex⟩` (empty files) | `lib/src/simple_op_heads_store.rs:77-90` |
| index (derived) | shared | `.jj/repo/index/{op_links,segments,changed_paths}` | `lib/src/default_index/store.rs:167-177` |
| workspace name → on-disk path | shared, **not** in the op log | `.jj/repo/workspace_store/index` (single file + lock) | `lib/src/simple_workspace_store.rs:81-83` |
| working-copy **files** | per workspace | the workspace root | — |
| working-copy commit **pointer** | per workspace, but stored in the *shared* view | `view.wc_commit_ids: map<string,bytes>` | `lib/src/protos/simple_op_store.proto` (`View.wc_commit_ids = 8`) |
| change IDs | shared (they live inside commit objects) | store | `docs/glossary.md:54-58` |
| last-checked-out op id, tree state, sparse patterns, `working_copy.lock` | per workspace | `.jj/working_copy/{checkout,tree_state,working_copy.lock}` | `lib/src/local_working_copy.rs:2760`, `lib/src/working_copy.rs:343-401` |

Two consequences worth teaching explicitly:

* The view object holds **one working-copy commit per workspace** (`wc_commit_ids`), which is why
  “workspace B moved workspace A's checkout” is representable at all — it is just another field
  in a view diff.
* The mapping name → *directory* is **not** in the operation log. It is a separate mutable file
  guarded by a `flock` (`simple_workspace_store.rs:121-127`). `jj workspace list` therefore shows
  paths that were recorded by whichever machine last wrote that file (see §4).

### 1.3 Do ops record who/where created them? Yes — three fields

`lib/src/protos/simple_op_store.proto` (v0.46.0), `OperationMetadata`:

```proto
message OperationMetadata {
  Timestamp start_time = 1;
  Timestamp end_time = 2;
  string description = 3;
  string hostname = 4;
  string username = 5;
  bool is_snapshot = 7;
  optional string workspace_name = 8;
  map<string, string> attributes = 6;
}
```

* `workspace_name` — set only when the transaction is created from a workspace context
  (`cli/src/cli_util.rs:816-823`, `start_repo_transaction(repo, workspace_name, args)`); the
  `add workspace '⟨name⟩'` op itself has **no** workspace name, because it is produced by
  `lib/src/workspace.rs` before the new workspace exists.
* `username`/`hostname` — from `operation.username` / `operation.hostname`, falling back to
  `$JJ_OP_USERNAME` / `$JJ_OP_HOSTNAME` (`docs/config.md:2449-2450`).
* `attributes` — free-form; jj puts the command line there
  (`attributes=args: jj workspace add ../ws-b`).

**Template surface** (`docs/templates.md:489-506`, `cli/src/operation_templater.rs:584-620`):

| keyword | rendering |
| --- | --- |
| `op.user()` | `"⟨username⟩@⟨hostname⟩"` |
| `op.workspace_name()` | `"⟨name⟩@"`, or empty string when the op wasn't created from a workspace |
| `op.attributes()`, `op.snapshot()`, `op.root()`, `op.description()`, `op.time()` | as named |

Default `jj op log` renders `id user workspace time` then the description
(`cli/src/config/templates.toml:438-449`), e.g.
`bfd800992873 Alice@laptop ws-b@ now, lasted 1 millisecond`.

CHANGELOG §0.40.0: “`jj op log` now includes the name of the workspace the operation was
created from.” (So tutorials targeting ≤0.39 do not have this column.)

### 1.4 Ops from a second workspace, seen from the first

**Empirical.** `jj op log` run in the main workspace after `jj workspace add ../ws-b` (colocated
repo; `JJ_OP_USERNAME=Alice JJ_OP_HOSTNAME=laptop` set for the second invocation, so the first op
still shows the machine's real identity):

```
@  bfd800992873 Alice@laptop ws-b@ now, lasted 1 millisecond
│  create initial working-copy commit in workspace ws-b
│  args: jj workspace add ../ws-b
○  2c8f70524943 Alice@laptop now, lasted 1 millisecond
│  add workspace 'ws-b'
○  3b4e34e1fb17 bogdan@nixos 3 seconds ago, lasted 2 milliseconds
│  add workspace 'default'
○  000000000000 root()
```

`jj op log` from *inside* ws-b shows exactly the same four ops — one log, shared. The
distinguishing information is the `ws-b@` / (empty) column and the `Alice@laptop` vs
`bogdan@nixos` identity, not the op-log topology.

`jj log` marks the per-workspace checkouts, and the `working_copies` template keyword lists all
workspaces sitting on a commit (`docs/templates.md`):

```
$ jj log                      $ jj log -T 'commit_id.short() ++ " " ++ working_copies ++ "\n"'
@  stvmrvkq … ws-b@  a99f028d        @  f90806e2537f a2-ws2@ default@
│ ○  zlkzlrtn … default@ b4c597bd     ◆  000000000000
```

### 1.5 Stale working copies

**Docs** (`docs/working-copy.md`, “Stale working copy”):

> If step 3 doesn't happen for some reason, the working copy is considered "stale". We can detect
> that because the working copy (`.jj/working_copy/`) keeps track of which operation it was last
> updated to. When the working copy is stale, use `jj workspace update-stale` to update the files
> in the working copy.
>
> A common reason that step 3 doesn't happen for a working copy is that you rewrote the commit
> from another workspace. When you modify workspace A's working-copy commit from workspace B,
> workspace A's working copy will become stale.

**Source** — `WorkingCopyFreshness::check_stale` (`lib/src/working_copy.rs:357-401`) has four
outcomes:

| outcome | condition |
| --- | --- |
| `Fresh` | wc's recorded op id == repo op id, **or** the recorded tree already equals the desired wc commit's tree (silent no-op — `working_copy.rs:388-392`) |
| `Updated(op)` | repo op is an ancestor of the wc's op → repo is reloaded at the wc's operation |
| `WorkingCopyStale` | wc's op is an ancestor of the repo op **and** the trees differ |
| `SiblingOperation` | neither is an ancestor of the other |

**Empirical** — the exact error (`cli/src/cli_util.rs:3040-3052`):

```
Error: The working copy is stale (not updated since operation 11d6dbc63ffa).
Hint: Run `jj workspace update-stale` to update it.
See https://docs.jj-vcs.dev/latest/working-copy/#stale-working-copy for more information.
```

Note the message names the *working copy's* last operation, not the blamed op.

Triggers, and what does **not** trigger it:

* **Does** trigger: another workspace (or any op) changes your workspace's `wc_commit_id` to a
  commit with a *different tree*. Reproduced by `jj op restore` from a second workspace
  (`restore to operation 56210ca13542`), after `jj squash`, `jj abandon`, `jj describe` had
  produced a stale-looking-but-identical tree.
* **Does not** trigger: another workspace merely *rewrites* your working-copy commit to the same
  tree (`jj describe`, `jj squash` out of the wc commit, `jj abandon` of an empty wc commit all
  produced “no changes” on the next `jj st`, `check_stale` → `Fresh`).
* **Does not** trigger: a plain remote change. `jj git fetch` only makes another workspace stale
  when the import actually rewrites that workspace's wc commit (see
  `docs/design/jj-converge-command.md:68-73`, which describes exactly the follow-on divergence:
  “Go back to w1 (which is now stale), modify some file on disk and take a snapshot (e.g. run
  `jj log`). This introduces divergence.”).

**`jj workspace update-stale`** (`cli/src/cli_util.rs:626-760`) does, in order:

1. load the operation the working copy is at, snapshot on top of **that** operation;
2. re-resolve the desired wc commit from the current head operation;
3. if still stale (or a sibling), optionally reset Git HEAD (`reset git head` op, colocated
   only), check out, and print
   `Added 0 files, modified 0 files, removed 1 files` + `Updated working copy to fresh commit ⟨short commit⟩`;
4. snapshot once more (Git refs may have changed).

**It creates no new operation in the normal case** — verified: the op log was byte-identical
before and after `jj workspace update-stale`; only `.jj/working_copy/checkout` advanced. Files on
disk are overwritten/deleted to match the recorded commit (my `bar` file disappeared,
`removed 1 files`).

Two failure/diagnostic paths matter:

* Op object gone (e.g. after GC):
  `Failed to read working copy's current operation; attempting recovery. Error message from read
  attempt: ⟨err⟩` → creates a commit whose description is
  `RECOVERY COMMIT FROM `jj workspace update-stale`` (`cli_util.rs:1544`) and prints
  `Created and checked out recovery commit ⟨short⟩`.
* Op object present but off the log (`jj op abandon` of the op a workspace sits at) →
  `SiblingOperation`:
  ```
  Internal error: The repo was loaded at operation d99c856e61cd, which seems to be a sibling of
  the working copy's operation 5734a5858abf
  Hint: Run `jj op integrate 5734a5858abf` to add the working copy's operation to the operation
  log.
  ```
  `jj op integrate ⟨op⟩` then answers
  `The specified operation has been integrated with other existing operations.` and creates a
  merge op `reconcile divergent operations` with both heads as parents:
  ```
  @    384a10ff82ac h1-ws@ reconcile divergent operations
  ├─╮
  ○ │  a56f80da67d5 h1-ws@ snapshot working copy
  │ ○  a53b7061892c default@ new empty commit
  ├─╯
  ```
  (`jj workspace update-stale` also resolves this case, without an op.)

Config: `snapshot.auto-update-stale` (default **`false`**, `cli/src/config-schema.json`) makes jj
run the recovery silently instead of erroring; `docs/config.md:2233-2245` recommends it “if you
have multiple workspaces and want to avoid manually updating each one”.

### 1.6 Two workspaces checking out the same change — no warning

**Empirical.** With `jj edit 'default@'` from the second workspace:

```
$ jj edit 'default@'
Working copy  (@) now at: vtwkyqrv f90806e2 commit X
Parent commit (@-)      : zzzzzzzz 00000000 (empty) (no description set)
Added 1 files, modified 0 files, removed 0 files
$ jj log
@  vtwkyqrv alice@example.com … a2-ws2@ default@ f90806e2
│  commit X
```

Both workspaces are simply recorded in `wc_commit_ids` pointing at the same commit. jj 0.46.0
prints **no** warning or conflict: there is no “already checked out elsewhere” diagnostic in
`cli/src` (grep for `already checked out` yields nothing). The two working copies then share one
mutable commit — an edit snapshotted in one immediately rewrites the commit both are standing on.
The only visible hint is the doubled ref decoration in `jj log` (`ws-a@ ws-b@`) or
`working_copies`.

### 1.7 Cross-workspace undo is refused (new in 0.46.0)

`CHANGELOG.md` §0.46.0: “`jj undo` and `jj redo` now refuse to undo/redo an operation that was
performed in another workspace.”

**Empirical** (`cli/src/commands/undo.rs:120-140`):

```
$ jj undo                      # run in h1-ws, last op was made in 'default'
Error: Refusing to undo operation 0135adc71b7e because it was performed in workspace default
Hint: Use `--allow-cross-workspace` to undo it anyway, or use `jj op revert` to revert a specific
operation
```

With the flag, `jj undo` restores the whole view (which includes *other* workspaces' wc commits)
and prints `Undid operation: … / Restored to operation: …`. Two further workspace-aware warnings
exist in `undo.rs:143-160`:

```
Warning: Undoing a workspace removal restores the workspace, but does not restore the workspace
directory.
Hint: Run `jj workspace forget` then `jj workspace add` to recreate the directory.
```

### 1.8 Workspaces in colocated repos are Git worktrees (0.46.0 feature)

`CHANGELOG.md` §0.46.0 release highlights: “Jujutsu can now colocate workspaces besides the
default one by creating Git worktrees. Use `jj workspace add --[no-]colocate` and the setting
`git.colocate` to control this.” (`git.colocate` default `true`, `cli/src/config-schema.json`).
The worktree is created with `git worktree add --orphan` on branch `jj-worktree-⟨16 hex⟩` and
HEAD is then nulled so a `git commit` there cannot materialise that branch
(`lib/src/git.rs:1867-1900`). The minimum git version therefore rose to 2.42.0
(`CHANGELOG.md` §0.46.0 breaking changes). `jj workspace forget` unlinks the worktree and prints
`Removed Git worktree for "⟨path⟩".`; `jj workspace remove` additionally prints
`Removed workspace directory "⟨path⟩".`

A forgotten-but-present workspace directory still works for read-only commands:

```
$ jj st            # inside a forgotten workspace
No working copy.
```

### 1.9 Other workspace-related messages (exact)

| Situation | Message |
| --- | --- |
| `jj workspace forget nope` | `Warning: No such workspace: nope` then `Nothing changed.` |
| `jj workspace rename` to same name | `Nothing changed.` |
| rename an untracked workspace | `Error: The current workspace '⟨name⟩' is not tracked in the repo.` |
| forget the current workspace | `Warning: The current workspace '⟨name⟩' no longer exists after this operation. The working copy was left untouched.` + `Hint: Restore to an operation that contains the workspace (e.g. `jj undo` or `jj redo`).` |
| `jj workspace root --name ⟨ws⟩` with a dead path | `Warning: Cannot access workspace path: ⟨path⟩` (path still printed; exit 0) |
| `jj workspace list` with a dead path | path is still listed (0.46.0 changelog: “no longer omit unreachable paths”) |

---

## 2. Git interop

### 2.1 `jj git init` — root op chains

**Empirical.** Colocated init on a Git repo that already has 2 commits:

```
$ jj git init .
Done importing changes from the underlying Git repo.
Initialized repo in "."
$ jj op log
@  b662d7f7d728 default@ import git head
○  3d917e771828 default@ import git refs
○  5fd6966c5249  add workspace 'default'
○  000000000000 root()
```

| Variant | Op chain after `root()` |
| --- | --- |
| `jj git init` (colocated, existing history) | `add workspace 'default'` → `import git refs` → `import git head` |
| `jj git init` (colocated, empty dir) | `add workspace 'default'` (nothing to import) |
| `jj git init --no-colocate` | `add workspace 'default'` (internal bare git, empty) |
| `jj git init --git-repo=⟨path⟩` (external, non-colocated) | `add workspace 'default'` → `import git refs` → `import git head` |

Sources: `cli/src/commands/git/init.rs:237-283`; the ref import is `init_git_refs`
(`init.rs:293-330`, description `"import git refs"`, message
`Done importing changes from the underlying Git repo.`), the HEAD import is
`tx.finish(ui, "import git head")` (`init.rs:268`), and `add workspace 'default'` comes from
`lib/src/workspace.rs:148`. In non-colocated mode the ref import is committed *before* HEAD so
that “all the reachable commits are indexed in chronological order” (`init.rs:249-251`).

Guard rails (`init.rs:229-236`):

```
Error: Did not create a jj repo because there is an existing Git repo in this directory.
Hint: To create a repo backed by the existing Git repo, run `jj git init --colocate` instead.
```
```
Warning: Initialized a new colocated jj repo inside a Git worktree.
Hint: To add a workspace to an existing repository, use `jj workspace add` instead.
```

### 2.2 `jj git clone` — a fresh op log, three ops

**Empirical** (`jj git clone file://$TMP/remote.git cloneA`):

```
@  9f1c1497e72f default@ check out git remote's branch: main  args: jj git clone file://… cloneA
○  ee3ef0280a89 default@ fetch from git remote into empty repo  args: jj git clone …
○  e9f15d67a0eb default@ add git remote origin                  args: jj git clone …
○  c0500e6e80d9  add workspace 'default'
○  000000000000 root()
```

Messages on stdout: `Fetching into new repo in "⟨path⟩"`, `bookmark: main@origin [new] tracked`,
`Setting the revset alias `trunk()` to `main@origin`.`

**The op log of a clone starts at `root()` and shares nothing with the source repo** — clone is
not “fetch an op log”, it is “create an empty jj repo, then fetch commits” (`clone.rs:330-340`
calls `Workspace::init_colocated_git` / `init_internal_git`). This is the cleanest demonstration
that the op log is local-only. `--no-colocate` produces the identical four/five ops, minus `.git`.

### 2.3 `jj git fetch` — one op (plus the pre-command import ops in colocated repos)

**Empirical, non-colocated clone:** exactly one op, no separate `import git refs`:

```
$ jj git fetch
bookmark: main@origin [updated] tracked
$ jj op log --limit 2 …
@  f10a9867ff55 fetch from git remote(s) origin
○  9f1c1497e72f check out git remote's branch: main
$ jj git fetch
Nothing changed.          # second fetch with nothing new: no op at all
```

Description construction (`fetch.rs:253-262`) is
`format!("fetch from git remote(s) {}", matching_remotes…join(","))` — note the literal
`(s)` and the comma-joined remote list (`fetch from git remote(s) origin,upstream`).

**Empirical, colocated clone** where the user had also (a) made a raw `git commit` (moving HEAD)
and (b) created an untracked file — a *single* `jj git fetch` produced **three** ops, because the
command first snapshots and re-imports:

```
@  e54869ec9774 default@ fetch from git remote(s) origin
○  ba14378f7307 default@ snapshot working copy
○  b72da0c4abdd default@ import git head          # "Reset the working copy parent to the new Git HEAD."
○  a7c69a197c75 default@ undo: restore to operation 0028f6f1…
```

So “which ops does a fetch create?” = *the fetch transaction itself is one op*, but in a colocated
repo the surrounding `workspace_helper` pass may contribute `import git head`, `snapshot working
copy`, and `import git refs` before it. That is why fetch interleaved with raw git activity looks
so noisy in `jj op log`.

The fetched refs are imported into the same transaction: `GitFetch::import_refs()` is awaited
before `tx.finish(...)` (`fetch.rs:247-262`; `lib/src/git.rs:3382-3410`).

### 2.4 `jj git push`

**Empirical:** `push bookmark feat to git remote origin`.

Description rules (`git/push.rs:620-652`, constant `TX_DESC_PUSH = "push "` at `push.rs:272`):

| invocation | description |
| --- | --- |
| one bookmark, one remote | `push bookmark ⟨name⟩ to git remote ⟨remote⟩` |
| several bookmarks | `push bookmarks ⟨a⟩, ⟨b⟩ to git remote ⟨name⟩` |
| tags | `…, tags ⟨t⟩ …` (kinds joined with `", "`) |
| several remotes | `… to git remotes ⟨r1⟩, ⟨r2⟩` |
| `--all` | `push all bookmarks/tags to ⟨remotes⟩` |
| `--tracked` | `push all tracked bookmarks/tags to ⟨remotes⟩` |
| `--deleted` | `push all deleted bookmarks/tags to ⟨remotes⟩` |

Push does **not** touch the remote's op log; it moves Git refs and the local view's remote-tracking
bookmarks (`lib/src/git.rs::push_refs`). `is_push_operation()` (`push.rs:1492`) matches
`description.starts_with("push ")` and is used by `jj undo` to warn:
`Undoing a push operation often leads to conflicted bookmarks.` +
`To avoid this, run `jj redo` now.`

### 2.5 Automatic import in colocated repos — there is no `git.auto-import` in 0.46.0

**Correction to the brief.** v0.46.0 has **no** `git.auto-import` config key. The full `git.*`
schema at the tag (`cli/src/config-schema.json`) contains: `abandon-unreachable-commits`,
`fetch`, `private-commits`, `push`, `record-synthetic-predecessors`, `sign-on-push`,
`track-default-bookmark-on-clone`, `write-change-id-header`, `executable-path`, `colocate`,
`object-hash`, and more — but nothing named `auto-import`/`auto_import`; `git grep -i auto-import`
over the whole pinned tree returns nothing. `docs/config.toml` (a sample config, not defaults)
does not mention it either. Automatic import is **unconditional** in colocated workspaces:

`docs/git-compatibility.md:134-142`:

> The Git repo and the Jujutsu workspace then share the same working copy. Jujutsu will import and
> export from and to the Git repo on every `jj` command automatically.

> You can undo the results of mutating `git` commands using `jj undo` and `jj op restore`. Inside
> `jj op log`, changes by `git` will be represented as an "import git refs" operation.

> One reason for this … is that `jj` commands will usually put the Git repo in a "detached HEAD"
> state, since in `jj` there is no concept of a "currently tracked branch".

Implementation: every writable-workspace command takes a `git_import_export_lock` and runs
`import_git_head` → `snapshot_working_copy` → `import_git_refs` → (command) →
`export_refs` + `try_reset_git_head` (`cli/src/cli_util.rs:1323-1360`, `2396-2410`).

**Empirical A — raw `git commit` while HEAD is detached** (the normal state; jj keeps HEAD
detached at the wc parent, so `refs/heads/main` does *not* move):

```
$ git commit -qam "made with plain git"     # HEAD is detached
$ jj st
Reset the working copy parent to the new Git HEAD.
The working copy has no changes.
$ jj op log --limit 1 …
@  5dc5100333a4 default@ import git head
```

**Empirical B — `git switch main` + `git commit`** (refs/heads/main moves → two ops, and a
conflicted bookmark if jj's local bookmark had also moved):

```
$ git checkout main && git commit …          # refs/heads/main: 8b3ce29 → 77cdffe
$ jj st
Reset the working copy parent to the new Git HEAD.
Done importing changes from the underlying Git repo.
$ jj op log --limit 2 …
@  60ac3047fd42 default@ import git refs
○  0e707c2d57c3 default@ import git head
$ jj log
@  … default@ c181ca16
│ ○  rytpsnxt … main* 77cdffeb git-side branch commit     # '*' = local bookmark not in sync with its tracked remote
```

`main*` comes from `CommitRef::format` (`cli/src/commit_templater.rs:1818-1830`): `??` = conflicted,
`*` = local ref whose tracked remote ref is at a different target.

There is no “Updated Git refs” message in 0.46.0. The import messages are:
`bookmark: ⟨name⟩@⟨remote⟩ [new|updated] [tracked|untracked]`, `tag: …`,
`Abandoned ⟨n⟩ commits that are no longer reachable.`,
`Updated ⟨n⟩ rewritten commits.`, `Done importing changes from the underlying Git repo.`
(`cli/src/git_util.rs:298-317`, `cli_util.rs:1486-1490`).

### 2.6 Manual `jj git import` / `jj git export`

* Colocated: both are deliberately **no-ops** unless you add `--ignore-working-copy`.
  `jj git import` → `No import needed in colocated workspaces.` (`git/import.rs:48`);
  `jj git export` → `No export needed in colocated workspaces.` (`git/export.rs:44`).
  Both flags’ help text says the import/export “happens automatically” and that
  `--ignore-working-copy` forces it.
* Non-colocated with an external Git repo (`jj git init --git-repo=…`): nothing is automatic.
  **Empirical** — after a raw `git commit` in the external repo, `jj st` shows *no* new commit
  (`Parent commit (@-): … ext commit 1`), and only `jj git import` brings it in:
  ```
  $ jj git import
  bookmark: master@git [updated] tracked
  → op: import git refs
  ```
  `jj git export` symmetrically creates `export git refs`.
* Non-colocated with the *internal* bare Git repo: `import`/`export` operate on
  `.jj/repo/store/git`, which only jj writes, so they normally report `Nothing changed.`

### 2.7 `jj git import; jj undo; jj git import` — the answer depends on colocation

This is the most surprising interop/op-log interaction, and it is explained by two pieces of
source.

**(1) `jj undo` never restores the view's `git_refs` / `git_heads`.**
`cli/src/commands/operation/mod.rs:95-115`:

```rust
jj_lib::op_store::View {
    head_ids: repo_source.head_ids.clone(),
    local_bookmarks: repo_source.local_bookmarks.clone(),
    local_tags: repo_source.local_tags.clone(),
    remote_views: remote_source.remote_views.clone(),
    git_refs: current_view.git_refs.clone(),        // <-- always the *current* value
    git_heads: current_view.git_heads.clone(),      // <-- always the *current* value
    wc_commit_ids: repo_source.wc_commit_ids.clone(),
}
```

The default `--what` is `[Repo, RemoteTracking]` (`operation/mod.rs:87`). The old `GitTracking`
variant was removed in Sept 2023 by commit `f397349db` (“cli: make non-colocated repo also preserve
git_refs on op undo/restore”), whose message states: “Now we have a separate map for 'git' tracking
remote, we can always preserve the last imported/exported git_refs. The option to restore
git-tracking refs has been removed.” An earlier fix, `864515394` (“undo: preserve git-tracking refs
in colocated repos by default”, 2023-05), explains the rationale still visible in today's code: in
a colocated repo the automatic export relies on `git_refs` matching the real Git refs, so undo
must leave them alone and let export/import reconcile.

**(2) In a colocated repo, the undo transaction itself exports**, so `.git` is rolled back too:
`finish_transaction` runs `try_reset_git_head` + `export_refs` for every transaction when the
working copy is shared with Git (`cli_util.rs:2396-2410`). `diff_refs_to_export` even documents
the case (`lib/src/git.rs:1577-1580`):

```rust
// There are two situations where remote refs get out of sync:
// 1. `jj bookmark forget --include-remotes`
// 2. `jj op revert`/`restore` in colocated repo
```

**Empirical, colocated clone** (remote had a new commit):

```
$ jj git fetch                       → op: fetch from git remote(s) origin
    .git: refs/heads/main = 09381b5, refs/remotes/origin/main = 09381b5
$ jj undo                            → op: undo: restore to operation 0028f6f1…
    .git: refs/heads/main = eaf1322, refs/remotes/origin/main = eaf1322   # rolled back by export
$ jj --ignore-working-copy git import
Nothing changed.                     # no op created; nothing to re-import
```

**Empirical, non-colocated external Git repo:** the second import **does** re-import:

```
$ jj git import      → op: import git refs   (master@git → ext commit 2)
$ jj undo            → op: undo: restore to operation 1e721fe5…
$ jj git import
bookmark: master@git [updated] tracked       # again
→ op: import git refs   (new op c4319e07182a)
```

**Source-derived reason:** import diffs the *actual* Git refs against the view's remote-tracking
bookmarks as well as `git_refs` (`diff_refs_to_import`, `lib/src/git.rs:904-1019`, which walks
`actual.local_branches()`, `actual.remote_branches()`, `actual.tags()`). `jj undo` restored the
remote-tracking bookmark `master@git` to the older target while the external Git repo still has
the newer commit, so the next import re-materialises it — and that write produces a fresh op.
In the colocated case the export step had already pushed the restored target back into `.git`, so
there was nothing left to re-import.

**Tutorial takeaway:** `jj undo` after a fetch restores *your* view (bookmarks, remote-tracking
bookmarks, wc commits) but the underlying Git repository is only reconciled by export/import.
The `git_refs` snapshot is deliberately out of undo's scope, so “undo then import” is *not* a
faithful rewind: in a colocated repo nothing reappears, in an external-Git repo the imported refs
reappear as a new op.

### 2.8 Colocation status ops

`jj git colocation enable` / `disable` create ops `set git head to working copy parent`
(`git/colocation.rs:349`) and `remove git head reference` (`colocation.rs:364`), plus
`Workspace is already colocated with Git.` / `Workspace is already not colocated with Git.` when
there is nothing to do (no op).

---

## 3. Divergence by design (two clones, one remote)

### 3.1 The op log is purely local — documented and structural

Documented:

* `docs/operation-log.md:1-30` — the log lives in the repo, describes “the current working-copy
  commit in each workspace”, is used by `jj undo`/`jj op revert`/`jj op restore`.
* `docs/technical/concurrency.md:69-90` — “The most important piece in the lock-free design is the
  'operation log'. That is what allows us to detect and merge divergent operations.” … “When a
  command starts, it loads the repo at the latest operation … When the operation completes, it is
  written with the start operation as parent.”
* `docs/technical/concurrency.md:116-125` — storage: content-addressed op/view objects plus a
  *directory of head files*: “We do that by keeping the ID of the current head(s) as a file in a
  directory. The ID is the name of the file; it has no contents.”

Structural: op and view objects live only in `.jj/repo/op_store` and head markers only in
`.jj/repo/op_heads/heads` (`lib/src/simple_op_store.rs`, `lib/src/simple_op_heads_store.rs`).
`jj git push`/`fetch`/`clone` move *commits and refs* (`lib/src/git.rs`), and there is no code
path that reads or writes a foreign op log. Nothing in `docs/` mentions transporting operations.
Consequently:

* **change IDs converge** — they travel inside the Git commit object (`git.write-change-id-header`,
  default `true`; `lib/src/git.rs` writes the `change-id` header), so two clones derive the same
  change ID from the same commit;
* **operation IDs never converge** — different view + different metadata (time, user, host,
  workspace) hash to different op IDs, and each repo keeps its own head files.

### 3.2 Empirical: two clones of one bare remote

`d1` and `d2` cloned from the same `file://` bare repo, each made one independent commit
(`ksymtxytwzwm` and `ymlwsptwprvy`), `d1` pushed a new bookmark `feat`, `d2` fetched.

```
# d1, before push
@  f8e0692c382e create bookmark feat pointing to commit babb2faa…
○  494bd5fa3913 describe commit 2419071c…
○  94d060a0eb8b snapshot working copy
○  89e50c866328 check out git remote's branch: main
○  1ea6db932bf8 fetch from git remote into empty repo
○  75d708ff1cbe add git remote origin
○  2ce3fd72418c add workspace 'default'
○  000000000000

# d2, same shape, but every id differs (2ce3fd72… vs 792ccdad…)
@  1e3150af1c54 describe commit 18b53b60…
○  075ed988eed7 snapshot working copy
○  c654b29eb84b check out git remote's branch: main
…
```

After `d1: jj git push -b feat` (op `push bookmark feat to git remote origin`) and
`d2: jj git fetch` (op `fetch from git remote(s) origin`):

```
# d2
$ jj log -r 'feat@origin' --no-graph -T 'change_id.short() ++ " " ++ commit_id.short() ++ "\n"'
ksymtxytwzwm babb2faa9d69          # identical change id AND commit id to d1's
$ jj op log --limit 1 -T 'self.id()'
42222488f69a375c…                 # d1's head:
                                  # 86f648eb051c23d5…
```

**Same change, same commit, different op-log head, and no op in common after the fetch.** The
histories *look* similar (both have `fetch from git remote into empty repo` etc.) only because both
started from the same template of commands; the op objects are unrelated. That is the “divergence
by design” story in one experiment.

### 3.3 What `jj undo` after a `jj git fetch` undoes

Restores the view fields `head_ids`, `local_bookmarks`, `local_tags`, `remote_views`,
`wc_commit_ids` from the target operation; leaves `git_refs`/`git_heads` as they are
(§2.7). Practically, in a colocated repo:

* `main@origin` goes back to the pre-fetch target (`jj bookmark list` shows
  `@origin (behind by 1 commits): …` again),
* any bookmark conflict introduced by the fetch is undone,
* `.git` refs are re-exported to match (so `git log main` also rewinds),
* the fetched *commits* stay in the object store (they are unreachable but present until GC), and
* a later `jj git import`/`jj git fetch` will bring the refs back (import only in the
  external-Git case; fetch always).

Docs covering the mechanism rather than the recipe: `docs/technical/concurrency.md` §“Merging
divergent operations” (3-way merge of views, conflicts recorded as `RefTarget` conflicts),
`docs/glossary.md` (`colocated workspaces`), `docs/guides/divergence.md` (divergent *changes*,
the symptom users actually see). There is no FAQ/glossary entry that says “operation logs are not
shared between clones” in so many words; the closest are the two concurrency docs above plus
`docs/operation-log.md`'s “as long as the file system guarantees that a write is only visible once
previous writes are visible”.

---

## 4. One repo directory shared by two users/machines (NFS, SSHFS, Dropbox…)

### 4.1 What the docs actually say

Only three places in the v0.46.0 docs discuss this; quoting them in full because they set the
boundary between supported and not:

`docs/operation-log.md:31-40` (**documented**):

> One benefit of the operation log (and the reason for its creation) is that it allows lock-free
> concurrency -- you can run concurrent `jj` commands without corrupting the repo, even if you run
> the commands on different machines that access the repo via a distributed file system (as long
> as the file system guarantees that a write is only visible once previous writes are visible).
> When you run a `jj` command, it will start by loading the repo at the latest operation. It will
> not see any changes written by concurrent commands. If there are conflicts, you will be
> informed of them by subsequent `jj st` and/or `jj log` commands.

`docs/technical/concurrency.md:40-63` (**documented**):

> ### Syncing with `rsync`, NFS, Dropbox, etc
>
> Jujutsu's lock-free concurrency means that it's possible to update copies of the clone on
> different machines and then let `rsync` (or Dropbox, or NFS, etc.) merge them. The working copy
> may mismatch what's supposed to be checked out, but no changes to the repo will be lost (added
> commits, moved bookmarks, etc.). If conflicting changes were made, they will appear as
> conflicts. …
>
> Note that, for now, there are known bugs in this area. Most notably, with the Git backend,
> repository corruption is possible because the backend is not entirely lock-free
> (issue #2193). If that corruption occurs, there is an easy recovery path: `jj debug reindex`.
>
> Moreover, such use of Jujutsu is not currently thoroughly tested, especially in the context of
> colocated repositories. While the contents of commits should be safe, concurrent modification of
> a repository from different computers might conceivably lose some bookmark pointers. Note that,
> unlike in pure Git, losing a bookmark pointer does not lead to losing commits.

`docs/git-compatibility.md:193-196` (**documented**), as a colocation disadvantage:

> Colocated workspaces are less resilient to concurrency issues if you share the repo using an NFS
> filesystem or Dropbox. In general, such use of Jujutsu is not currently thoroughly tested.

Also relevant: `docs/design/jj-converge-command.md:83-87` (**documented**, Google-internal
context): “At Google, snapshotting operations happen concurrently on different machines (e.g. two
terminals, or more commonly, a terminal and an IDE). … Google's backend does not hold locks while
snapshotting because it's a distributed filesystem, so locking would be slow.”

**There is no doc statement that sharing one repo directory between two *users* is supported, and
no recommendation to “clone per user” or “use workspaces instead”.** The docs frame sharing as
“copies of the clone … merged by rsync/Dropbox/NFS”, i.e. *eventual* merging of two divergent
histories, not concurrent use of one directory. `grep -i 'nfs|sshfs|dropbox|rsync|network
filesystem|shared'` over `docs/` returns only the three files above.

### 4.2 What the code actually does when two machines write concurrently

Everything below is **source-derived reasoning** pinned to v0.46.0, cross-checked with the
concurrency experiments in §4.3.

**(a) Op-head updates are non-atomic by design, and healing is on the read path.**
`SimpleOpHeadsStore::update_op_heads` (`lib/src/simple_op_heads_store.rs:112-134`) writes a *new*
empty file `heads/⟨new op hex⟩` and then unlinks the old head file(s). `remove_op_head` explicitly
tolerates a missing file (`simple_op_heads_store.rs:84-101`):

```rust
// It's fine if the old head was not found. It probably means
// that we're on a distributed file system where the locking
// doesn't work. We'll probably end up with two current
// heads. We'll detect that next time we load the view.
```

`resolve_op_heads` (`lib/src/op_heads_store.rs:85-190`) does exactly that on every load: if
`get_op_heads()` returns >1 id, it takes a lock, re-reads, drops ancestor heads, and if ≥2 heads
remain it calls the resolver, which in the CLI prints
`Concurrent modification detected, resolving automatically.` and commits a **merge operation**
`reconcile divergent operations` with all surviving heads as parents (`cli_util.rs:807-830`).
A 3-way view merge can produce conflicted bookmarks/`@git` refs, and if commits were rewritten it
adds `Rebased ⟨n⟩ descendant commits onto commits rewritten by other operation.`

**(b) The lock is advisory and explicitly best-effort.** `OpHeadsStore::lock`'s doc comment
(`lib/src/op_heads_store.rs:68-73`): “It is not needed for correctness; implementations are free
to return a type that doesn't hold a lock.” On Unix it is `flock(LOCK_EX)` on
`.jj/repo/op_heads/heads/lock` (`lib/src/lock/unix.rs:34-105`), and that file even has NFS-specific
handling:

```rust
Err(rustix::io::Errno::STALE) => {
    // The file handle is stale.
    // This can happen when using NFS,
    // likely caused by a remote deletion of the lockfile.
    // Treat this like a normal lockfile deletion and retry.
    continue;
}
```

So: on a filesystem where `flock` is not honoured across hosts (many NFS setups), the two hosts
still *append* heads safely (each writes its own file), but both may also try to unlink the same
old head; the loser's unlink is tolerated. The result is exactly two heads and one extra
`reconcile divergent operations` op — not corruption. What is *not* safe is the further assumption
that `view` objects and commit objects are content-addressed and immutable — that part holds
everywhere.

**(c) The working copy of a shared workspace is genuinely racy and only guarded by a per-workspace
`flock` + a tree comparison.** `LocalWorkingCopy::start_mutation` locks
`.jj/working_copy/working_copy.lock` (`lib/src/local_working_copy.rs:2759-2766`, error text
`Failed to lock working copy`) and re-reads `checkout_state` after taking it. Then
`update_stale_working_copy` guards against a lost race with
`if stale_commit.tree() != locked_ws.locked_wc().old_tree() { return Err(user_error("Concurrent
working copy operation. Try again.")) }` (`cli_util.rs:3089-3093`). Two machines checking out into
the *same* directory therefore interleave whole-file writes with no coordination beyond that lock;
if `flock` doesn't work over the network, the tree comparison is the only detector — and it
detects only *some* races (it compares the recorded tree, not the bytes on disk). This is the
“working-copy races in the SAME workspace” hazard, and it is not mitigated by the op log at all.

**(d) The workspace store is a single mutable file with a read-modify-write under `flock`.**
`SimpleWorkspaceStore` keeps `.jj/repo/workspace_store/index` (a serialized `Workspaces` map,
`lib/src/simple_workspace_store.rs:79-83`, `protos/simple_workspace_store.proto`). Writes go
through a `NamedTempFile` + rename (atomic per write, `simple_workspace_store.rs:134-152`), but the
whole map is rewritten on every `add`/`forget`/`rename` under `FileLock` (`:158-222`). Where
`flock` is a no-op across hosts, two concurrent `jj workspace add`s can lose one entry
(last-writer-wins) — **source-derived reasoning**, and the reason `jj workspace list` on machine A
may not show machine B's workspace.

**(e) The index is derived and self-healing.** `.jj/repo/index/op_links/⟨op hex⟩` maps an operation
to an index segment; segment files are content-addressed and there is **no lock** anywhere in
`lib/src/default_index/store.rs`. Missing links simply trigger a rebuild
(`build_index_at_operation` walks ancestors until it finds an existing link, `store.rs:231-260`),
and `reinit()` docs say “If raced, new segment file will be created by the other process.”
(`store.rs:136-138`). So index races cost time, not data; `jj debug reindex` / `jj util gc` are the
escape hatches (the latter is recommended in `docs/git-compatibility.md` for slow imports).

**(f) The one documented data-loss risk is the Git backend**, not the op log:
`docs/technical/concurrency.md:56-60` — “with the Git backend, repository corruption is possible
because the backend is not entirely lock-free (issue #2193)”, recovered with `jj debug reindex`.

### 4.3 Empirical: what concurrency actually looks like

**Deterministic divergence via `--at-op`** (same directory, two ops from one base):

```
$ jj --at-op=b8250af502eb new -m "branch A"
$ jj --at-op=b8250af502eb new -m "branch B"
$ ls .jj/repo/op_heads/heads        → 0f5de97b92f9  10d8cfec0137
$ jj op log
Concurrent modification detected, resolving automatically.
@    8e98dbebecc1 reconcile divergent operations parents=0f5de97b92f9,10d8cfec0137
├─╮
○ │  0f5de97b92f9 new empty commit parents=b8250af502eb
│ ○  10d8cfec0137 new empty commit parents=b8250af502eb
├─╯
○  b8250af502eb add workspace 'default' parents=000000000000
○  000000000000
```

**Genuinely concurrent processes, same workspace, same directory** (3 rounds of two simultaneous
`jj describe` — this is the shape of “two machines on one NFS mount” minus caching):

```
round 1: A → wc commit 73c71257 "conc A1"     B → wc commit c7703bf1 "conc B1"    (both succeed)
round 2: A → 6dff8144 "conc A2"               B → 91b24907 "conc B2"              (both succeed)
round 3: A → "Working copy (@) now at: vwoprpvn/0 b0a655f2 (divergent) (empty) conc A3"
             B → "Concurrent modification detected, resolving automatically." then
                 "Working copy (@) now at: vwoprpvn/0 ec7eb35b (divergent) (empty) conc B3"
$ jj op log
Concurrent modification detected, resolving automatically.
@    3203aa3d1188 reconcile divergent operations parents=0b84698cec58,62380d6dc44d
├─╮
○ │  0b84698cec58 describe commit 6dff8144…      # same parent op, same change id
│ ○  62380d6dc44d describe commit 6dff8144…
├─╯
○    105d78fba8ff reconcile divergent operations parents=346d6a28d00a,f070c9573f5b
…
```

Observations: no error, no corruption; both processes' ops survive; the *change* ends up divergent
(`(divergent)`, `vwoprpvn/0`, `vwoprpvn/1`) because both rewrote the same change from the same base.
This is precisely the failure mode a two-machine single-directory setup will produce constantly —
silently, with conflict markers only in `jj log`, never a scary error.

### 4.4 Verdict

| Question | Answer | Status |
| --- | --- | --- |
| Is sharing one repo dir between machines/processes *supported*? | Not claimed anywhere in the docs. It is described as *tolerated* for the repo (op log heals divergence) and explicitly “not thoroughly tested”, with Git-backend corruption a known bug. | documented (§4.1) |
| Does the op log survive concurrent writes from two hosts? | Yes, by design: head files are added-then-removed, extra heads are merged into a `reconcile divergent operations` op on the next load; a failed unlink is explicitly tolerated. | source + empirical (§4.2a, §4.3) |
| Can ops be *lost*? | Not by the head-file protocol. Real risk is elsewhere: Git-backend object writes (docs), and last-writer-wins on the workspace-store index. | docs + reasoning |
| Is one *workspace* shared by two machines safe? | No. Working-copy file writes are only guarded by `flock` on a file whose NFS semantics jj itself distrusts; checkouts delete/overwrite files; the “Concurrent working copy operation. Try again.” check is a narrow race detector. | reasoning + empirical (§4.2c) |
| Does the index need care? | No; derived and rebuilt. | source (§4.2e) |
| What should a tutorial recommend? | One workspace (working-copy directory) per machine/user, sharing the same `.jj/repo` only if you accept the caveats — or, more conventionally, one *clone* per user and exchange commits through a remote, since the op log is not transportable anyway. | reasoning, consistent with docs' framing |

---

## 5. Workspaces vs clones, specifically for the op log

| | Two workspaces of one repo | Two clones |
| --- | --- | --- |
| op log | **one shared log** (`docs/glossary.md:257-259`) | **two private logs, never reconciled** (§3) |
| change / commit objects | shared, one store | duplicated; exchanged by fetch/push |
| change IDs | trivially identical (same objects) | identical only if the commit was transferred (change-id header travels with the commit) |
| `jj op log` shows | every op of every workspace, tagged `⟨ws⟩@` | only local ops |
| `jj undo` | undoes *any* workspace's last op (0.46.0 asks for `--allow-cross-workspace` when it was another workspace's) | only your own history |
| concurrent work | view-level merge, conflicted bookmarks | ref-level merge at fetch time, `@origin` bookmarks |
| documented use case | “you can run a slow build or test in one workspace while you're continuing to write code in another” (`working-copy.md`), “Each workspace also has own sparse patterns” (`workspace/mod.rs`) | normal distributed-VCS workflow; clones on different machines |

Documented guidance that touches the choice:

* `docs/working-copy.md` §Workspaces — the only stated motivation is parallel local work
  (build/test while developing); plus `jj workspace root --name` for scripting.
* `docs/glossary.md:253-262` — “This is what Git calls a ‘worktree’”; commits **and operations**
  live in the initial workspace.
* `docs/technical/concurrency.md:40-63` — cross-machine work is expected to go through
  *copies* + rsync/Dropbox/NFS merging, with the caveats in §4.1; the op log is what makes that
  merging safe.
* `docs/design/jj-converge-command.md:68-73` — explicitly names “mutating two workspaces” as a
  source of change divergence (stale w1 + snapshot), which is the workspace analogue of the clone
  divergence in §3.
* `CHANGELOG.md` §0.46.0 — colocated child workspaces exist now (`--[no-]colocate`), and
  `jj undo`/`jj redo` became workspace-aware, i.e. the project is actively pushing the
  “workspaces are a first-class, shared-log concept” line.

Rule of thumb consistent with all of the above: **workspaces = one user, one machine, one op log,
parallel checkouts; clones = many users/machines, N independent op logs, convergence only at the
commit/ref level.**

---

## Gaps & uncertainties

1. **`git.auto-import` does not exist in 0.46.0** — the brief assumed a config key with a default
   value to pin. I verified its absence in `cli/src/config-schema.json`, `docs/config.md`,
   `docs/config.toml` and by `git grep -i auto-import` over the tag. Automatic import in colocated
   repos is unconditional; `jj git import` there is a no-op unless `--ignore-working-copy`. If the
   tutorial wants to mention the historical key, that needs a separate archaeology pass
   (pre-0.20 releases); I did not find the string in this repo's history.
2. **No documented message “Updated Git refs”** — 0.46.0 prints
   `bookmark: ⟨name⟩@⟨remote⟩ [new|updated] [tracked|untracked]` and
   `Done importing changes from the underlying Git repo.` I quote those instead.
3. **`jj op integrate`** is new-ish (0.46 era) and only lightly documented; I captured its exact
   message and its “merge two heads” effect empirically, but did not find prose docs for it in
   `docs/` at the tag (it appears in `jj op --help` and in the stale-workspace hint).
4. **`jj workspace update-stale` creating no op** is empirical (a single run, op log compared
   before/after). The code path supports it (`update_stale_working_copy` only finishes the working
   copy at the *existing* op id, `cli_util.rs:3085-3113`), but the “reset git head” sub-op in
   colocated repos *can* appear when HEAD has to be rewritten — I did not force that case.
5. **NFS/flock semantics** are asserted from the code's own comments and from general flock
   behaviour; I did not test on an actual NFS/SSHFS mount. All §4.2 statements about "where flock
   is a no-op across hosts" are labeled reasoning and should stay that way in the tutorial.
6. **Workspace-store last-writer-wins** is reasoning from `simple_workspace_store.rs`
   (read-modify-write of one file under `flock` + temp-file rename). I did not reproduce a lost
   update; doing so needs two hosts or an `LD_PRELOAD` that stubs `flock`.
7. **`jj undo` of a push/fetch in a *non-colocated* repo with the internal bare Git store** was not
   tested end-to-end (only the external-Git-repo variant in §2.7). The code path is shared with
   `jj git export`, so I expect `undo` there to leave `.jj/repo/store/git` untouched until an
   explicit `jj git export`, but that is inference.
8. **Op-log growth/GC (`jj util gc`, `jj op abandon` of old ops)** is out of scope here; note only
   that `jj op abandon` of an op a workspace sits at produces the `SiblingOperation` state in §1.5.
9. **Multi-user attribution nuance:** `operation.username`/`hostname` are recorded per op, so a
   shared repo directory does give you “who did what” in `jj op log`; but nothing enforces
   distinct usernames, and `attributes` (the command line) can reveal local paths. I did not
   explore `operation.hostname`-based config `--when.hostnames` (`docs/config.md:2580-2588`) beyond
   noting it exists.
10. **`docs/FAQ.md` “Should I colocate my repository?”** was only skimmed; if the tutorial wants a
    quote about git-interop risk, read that section end-to-end (`docs/FAQ.md:110+`).
