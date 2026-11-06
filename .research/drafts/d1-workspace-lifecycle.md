# DRAFT d1 — Lesson 04 additions: the workspace lifecycle (4.8 … 4.18)

Append after exercise 4.7 and before "## Verify" in
`lessons/04-workspaces-one-log.md`. Every quoted message below came from a
real run on jj 0.46.0 (commands were replayed after a scripted 4.1–4.7, so
they work on the messy post-4.7 sandbox: divergent change, both
workspaces on one change). Ids, timestamps and absolute paths vary: they are
written `⟨…⟩`.

Integration notes for the maintainer (nothing was changed in the tree):

- The new exercises create sibling directories `../scratch`, `../spare`,
  `../scratch-2`, `../review`. `reset-sandbox.sh` only removes `sandbox`,
  `side-task`, `colleague`, so add `scratch scratch-2 spare review` to its
  `rm -rf` line (otherwise `jj workspace add ../scratch` fails with
  "Destination path exists and is not an empty directory" on a second pass).
- Exercises 4.16 and 4.17 are destructive to old op-log objects
  (`jj util gc --expire now`, as in lesson 02), so keep them last.
- The `ls`/`git worktree list` outputs are for the colocated sandbox.

---

## Theory (new section, put after "Stale working copies" or just before
## "Cross-workspace undo")

### The workspace lifecycle, seen from the op log

A workspace has **three** pieces of identity, and they live in three
different places. Almost every surprise below is one of them disagreeing
with another:

| Piece | Lives in | Written by an op? |
|---|---|---|
| the *name* and its working-copy commit | the shared **view** (`wc_commit_ids`) | yes — undoable |
| the *name → directory* map | `.jj/repo/workspace_store/` | **no** — a mutable file |
| the directory's own idea of "who am I" (name + last op) | `.jj/working_copy/` in that directory | no — per directory |
| (colocated only) the Git worktree link | `.git` file in the workspace + `.git/worktrees/⟨dir⟩/` in the main repo | no — Git state |

**`jj workspace forget`** only edits the first row (plus unlinking the Git
worktree). It writes one op, `forget workspace ⟨name⟩` (several names are
bundled in one op: `forget workspaces a, b`, so one `jj undo` restores them
all). The directory and its files stay. The working-copy commit stops
being a working-copy commit: if it is *discardable* — **empty and
undescribed** — and nothing else references it (no other workspace, local
bookmark or tag), forget **abandons** it; otherwise it simply becomes an
ordinary head and stays in `jj log`. (`MutableRepo::remove_workspace` →
`maybe_abandon_wc_commit`, `lib/src/repo.rs`; `is_discardable`,
`lib/src/commit_builder.rs`.) `forget` does **not** snapshot first —
unlike `remove` — so files you never snapshotted are only on disk.

The path is deliberately *kept* in the workspace store
(`cli/src/commands/workspace/forget.rs`, comment above the `remove_workspace`
loop), so that `jj undo` can point the restored workspace back at its
directory (the 0.46 fix mentioned above). `jj workspace remove`
(`remove.rs`) *does* call `workspace_store.forget(…)`, so undoing a remove
gives you a workspace with no path at all.

**`jj workspace rename`** (`rename.rs`) is the odd one: it can only rename
the workspace you are standing in, and it has to update all of the rows
at once — view (`tx.repo_mut().rename_workspace`), workspace store
(`workspace_store.rename`) and the directory's own state
(`locked_wc().rename_workspace`, implemented in
`lib/src/local_working_copy.rs`). Only the first is in the op, so only the
first is undone by `jj undo`. The transaction is started *before* the rename,
so the op is tagged with the **old** name — which matters for undo.

**Freshness uses names.** A directory identifies itself with the workspace
*name* stored in its own `.jj/working_copy`. If the view stops containing
that name, the directory says `No working copy.`; if the view contains it
but points at a different commit (because the name was re-used for another
directory), the directory is merely *stale*.

### When the op a workspace points at is gone

