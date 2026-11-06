# Lesson 05 — Forks and healing: concurrent operations on one machine

## Theory

"Lock-free concurrency" doesn't mean concurrent commands cooperate —
it means **they don't collide destructively**. Two jj processes (or
two machines on one filesystem — lesson 07) each load the repo at some
operation, work in memory, and publish a *new* operation whose parent
is the op they started from. If someone published in between, the log
now has **two heads** — a fork — and nothing was lost.

### How forks arise

1. **`--at-op=<old op>` + a mutating command** — the deliberate
   laboratory method: "equivalent to having run concurrent commands
   starting at the earlier operation" (the `--at-op` help text).
2. **Genuine races** — two processes, or two machines on NFS.
3. **`jj op integrate` of a detached op** whose log moved on
   (`--no-integrate-operation` leaves an *unreachable* op — no fork;
   integrating it later re-adds it as a head *beside* the current one).
4. **A crash between add-marker and remove-marker** — leaves a
   *descendant+ancestor* pair, which heals without creating any op.

### Healing, step by step

Every command starts by resolving the head markers
(`resolve_op_heads`):

1. One head → done, no lock taken (the common case).
2. Multiple heads → take the op-heads lock (so two processes don't
   both reconcile), re-read, **drop ancestor heads** — a
   descendant+ancestor pair from a crash heals here, silently, no op
   created.
3. Still multiple → sort heads by **end timestamp** and run a
   **3-way merge of the views**, field by field, against each pair's
   closest common ancestor:
   - head commits: union, with commits rewritten by the other side
     rebased (`Rebased N descendant commits onto commits rewritten by
     other operation.`),
   - bookmarks/tags/refs: `Merge` terms — **conflicts, not failures**
     (one op moved `main` forward, a sibling deleted it → `main
     (conflicted)` with `- old / + new` terms),
   - working-copy pointers: merged per workspace.
4. Publish one merge operation — description
   `reconcile divergent operations` — with **one parent per head**
   (verified: 3 forks → one op with 3 parents), and remove all fork
   heads.

The command that healed prints (to stderr):

```text
Concurrent modification detected, resolving automatically.
```

N-way merges with criss-cross ancestry are computed iteratively
(upstream once overflowed the stack recursing — it's an explicit
work-list now), and may write intermediate `merge N operations`
objects that are **never published** — orphans in the store, gc-fodder.

### Who wins a conflict between the two sides?

Reconcile is a *fold*, not a symmetric merge. `resolve_op_heads` sorts the head ops by **end
timestamp** (`lib/src/op_heads_store.rs:154`), then `merge_operations` starts a transaction from
`operations[0]` ("self") and merges each later head into it as "other" (`lib/src/repo.rs`,
`RepoLoader::merge_operations`). The view merge is `MutableRepo::merge_view` (`lib/src/repo.rs`):

- **head commits**: rewrites made on either side are recorded (`record_rewrites`) and descendants
  that exist only on the *other* side are rebased onto the rewrite
  (`Rebased N descendant commits onto commits rewritten by other operation.` is printed by
  `merge_operations` in `cli/src/cli_util.rs`).
- **working-copy pointer** (`merge_wc_commit`): a three-way trivial merge; if both sides moved it,
  the doc comment says it plainly: *"If there's a conflict ... we keep the self side"*. So the
  fork that **finished first** owns `@`.
- **divergent rewrites** (`enum Rewrite::Divergent`, same file): *"Children of the old commit should
  be rebased onto the new commits. However, if the type is `Divergent`, they should be left in
  place."* Two sides that rewrite the same commit produce a divergent change and **no rebase**.

Consequence: reconcile is deterministic *given the end timestamps*. Ties (same millisecond) fall
back to directory-listing order of `op_heads/heads/`, which is not stable (see 5.11).

To make the lab repeatable we pin both clocks: `JJ_OP_TIMESTAMP` (operation start/end) and
`JJ_TIMESTAMP` (commit author/committer time). Both are real env overrides
(`cli/src/config.rs`, `env_overrides_layer`: `debug.operation-timestamp`, `debug.commit-timestamp`).

Helper used in every exercise (define once per shell):