`WorkingCopyFreshness::check_stale` (`lib/src/working_copy.rs`) compares the
op recorded in the directory with the repo head. Two things can go wrong
after `jj op abandon`:

| Situation | Error | Recovery | New op? |
|---|---|---|---|
| abandoned op still exists in the op store, but is no longer an ancestor/descendant of the head (a *sibling*) | `Internal error: The repo was loaded at operation …, which seems to be a sibling of the working copy's operation …` (exit status 255) | `jj op integrate ⟨op⟩` **or** `jj workspace update-stale` | integrate: `reconcile divergent operations`; update-stale (clean wc): none |
| the op object was deleted by `jj util gc` | `Error: Could not read working copy's operation.` | `jj workspace update-stale` → recovery commit | `recovery commit` (+ `snapshot working copy`) |

(Error texts: `cli/src/command_error.rs`; recovery:
`cli/src/cli_util.rs`, `recover_stale_working_copy_impl` and
`create_and_check_out_recovery_commit`.)

`snapshot.auto-update-stale = true` makes the *snapshot step of any
command* catch `StaleWorkingCopy` and run the same recovery
(`cli/src/cli_util.rs`, in `workspace_helper_with_stats`). It is
update-stale on autopilot — same ops, same output — not a different
mechanism.

---

## Exercises

All exercises start in `sandbox/` unless a `cd` says otherwise. Use bash.

**4.8** Forget two workspaces from a third — and look at what happens to
their commits and directories:

```console
jj workspace add ../scratch           # leave it empty
jj workspace add ../spare
cd ../spare
echo 'spare notes' > notes.txt
jj describe -m "spare work"           # (this also snapshots notes.txt)
cd ../sandbox
SCRATCH=$(jj log -r 'scratch@' --no-graph -T 'commit_id.short(12)')
SPARE=$(jj log -r 'spare@' --no-graph -T 'commit_id.short(12)')
jj workspace forget scratch spare
# Removed Git worktree for "⟨…/scratch⟩".
# Removed Git worktree for "⟨…/spare⟩".
jj op log -n 1                        # ONE op: forget workspaces scratch, spare
jj op show @                          # the view diff, see below
jj workspace list                     # both names are gone
jj log -r "$SCRATCH | $SPARE"         # scratch's empty commit is (hidden); spare's is still a normal visible head
jj log -r 'scratch@'                  # Error: Workspace `scratch` doesn't have a working-copy commit
git worktree list                     # only sandbox (and side-task) — the two worktree links are gone
ls -A ../scratch ../spare             # …but the directories and notes.txt are untouched
```

`jj op show @` prints (verbatim shape):

```text
Changed commits:
○  - ⟨change⟩/0 ⟨id⟩ (hidden) (empty) (no description set)

Changed working copy scratch@:
+ (absent)
- ⟨change⟩/0 ⟨id⟩ (hidden) (empty) (no description set)
Changed working copy spare@:
+ (absent)
- ⟨change⟩ ⟨id⟩ spare work
```

Two different fates for the two commits, from one command. `scratch`'s
working-copy commit was empty *and* undescribed → discardable → the forget
op abandoned it (the `Changed commits:` line). `spare`'s has a description
and a file → it survives as an anonymous head; only the pointer is gone.

Now stand inside a forgotten directory:

```console
cd ../spare
jj st                                 # No working copy.   (exit 0)
jj log -n 2                           # works — the repo is fine, and the log is shared
jj new                                # Error: Workspace `spare` doesn't have a working-copy commit
jj file list                          # the same error: anything that needs a working copy refuses
jj workspace forget                   # Warning: No such workspace: spare   /   Nothing changed.
```

**4.9** Undo the forget: what state is the directory in?