```console
at() { s=$1; shift
       JJ_OP_TIMESTAMP="2026-01-01T12:00:0${s}+00:00" \
       JJ_TIMESTAMP="2026-01-01T12:00:0${s}+00:00" jj "$@"; }
opshape() { jj op log -n ${1:-6} --no-graph -T 'id.short(8) ++ " " ++ description.first_line() ++ " parents=" ++ parents.map(|p| p.id().short(8)).join(",") ++ "\n"'; }
```

### Merge ops are second-class citizens

The reconcile op has multiple parents, so the linear-history tools
refuse it: `jj undo` → `Cannot undo a merge operation` (hint:
`Consider using jj op restore instead`), `jj op revert` → `Cannot
revert a merge operation`, and `op show`/`op log -d` print no diff for
it (reconstructing "the" parent state is ambiguous, so jj doesn't
guess). `jj op restore` remains the one time machine — but it needs a
*specific* op id: even `@-` won't resolve through a merge (two
parents → `resolved to more than one operation`).

### Inspecting a fork without healing it

The default load *is* the healer — even `--ignore-working-copy` still
reconciles (it only skips snapshotting). To look but not touch:

```text
$ jj op log --at-op=@
Error: The "@" expression resolved to more than one operation
Hint: Try specifying one of the operations by ID: f7922ea71f0d, 33be1d3c7e33
```

`jj --at-op=<one-head-id> op log` shows that side's ancestry only.
(`--at-op=@` works fine when there's a single head — but note it still
**snapshots** the working copy (an `@` operation counts as the head).
For a read that writes nothing at all, add the flag
`jj --at-op=@ --ignore-working-copy op log` — what `jj op log --help`
itself recommends. An explicit old op id never snapshots; see 2.14.)

### The sibling working copy

When the working copy's recorded operation and the repo's loaded
operation are neither ancestor of the other, the freshness check fails
like this. `--no-integrate-operation` does **not** trigger it on 0.46
(the working-copy state never advances for a non-integrated op: four
attempts, clean/dirty/snapshot, all fine). What does trigger it,
deterministically, is `jj op abandon` of the operation a *lagging*
workspace points at — recipe in 5.15, and again in 2.10 and 4.16:

```text
Internal error: The repo was loaded at operation X, which seems to be
a sibling of the working copy's operation Y
Hint: Run `jj op integrate Y` to add the working copy's operation to
the operation log.
```

— one more way the op log, the view, and the working copy interact
(lesson 04's freshness table, third row).

## Exercises

*(Arriving from lesson 04? Start clean: `cd .. && ./reset-sandbox.sh &&
cd sandbox`. Lesson 04 leaves divergent changes and a second workspace
that would clutter 5.7's `divergent()` output — and break lesson 06.)*

**5.1** Manufacture a fork deterministically:

```console
jj st                               # fresh? (update-stale if lesson 04 left you stale)
BASE=$(jj op log -n 1 --no-graph -T 'id' | cut -c1-12)
jj --at-op "$BASE" new -m "branch A"
jj --at-op "$BASE" new -m "branch B"
ls .jj/repo/op_heads/heads/          # two marker files
jj st                                # Concurrent modification detected, resolving automatically.
jj op log -n 5                       # the reconcile op, two parents
```

Note *when* the message appears: not at fork time — at the next load.
(In this colocated sandbox the `--at-op` publishes may also print
`Warning: Failed to update Git HEAD ref` — publishing from an old op
can't move Git HEAD, and the next ordinary command re-syncs it.
Cosmetic.)

**5.2** Three forks, one merge:

```console
BASE=$(jj op log -n 1 --no-graph -T 'id' | cut -c1-12)
jj --at-op "$BASE" new -m "fork 1"
jj --at-op "$BASE" new -m "fork 2"
jj --at-op "$BASE" new -m "fork 3"
jj log
jj op log -n 5 --no-graph -T 'id.short(6) ++ " " ++ description.first_line()
  ++ " parents=" ++ parents.map(|p| p.id().short(6)).join(",") ++ "\n"'
```

One `reconcile divergent operations` op, three parents.

**5.3** The detached-op fork (from lesson 02's trick):

```console
DET=$(jj --no-integrate-operation new -m "detached X" 2>&1 | tail -1 | grep -oE '[0-9a-f]{12,}')
jj new -m "meanwhile, the log moves on"
jj op integrate "$DET"
# The specified operation has been integrated with other existing operations.
jj op log -n 4                       # reconcile op; detached op beside the moving-on op
```

**5.4** Look without healing:

```console
BASE=$(jj op log -n 1 --no-graph -T 'id' | cut -c1-12)
jj --at-op "$BASE" new -m "left" >/dev/null
jj --at-op "$BASE" new -m "right" >/dev/null
jj op log --at-op=@                  # Error + hint listing both heads
jj --at-op "$(ls .jj/repo/op_heads/heads | head -1)" op log -n 3   # one side
jj op log                            # healing, with the error's two ids as parents
```

**5.5** A bookmark conflict born from concurrency:

```console
jj bookmark set main -r @- 2>/dev/null
BASE=$(jj op log -n 1 --no-graph -T 'id' | cut -c1-12)
jj --at-op "$BASE" bookmark move main          # forward, to @
jj --at-op "$BASE" bookmark delete main
jj log
```

The reconcile prints `Concurrent modification detected …` and the log
shows `main??`; `jj bookmark list` explains:

```text
main (conflicted):
  - <old target>
  + <new target>
  @git: <new target>
Hint: Some bookmarks have conflicts. Use `jj bookmark set <name> -r <rev>` to resolve.
```

The *operation* fork healed itself; the *bookmark* disagreement it
carried survives as a conflict for you to settle — resolve it with
`jj bookmark set main -r <rev>`. (In the colocated sandbox you'll
also see `Warning: Failed to export some bookmarks:` — Git can't hold
a conflicted ref; it exports cleanly once you resolve.)

**5.6** Second-class citizens, confirmed:

```console
jj undo                 # Cannot undo a merge operation — the head is the reconcile op
jj op revert @          # Cannot revert a merge operation
jj op restore @-        # Error: The "@-" expression resolved to more than one operation
                        # (a merge has TWO parents — the grammar refuses to pick)
jj op restore "$BASE"   # but restore names a specific op: land before the fork
jj log                   # the conflicted main is gone — you're back at $BASE's state
```

**5.7** The real thing — genuine racing processes (safe to try; this
is the whole point of the design):

```console
for i in 1 2 3; do
  (JJ_OP_USERNAME=alice jj describe -m "race A$i" >/dev/null 2>&1) &
  (JJ_OP_USERNAME=bob   jj describe -m "race B$i" >/dev/null 2>&1) &
  wait
done
jj st
jj op log -n 6
jj log -r 'divergent()' --no-graph -T 'change_id.short() ++ " " ++ description.first_line() ++ "\n"'
```

Both processes *succeeded every round* — no errors, no corruption. But
they rewrote the same change from the same base, so the **change**
diverged (several `<change-id>/N` tips, e.g. `ywvwumru/0`, `/1`, `/2`) even as each op-log fork healed.
Convergence is manual here: `jj converge`, or abandon a side. Lesson 07
takes this to two "machines".

The next exercises are destructive and timing-sensitive, so they run in
a **fresh lab repo**, not in your sandbox. From `sandbox/`:

```console
cd .. && ./new-lab.sh lab-forks && cd lab-forks
```

(`new-lab.sh lab-<name>` creates a seeded colocated repo identical to a
fresh sandbox; it wipes and recreates `lab-<name>` each time, and
`./reset-sandbox.sh` removes all `lab-*` directories.) Define the
helpers from the theory section above (`at`, `opshape`) once per shell,
under **bash**. Ids and timestamps in the quoted output are from one run
— compare *shapes*, not ids. (The pinned clocks are UTC; `jj log` shows them in your
timezone, so `12:00:01+00:00` reads `13:00:01` in the quoted runs, which were in UTC+1.)

**5.8** Reword vs. grow — one fork rewrites a commit, the other adds a child to it:

```console
# fresh lab:  cd .. && ./new-lab.sh lab-forks && cd lab-forks
jj describe -m "feature"
BASE=$(jj op log -n 1 --no-graph -T 'id.short(12)')
at 1 --at-op $BASE describe -m "feature (reworded)"      # fork A finishes first
at 2 --at-op $BASE new -m "child of feature"             # fork B finishes second
at 9 log                                                  # heal with a pinned clock too (the rebased child gets 09)
opshape 3
```

Verified output (the `--at-op` publishes are silent here; heal happens in the `log` — pinned
with `at 9` so that the rebased child carries a fixed time, `13:00:09` below; with a plain `jj log`
it would carry the wall clock):

```text
Concurrent modification detected, resolving automatically.
Rebased 1 descendant commits onto commits rewritten by other operation.
○  skmykkpm tut@example.com 2026-01-01 13:00:09 98b0f7a3
│  (empty) child of feature
@  kyykwmlv tut@example.com 2026-01-01 13:00:01 659899db
│  (empty) feature (reworded)
○  znsulqss tutorial@example.com 2026-11-05 18:29:23 main db1c0170
│  Add farewell
...
6f63c4d6 reconcile divergent operations parents=39b1a0f9,e6d21473
39b1a0f9 describe commit 3d42425545f2770dfc37f34f9238227b73f781c7 parents=df612a74
e6d21473 new empty commit parents=df612a74
```

B's child was created on the *old* `feature`; the reconcile rebased it onto A's reworded commit,
and `@` is A's side (the earlier finisher), not the child B moved to.

Now flip the clocks (`at 2` for the describe, `at 1` for the `new`, heal with `at 9 log`) on a fresh lab (`cd .. && ./new-lab.sh lab-forks && cd lab-forks`, redo the `describe`):

```text
@  rqppnxys tut@example.com 2026-01-01 13:00:09 39872ac2
│  (empty) child of feature
○  xoqpuzrz tut@example.com 2026-01-01 13:00:02 479e937e
│  (empty) feature (reworded)
...
55fb2bff reconcile divergent operations parents=ed078702,ba06c8a3
ed078702 new empty commit parents=9c10c0f1          <- first parent = first finisher
ba06c8a3 describe commit 66a608a6... parents=9c10c0f1
```

Same graph, different `@`: the first-finishing head is "self", and wins the working-copy pointer.
Parent order of the reconcile op is the end-time order too.

**5.9** Reword vs. reword — divergence, and children are left alone:

```console
# fresh lab:  cd .. && ./new-lab.sh lab-forks && cd lab-forks
jj describe -m "feature"
BASE=$(jj op log -n 1 --no-graph -T 'id.short(12)')
at 1 --at-op $BASE describe -m "feature, take A"
at 2 --at-op $BASE describe -m "feature, take B"
at 3 --at-op $BASE new -m "child of the original"
jj log
jj log -r 'divergent()' --no-graph -T 'change_id.shortest(8) ++ "/" ++ change_offset ++ " " ++ commit_id.short(8) ++ " " ++ description.first_line() ++ "\n"'
opshape 5
```

Verified:

```text
Concurrent modification detected, resolving automatically.
@  pwwtpqnq/1 tut@example.com 2026-01-01 13:00:01 b0b06001 (divergent)
│  (empty) feature, take A
│ ○  pwwtpqnq/0 tut@example.com 2026-01-01 13:00:02 60960b78 (divergent)
├─╯  (empty) feature, take B
│ ○  wymszxqu tut@example.com 2026-01-01 13:00:03 a96d18fa
│ │  (empty) child of the original
│ ○  pwwtpqnq/2 tut@example.com 2026-11-05 18:29:38 6f06c4e6 (divergent)
├─╯  (empty) feature
○  krqpskxq tutorial@example.com 2026-11-05 18:29:38 main 7aac8084
...
0927b7e2 reconcile divergent operations parents=174d21a0,ef078140,3b12ddaf
pwwtpqnq/0 60960b78 feature, take B
pwwtpqnq/1 b0b06001 feature, take A
pwwtpqnq/2 6f06c4e6 feature
```

Surprises worth teaching:
- **No `Rebased ...` line.** Two rewrites of one commit are `Rewrite::Divergent`: the child is *not*
  moved, so the **original** `feature` stays visible (offset `/2`) as the child's parent — three
  commits share one change id.
- The reconcile op has three parents (A, B, and the child fork), sorted by end time.
- `@` is take A (earliest finisher).

**5.10** A conflict born inside the reconcile (and the stale working copy it causes):

```console
# fresh lab:  cd .. && ./new-lab.sh lab-forks && cd lab-forks
printf 'one\ntwo\nthree\n' > poem.txt; jj commit -m "poem"
C1=$(jj log -r @- --no-graph -T 'commit_id.short(12)')
jj new $C1 -m alt;         sed -i 's/two/deux/' poem.txt; jj st >/dev/null
ALT=$(jj log -r @ --no-graph -T 'commit_id.short(12)')
jj new $C1 -m child-edit;  sed -i 's/two/TWO/'  poem.txt; jj st >/dev/null
CH=$(jj log -r @ --no-graph -T 'commit_id.short(12)')
jj new $C1 -m scratch
jj abandon $ALT $CH                       # hide both; they stay addressable by id
BASE=$(jj op log -n 1 --no-graph -T 'id.short(12)')
at 1 --at-op $BASE restore --from $ALT --into $C1 poem.txt    # A: rewrite poem's content
at 2 --at-op $BASE new $CH -m "on top of child-edit"          # B: grow on top of the hidden edit
at 9 log                    # heals ... and then?
```

Verified:

```text
--- A:  Rebased 1 descendant commits.
--- B:  Warning: Failed to update Git HEAD ref   (cosmetic, see 5.1)
--- heal
Concurrent modification detected, resolving automatically.
Rebased 2 descendant commits onto commits rewritten by other operation.
Error: The working copy is stale (not updated since operation c25146c27ae1).
Hint: Run `jj workspace update-stale` to update it.
```

Two lessons in one: (1) the reconcile rebased B's two commits onto A's rewritten `poem`, which
conflicts; (2) A's side owns `@`, whose *tree* changed (it now contains `deux`), and a merge
op that changes the working-copy tree **does not auto-update the files**: `check_stale`
(`lib/src/working_copy.rs`, `WorkingCopyFreshness::check_stale`) returns `WorkingCopyStale` when
the wc op is an ancestor of the repo op but the trees differ. Fix and inspect:

```console
jj workspace update-stale
jj log
jj file show -r <child-edit change id> poem.txt
jj resolve --list -r <child-edit change id>
```

```text
Working copy  (@) now at: zpvrrrzm 8da4d208 (empty) scratch
Added 0 files, modified 1 files, removed 0 files
@  zpvrrrzm tut@example.com 2026-01-01 13:00:01 8da4d208
│  (empty) scratch
│ ×  qmtwxqtx tut@example.com 2026-01-01 13:00:09 587da7cd (conflict)
│ │  (empty) on top of child-edit
│ ×  wwuustms tut@example.com 2026-01-01 13:00:09 10a14215 (conflict)
├─╯  child-edit
○  lypzlzxr tut@example.com 2026-01-01 13:00:01 fd15b914
│  poem
...
one
<<<<<<< conflict 1 of 1
+++++++ lypzlzxr fd15b914 "poem" (rebase destination)
deux
%%%%%%% diff from: lypzlzxr a149f5c6 "poem" (parents of rebased revision)
\\\\\\\        to: wwuustms f23b6a4c "child-edit" (rebased revision)
-two
+TWO
>>>>>>> conflict 1 of 1 ends
three
poem.txt    2-sided conflict
```

(Note the empty commit `on top of child-edit` is also marked `(conflict)`: conflicts propagate to
descendants.) Gotcha: `jj log -r 'description(substring:child-edit)'` etc. error with
`resolved to more than one revision` when used where a single revision is required (`file show`),
because both the conflicted child and its child match; use the change id.

**5.11** Is the reconcile deterministic? Copy the repo *between* fork and heal and heal both copies
with the same pinned clock:

```console
# fresh lab, then only the two forks of 5.8 -- and NO heal (no `jj log`) before copying:
#   cd .. && ./new-lab.sh lab-forks && cd lab-forks
#   jj describe -m "feature"; BASE=$(jj op log -n 1 --no-graph -T 'id.short(12)')
#   at 1 --at-op $BASE describe -m "feature (reworded)"; at 2 --at-op $BASE new -m "child of feature"
cp -a . ../copy1; cp -a . ../copy2
(cd ../copy1; at 9 log >/dev/null 2>&1; opshape 1)
(cd ../copy2; at 9 log >/dev/null 2>&1; opshape 1)
```

Verified: both copies print the **identical** reconcile op id, `6f63c4d6 reconcile divergent
operations parents=39b1a0f9,e6d21473`, and identical logs (same commit ids for the rebased
child). With the wall clock instead of `JJ_*TIMESTAMP`, the *shape* is identical but ids differ
(the reconcile op and rebased commit embed "now"). So: deterministic function of
(heads, end-times, clock); op ids differ run to run only because of time.

Ties: if both forks get the same op timestamp (`at 5` for both), the sort key is equal and the
winner is whatever order `op_heads/heads/` lists. Make the two forks of 5.8 with `at 5` twice, then
heal several byte-identical copies, e.g.
`for i in 1 2 3 4; do cp -a . ../tie$i; (cd ../tie$i; jj log -r @ --no-graph -T 'description ++ "\n"' 2>/dev/null); done; rm -rf ../tie*`.
Copies of the same repo healed to different `@`:

```text
feature (reworded)
child of feature
child of feature
```

(copies are separate directories; directory hash order differs.) Don't build workflows on ties;
in real life ms-resolution ends make them rare but not impossible.

**5.12** Reading the log mid-fork, deterministically (extends 5.4):

```console
BASE=$(jj op log -n 1 --no-graph -T 'id.short(12)')
at 1 --at-op $BASE describe -m left
at 2 --at-op $BASE describe -m right
jj --at-op=@ log          # Error ... resolved to more than one operation
jj op log --at-op=@-      # same error
jj op log --at-op="$BASE+"   # children of BASE: same error, different expression
ls .jj/repo/op_heads/heads | wc -l                      # 2 (nothing healed yet)
jj --ignore-working-copy op log -n 1                    # ... but this DOES heal
ls .jj/repo/op_heads/heads | wc -l                      # 1
```

Verified:

```text
Error: The "@" expression resolved to more than one operation
Hint: Try specifying one of the operations by ID: 21b9467155c8, 9c7e150703cd
...
Error: The "e6ca2f9767f5+" expression resolved to more than one operation
Hint: Try specifying one of the operations by ID: 21b9467155c8, 9c7e150703cd
...
2
Concurrent modification detected, resolving automatically.
@    ec9545f7a696 tut@host default@ now, lasted 1 millisecond
├─╮  reconcile divergent operations
│ │  args: jj --ignore-working-copy op log -n 1
1
```

Why: `--at-op=@` goes through `op_walk::resolve_op_for_load`, whose `@` callback runs
`resolve_op_heads` with a resolver that *errors* (`OpsetResolutionError::MultipleOperations`) instead
of merging (`lib/src/op_walk.rs`). Candidates are listed sorted by end time (comment: "To stabilize
output, sort in the same order as resolve_op_heads()"), i.e. the first id is the would-be "self".
`@-` fails identically because `@` must be resolved first; `X+` reports the fork children via
`find_child_ops`. Error `Hint` ids are the exact ids you can pass to `--at-op`.

**5.13** The crash-window head heals silently (theory item 4 of "How forks arise", finally shown):

```console
jj describe -m "feature"
OLD=$(jj op log -n 1 --no-graph -T 'id')
jj describe -m "feature v2"
ls .jj/repo/op_heads/heads | wc -l                 # 1
touch .jj/repo/op_heads/heads/$OLD                 # simulate "added new marker, died before removing old"
ls .jj/repo/op_heads/heads | wc -l                 # 2
jj op log -n 2 --at-op=@                           # works! no error, no message
ls .jj/repo/op_heads/heads | wc -l                 # 1
```

Verified: the marker pair `6c3bf3bb298c d3f9e468f967` becomes just `6c3bf3bb298c`, with **no**
`Concurrent modification detected` and no new op. `dag_walk_async::heads` drops the ancestor head;
`if let [op_head] = &*op_heads { update_op_heads(&ancestor_op_heads, op_head.id()); return ... }`
(`lib/src/op_heads_store.rs`) — even the `--at-op=@` path performs this repair, because only the
*resolver* closure is the error. Contrast with 5.12 where the two heads are siblings.

**5.14** `Concurrent working copy operation` — the real thing, with an injected delay (Linux, needs `strace`):

The error is raised by `start_working_copy_mutation` (`cli/src/cli_util.rs`): after taking the
working-copy lock it compares the loaded wc commit's tree with the tree the on-disk state records
(`old_tree`); a mismatch is `RunnerError::ConcurrentWorkingCopyOperation`. Plain *snapshots* can't
trip it (they re-check freshness under the lock and say "stale" instead), so the victim has to be a
command that takes the lock a *second* time: `jj file track` (also `sparse set`, `workspace
add/rename`, `workspace update-stale`). The window is microseconds, so we widen it with strace:
delay the second `working_copy.lock` acquisition (the 9th `flock` call) of one process, and run a
conflicting checkout in between:

Do it in a **fresh lab** (the flock numbering depends on repo state: in a lab that has piled up
forks and a divergent `@`, as after 5.12-5.13, the snapshot phase takes more locks, call #9 is
the wrong one and the command simply succeeds):

```console
cd .. && ./new-lab.sh lab-forks && cd lab-forks
echo v1 > c.txt
strace -f -o /dev/null -e trace=flock -e inject=flock:delay_enter=3s:when=9 jj file track c.txt &
sleep 1.2
jj edit @-                    # P2: completes while P1 sleeps (P1 holds no lock at that moment)
wait
```

Verified (the `-o /dev/null` keeps strace's own trace out of the way; `-qq` alone does not):

```text
Error: Concurrent working copy operation. Try again.
P1 exit=1
```

and P2's edit stands. Pitfall found: delaying the *next* call (`when=10`, the op-heads lock) does
not work — P1 is then already holding `working_copy.lock`, P2 queues behind it and everything
succeeds. Delay the call *before* the lock is taken. Verify the count on your machine first (in the fresh lab, after `echo v1 > c.txt`) with
`strace -f -y -o /dev/stdout -e trace=flock jj file track c.txt` (we saw 12 flock calls: #1-8 are the
snapshot phase — import/export lock, `working_copy.lock`, `store/extra/lock`, `op_heads/heads/lock`
and their unlocks; #9 is the second `LOCK_EX` on `.jj/working_copy/working_copy.lock`, #10 the
`op_heads/heads/lock`). Whatever your count is, `when=` must be the index of that second
`working_copy.lock` acquisition.

Natural reproduction: a 150x/150x stress loop (`jj file track` vs `jj edit @-`/`jj edit @+`) produced
**zero** `Concurrent working copy operation` errors (it did produce 3 natural
`Concurrent modification detected` heals in the track loop). Treat the error as practically
unreachable without a delay. Not reproducible via `JJ_EDITOR`/aliases/external diff (none of those run between
the two lock acquisitions), and no `watchman` is installed, so the fsmonitor route was not tried.

**5.15** The sibling working copy, reproduced (it needs no race at all; run it in the same `lab-forks`). The theory section above says
this error could not be triggered with `--no-integrate-operation` on 0.46. It can, by abandoning the operation a *lagging*
workspace points at (full walkthrough in exercise 2.10):

```console
jj workspace add ../side; (cd ../side && jj describe -m "side work")   # default's op pointer now lags the head
WCOP=$(jj debug working-copy | grep -o 'OperationId("[0-9a-f]*' | cut -c14-25)
jj op abandon $WCOP
jj st
jj op integrate $WCOP
jj st
```

```text
Abandoned 1 operations and reparented 3 descendant operations.
Warning: The working copy operation b355625d6019 is not updated because it differs from the repo 543854a79dd6.
Internal error: The repo was loaded at operation fe6fa8f3bfbc, which seems to be a sibling of the working copy's operation b355625d6019
Hint: Run `jj op integrate b355625d6019` to add the working copy's operation to the operation log.
The specified operation has been integrated with other existing operations.
The working copy has no changes.
```

(exit status of the failing `jj st`: 255; `op integrate` creates a `reconcile divergent operations` op with parents `b35562,fe6fa8`.)

## Verify

```console
./check.sh 05
```