```console
echo late > ../spare/late.txt         # a file created WHILE the workspace was forgotten
jj undo
# Undid operation: ⟨id⟩ (⟨ts⟩) forget workspaces scratch, spare
# Restored to operation: ⟨id⟩ (⟨ts⟩) describe commit ⟨hex⟩
jj workspace list                     # both are back, with their ../scratch ../spare paths
git worktree list                     # …but the Git worktrees are NOT back
cd ../spare
jj st                                 # fresh, not stale — and it snapshots late.txt:
# Working copy changes:
# A late.txt
# A notes.txt
jj log -r 'spare@' --no-graph -T 'commit_id.short(12) ++ "\n"'   # a NEW id: the snapshot rewrote the commit
cd ../scratch
jj st                                 # The working copy has no changes.  (same commit id as before: it came back from "hidden")
git status                            # fatal: not a git repository …
```

Why it is fine: the view (name → commit) is restored by the op; the
path was never deleted from the workspace store; and the directory's own
`.jj/working_copy` still says "workspace spare, last op ⟨x⟩" — the restored
view has the same wc commit and tree, so freshness is `Fresh`.
Why the Git side is not: `unlink_git_worktree`
(`cli/src/git_util.rs`) removed the `.git` link in the workspace and the
`.git/worktrees/…` admin dir; that is Git state, outside every op, so `undo`
cannot bring it back (and no warning says so — only `jj undo` of a
*remove* gets one). The restored workspace is a plain, non-colocated jj
workspace. To get the worktree back, `jj workspace forget` + `jj workspace add`
again (see 4.11).

**4.10** Forget yourself:

```console
cd ../scratch
jj workspace forget
# Warning: The current workspace 'scratch' no longer exists after this operation. The working copy was left untouched.
# Hint: Restore to an operation that contains the workspace (e.g. `jj undo` or `jj redo`).
# Removed Git worktree …  (only if the worktree link existed)
jj op log -n 1                        # tagged scratch@ — the op was made *by* scratch
jj st                                 # No working copy.
jj undo                               # allowed: the op's workspace is the one you stand in
# Undid operation: ⟨id⟩ … forget workspace scratch
# Working copy  (@) now at: ⟨change⟩ ⟨id⟩ (empty) (no description set)
jj workspace list
```

Contrast with 4.8: there the forget was made by `default@`, so `jj undo`
from `default` was allowed; had you tried `jj undo` from a *third*
workspace you would have hit the 0.46 refusal from 4.6.

**4.11** Forget, delete the directory, then undo — the dead path. Forget
does not snapshot, so first make sure the work is in a commit:

```console
cd ../spare && jj st && cd ../sandbox        # snapshot: notes.txt/late.txt are now in the commit
SP=$(jj log -r 'spare@' --no-graph -T 'commit_id.short(12)')
BEFORE=$(jj op log -n 1 --no-graph -T 'id.short(12)')
jj workspace forget spare
rm -rf ../spare                              # directory gone
jj op restore "$BEFORE"                      # (jj undo works the same)
jj workspace list                            # spare is back, path ../spare still listed
jj workspace root --name spare
# Warning: Cannot access workspace path: ⟨…/spare⟩
# ⟨…/spare⟩                                  (the path is still printed; exit 0)
ls ../spare                                  # ls: cannot access '../spare'
```

The view and the store both say "spare lives in ../spare"; the disk
disagrees. jj cannot recreate the directory for you, but the hint from
`jj undo` of a removal (4.15) is the recipe:

```console
jj workspace forget spare
jj workspace add ../spare -r "$SP"           # new empty child of the saved commit
ls -A ../spare                               # .git .jj README.md late.txt notes.txt src   (files come back from the commit)
```

If you had **not** snapshotted before `rm -rf`, those files are gone for
good: forget never looked at them.

**4.12** Re-using a workspace name:

```console
echo "scratch draft" > ../scratch/draft.txt     # never snapshotted
jj workspace forget scratch
jj workspace add ../scratch                     # Error: Destination path exists and is not an empty directory
jj workspace add ../scratch-2 --name scratch    # fine: same name, new directory
jj workspace list                               # scratch: ../scratch-2 …   (the store entry was overwritten)
cd ../scratch                                   # the OLD directory
jj st
# Error: The working copy is stale (not updated since operation ⟨id⟩).
# Hint: Run `jj workspace update-stale` to update it.
jj workspace root                               # …it still believes it is ⟨…/scratch⟩
echo unsaved > unsaved.txt
jj workspace update-stale
# Concurrent modification detected, resolving automatically.
# Working copy  (@) now at: ⟨change⟩ ⟨id⟩ (empty) (no description set)
# Added 2 files, modified 0 files, removed 2 files
# Updated working copy to fresh commit ⟨id⟩
ls -A                                           # .jj README.md src — draft.txt and unsaved.txt are gone from disk…
jj log -r 'files("draft.txt")' --no-graph -T 'commit_id.short(12) ++ "\n"'   # …but both live in a commit
jj op log -n 3                                  # … reconcile divergent operations / create initial working-copy commit … / add workspace 'scratch'
```

The view is keyed by name, and the old directory carries the name in its
own state. Re-using the name makes the old directory a *second claimant* of
the same workspace: it sees a different wc commit for its name and a different
tree → `WorkingCopyStale`. `update-stale` (it snapshots before it overwrites)
saved `draft.txt` and `unsaved.txt` into a commit, then checked out the new
workspace's commit. Now **two directories answer to `scratch`** (check
`jj workspace root` in each) — delete the old one: `cd ..; rm -rf scratch`.
(The inverse hazard of the store comment in `forget.rs`: "overwritten if the
name is reused".)

**4.13** Rename:

```console
jj workspace add ../review && cd ../review
WC=$(jj log -r '@' --no-graph -T 'commit_id.short(12)')
jj workspace rename default           # Error: Failed to rename a workspace
                                      # Caused by: Workspace default already exists
jj workspace rename review            # Nothing changed.
jj workspace rename inspect           # silent
jj op log -n 1
# @  ⟨id⟩ ⟨user@host⟩ review@ ⟨ts⟩
# │  Renamed workspace 'review' to 'inspect'
# │  args: jj workspace rename inspect
jj op show
# Changed working copy inspect@:
# + ⟨change⟩ ⟨id⟩ (empty) (no description set)
# - (absent)
# Changed working copy review@:
# + (absent)
# - ⟨change⟩ ⟨id⟩ (empty) (no description set)
jj workspace list                     # inspect: . ⟨change⟩ …  (same change & commit id as before)
jj log -r 'review@'                   # Error: Workspace `review` doesn't have a working-copy commit
git worktree list                     # still lists …/review — the Git worktree is not renamed
```

A rename is a view diff with the same commit under a new key: no commit is
created or rewritten (`$WC` is unchanged). Note the title-case description
(already in the theory), and that the op is tagged with the **old** name,
`review@`, because the transaction started before the rename. `rename`
takes only the *new* name — there is no way to rename another workspace, and
running it in `sandbox/` would rename `default`.

**4.14** The undo trap — an op tagged with a name that no longer exists:

```console
jj undo
# Error: Refusing to undo operation ⟨id⟩ because it was performed in workspace review
# Hint: Use `--allow-cross-workspace` to undo it anyway, or use `jj op revert` to revert a specific operation
```

You are standing in `inspect`, but the op says `review`: the 0.46
cross-workspace guard (`cli/src/commands/undo.rs`) compares the op's
recorded name with your *current* name, so a workspace cannot undo its own
rename without the flag.

```console
jj undo --allow-cross-workspace
# Undid operation: ⟨id⟩ (⟨ts⟩) Renamed workspace 'review' to 'inspect'
# Restored to operation: ⟨id⟩ (⟨ts⟩) create initial working-copy commit in workspace review
# Warning: The current workspace 'inspect' no longer exists after this operation. The working copy was left untouched.
# Hint: Restore to an operation that contains the workspace (e.g. `jj undo` or `jj redo`).
jj workspace list                     # review:  ⟨change⟩ …   ← no path any more!
jj st                                 # No working copy.
```

The view went back to `review`, but the other two rows did not: this
directory's `.jj/working_copy` still says `inspect`, and the store entry was
renamed to `inspect` (so `review` has no path). Redo puts the view back in
agreement with the other two:

```console
jj redo
# Restored to operation: ⟨id⟩ (⟨ts⟩) Renamed workspace 'review' to 'inspect'
# Working copy  (@) now at: ⟨change⟩ ⟨id⟩ (empty) (no description set)
jj workspace list                     # inspect: . …
jj st                                 # The working copy has no changes.
```

(`redo` needs no flag: the undo op itself was tagged `inspect@`.) Moral:
undoing a rename is safe only if you also fix up the store and the directory
by hand — prefer renaming back with `jj workspace rename review`.

**4.15** `forget` versus `remove` — what undo can and cannot give back:

```console
cd ../sandbox
jj workspace remove inspect
# Removed Git worktree for "⟨…/review⟩".
# Removed workspace directory "⟨…/review⟩".
ls -d ../review                       # ls: cannot access '../review': No such file or directory
jj op log -n 1                        # remove workspace inspect
jj undo
# Warning: Undoing a workspace removal restores the workspace, but does not restore the workspace directory.
# Hint: Run `jj workspace forget` then `jj workspace add` to recreate the directory.
# Undid operation: ⟨id⟩ (⟨ts⟩) remove workspace inspect
jj workspace list                     # inspect:  ⟨change⟩ …     (no path)
jj workspace root --name inspect      # Error: Workspace has no recorded path: inspect
jj workspace forget inspect           # tidy up
```

`remove` snapshots, deletes the directory, **and** drops the store entry;
`forget` leaves the last two alone. That is exactly why `undo` of a
`forget` (4.9) lands you back on a working directory while `undo` of a
`remove` (here) only brings back a name. The warning is keyed on the op
description starting with `remove workspace` (`undo.rs`); there is no
equivalent warning for forget, which is why 4.9's missing Git worktree is
silent.

**4.16** `jj op abandon` of the op a workspace sits at — the sibling error:

```console
cd ../spare
echo s1 > s1.txt
jj st                                 # snapshot op, made by spare@ — spare's checkout now points at it
B=$(jj op log -n 1 --no-graph -T 'id.short(12)')
cd ../sandbox
jj describe -m "main work"            # a later op by default@, a child of $B
jj op abandon "$B"
# Abandoned 1 operations and reparented 1 descendant operations.
cd ../spare
jj st
# Internal error: The repo was loaded at operation ⟨id⟩, which seems to be a sibling of the working copy's operation ⟨B⟩
# Hint: Run `jj op integrate ⟨B⟩` to add the working copy's operation to the operation log.
echo $?                               # 255 — "internal error", not a user error
```

The head is now `describe'` (rebased onto the parent of `$B`); spare's
recorded op `$B` still exists in the store but is neither an ancestor nor a
descendant of the head: `check_stale` finds the common ancestor is
neither of them → `SiblingOperation`. Even `jj op log` refuses in this
directory. Two repairs. First, integrate:

```console
jj op integrate "$B"
# The specified operation has been integrated with other existing operations.
jj op log -n 4
# @    ⟨id⟩ ⟨user@host⟩ spare@ ⟨ts⟩
# ├─╮  reconcile divergent operations
# │ │  args: jj op integrate ⟨B⟩
# ○ │  ⟨B⟩ … spare@ … snapshot working copy
# │ ○  ⟨id⟩ … default@ … describe commit ⟨hex⟩
# ├─╯
# ○  …
jj st                                 # works; s1.txt is still in the working copy
```

"Abandon" turned out reversible: the op object was never deleted, and
integrating re-attaches it as a second head, merged by a
`reconcile divergent operations` op (lesson 05). Second, `update-stale`,
repeated for a fresh abandon:

```console
echo s2 > s2.txt && jj st             # snapshot op B2
B2=$(jj op log -n 1 --no-graph -T 'id.short(12)')
cd ../sandbox && jj describe -m "main work 2" && jj op abandon "$B2" && cd ../spare
jj workspace update-stale
# Updated working copy to fresh commit ⟨id⟩
jj op log -n 1                        # unchanged by update-stale: it wrote NO op
ls -A                                 # s1.txt s2.txt still there — a clean tree is simply re-checked-out
```

(When the working copy is dirty at that moment, update-stale takes the
lesson-4.5 path: `Concurrent modification detected, resolving
automatically.` and a reconcile op. On a graph with other rewrites I also
saw the checked-out change come back `(divergent)`; treat any of these as
"data is safe, history needs a look".)

**4.17** The op object is *deleted* — the recovery commit. (Destructive:
this removes unreachable objects.)

```console
cd ../spare
echo s3 > s3.txt && jj st             # snapshot op B3
B3=$(jj op log -n 1 --no-graph -T 'id.short(12)')
cd ../sandbox
jj describe -m "main work 3"
jj op abandon "$B3"                   # Abandoned 1 operations and reparented 1 descendant operations.
jj util gc --expire now               # (prints nothing) — now B3's object is really gone
cd ../spare
echo s4 > s4.txt                      # unsaved edit in flight
jj st
# Error: Could not read working copy's operation.
# Hint: Run `jj workspace update-stale` to recover.
jj workspace update-stale
# Failed to read working copy's current operation; attempting recovery. Error message from read attempt: Object ⟨128 hex digits⟩ of type operation not found
# Created and checked out recovery commit ⟨id⟩
jj log -r @ -T 'description' --no-graph   # RECOVERY COMMIT FROM `jj workspace update-stale` + the long explanation
jj op log -n 3                        # … recovery commit   (and a later snapshot working copy)
ls -A                                 # nothing was deleted from disk: s1…s4 all present
jj st                                 # the recovery commit is @; the working copy shows A s4.txt relative to it
```

Without the op there is no way to know the right parent commits, so jj
snapshots whatever is on disk into a *recovery commit*
(`cli/src/cli_util.rs`, `create_and_check_out_recovery_commit`) whose
description says as much; its diff "may contain changes from multiple
commits". The files stay on disk; you sort the commit out with
`jj squash`/`jj split`.

**4.18** `snapshot.auto-update-stale` — update-stale on autopilot:

```console
cd ../sandbox
OLD=$(jj op log -n 1 --no-graph -T 'id.short(12)')
echo 'auto' >> README.md
jj st                                 # snapshot op (holds the 'auto' line)
cd ../spare
jj op restore "$OLD"                  # rewind the shared view under sandbox
cd ../sandbox
jj st                                 # Error: The working copy is stale (not updated since operation ⟨id⟩).
jj --config snapshot.auto-update-stale=true st
# Working copy  (@) now at: ⟨change⟩ ⟨id⟩ …
# Added 0 files, modified 1 files, removed 0 files
# Updated working copy to fresh commit ⟨id⟩
# (then the normal status output)
grep -c auto README.md                # 0 — the line was rolled back, as in 4.4…
jj op log -n 1                        # …and, as in 4.4, update-stale added NO op
```

It is not silent — the same two status lines as the manual command — but
there is no error and no second command. With a dirty tree it takes the
dirty path of 4.5 (`Concurrent modification detected, resolving
automatically.`, a reconcile op), exactly as the manual command does:
verified by repeating the above with an extra unsaved edit. Persist it with
`jj config set --user snapshot.auto-update-stale true` if you live in
several workspaces. (Not for CI: it hides the signal that someone else moved
your checkout.)

## Cleanup (put at the end of the exercises)

```console
cd ../sandbox
for w in scratch spare; do jj workspace forget $w 2>/dev/null; done
rm -rf ../scratch ../scratch-2 ../spare ../review
```

(`jj workspace forget` leaves the dirs; the `rm -rf` is what removes them.)

---

## check.sh additions for lesson 04 (copy into the `04)` case)

Use the existing helpers `op_descs`, `op_attrs`. The workspace names are
dropped by the cleanup, so assert on the **op log**, which keeps history:

```bash
  maybe "4.8  a multi-workspace forget was made (one op for two names)" \
    "op_descs | grep -q '^forget workspaces .*, .*\$'" \
    "run: jj workspace forget scratch spare (from sandbox)"
  maybe "4.9  a forget was undone" \
    "op_descs | grep -q '^undo: restore to operation'" \
    "run: jj undo right after a jj workspace forget"
  maybe "4.10 a workspace forgot itself (op tagged with its own name)" \
    "jj --ignore-working-copy op log --no-graph -T 'workspace_name ++ \"|\" ++ description ++ \"\\n\"' | grep -q '^scratch@|forget workspace scratch\$'" \
    "from ../scratch run: jj workspace forget (no argument)"
  maybe "4.12 a workspace name was re-used (add after forget)" \
    "op_descs | grep -c \"^add workspace 'scratch'\" | grep -q '^[2-9]'" \
    "jj workspace forget scratch; jj workspace add ../scratch-2 --name scratch"
  maybe "4.13 a workspace was renamed" \
    "op_descs | grep -q \"^Renamed workspace 'review' to 'inspect'\"" \
    "from ../review run: jj workspace rename inspect"
  maybe "4.14 the rename was undone across workspaces" \
    "op_attrs | grep -q -- 'args: jj undo --allow-cross-workspace' && op_descs | grep -q 'redo: restore to operation'" \
    "jj undo --allow-cross-workspace, then jj redo, in the renamed workspace"
  maybe "4.15 a workspace was removed" \
    "op_descs | grep -q '^remove workspace inspect\$'" \
    "run: jj workspace remove inspect (from sandbox)"
  maybe "4.16 a sibling working-copy op was integrated" \
    "op_attrs | grep -q -- 'args: jj op integrate'" \
    "abandon the op spare sits at, then jj op integrate ⟨op⟩ from ../spare"
  maybe "4.17 a recovery commit exists" \
    "jj --ignore-working-copy log -r 'description(substring:\"RECOVERY COMMIT\")' --no-graph -T change_id | grep -q ." \
    "abandon spare's op, jj util gc --expire now, then jj workspace update-stale in ../spare"
  maybe "4.17 ...and its op is named 'recovery commit'" \
    "op_descs | grep -q '^recovery commit\$'" \
    "same as above"
```

All of the `op_descs`/`op_attrs`/`log -r description(substring:…)` forms
above were executed against a real post-lesson sandbox and matched
(`recovery commit`, `forget workspaces scratch, spare`,
`forget workspace scratch`, `Renamed workspace 'review' to 'inspect'`,
`remove workspace inspect`, `args: jj op integrate`, `args: jj workspace
rename`, `undo: restore to operation`, `add workspace 'scratch'`).
The `workspace_name` template keyword renders with a trailing `@`
(`review@|Renamed workspace 'review' to 'inspect'` in a real run), hence the
`^scratch@|` pattern; `grep -c "^add workspace 'scratch'"` printed `2` after
the re-use in 4.12. Ops removed by `jj op abandon` or by
lesson 02's experiments disappear from the log, so run the lesson
in order.

---

## Surprises worth flagging in the lesson text

1. `forget` does not snapshot and does not touch files, and whether the
   working-copy commit survives depends on *discardability* (empty +
   undescribed): empty scratch workspaces vanish from `jj log`, anything with
   content or a description stays as a head.
2. `jj undo` of a forget restores the jj workspace but **not** the Git
   worktree in a colocated repo (`.git` link gone, `git status` fatal) and
   says nothing.
3. Re-using a name turns the old directory into a stale zombie claiming
   the same workspace; `update-stale` there checks out the *new* workspace's
   commit.
4. A rename op is tagged with the OLD name, so the renamed workspace cannot
   `jj undo` its own rename without `--allow-cross-workspace`, and undoing it
   orphans the directory (view/store/dir disagree) until `jj redo`.
5. `jj op abandon` of a snapshot op that a workspace points at is
   reversible by `jj op integrate` (exit 255 "Internal error" is just the
   wording); only after `jj util gc` do you get the recovery commit.
6. `snapshot.auto-update-stale` = the manual command, same ops, same two
   status lines, no error.
7. `jj workspace rename` always renames *the workspace you are in*, including
   `default` (I accidentally renamed `default` to `foo` with it from
   `sandbox/` during testing; `jj workspace rename default` renames it back).
