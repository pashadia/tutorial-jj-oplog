# Lesson 02 — The undo toolbox

## Theory

Lesson 01 taught you to *read* the op log. This lesson is about *writing*
against it — and about why, in jj, almost nothing is destructive: every
undo-family command works by **appending** a new operation, never by
rewriting the log it walks on.

### undo/redo — a stack, not a list

`jj undo` restores the parent of the current op. Repeated `jj undo`
keeps stepping back; undoing an *undo* jumps straight to the original
target (jj collapses the chain instead of building a linked list).
`jj redo` moves forward again — only after an undo (`Error: Nothing to
redo` otherwise). The ops they write are self-describing:

```text
undo: restore to operation ⟨full 128-hex id⟩
redo: restore to operation ⟨full 128-hex id⟩
```

`jj undo` prints its two summary lines (`Undid operation:` /
`Restored to operation:`), plus the usual working-copy update lines;
`jj redo` prints one summary line (`Restored to operation:`) plus the working-copy lines when the files change. `--quiet` silences all of it.

Since 0.46, undo/redo **refuse cross-workspace targets** by default
(`Error: Refusing to undo operation … because it was performed in
workspace ⟨name⟩`) — `--allow-cross-workspace` overrides, or use
`jj op revert` to revert a specific op. (In 0.41 and older, undo
silently crossed workspaces.)

### restore — time travel that appends

`jj op restore <op>` creates a *new* op whose view is the target's view
— effectively rewinding the whole repo (including `@`) to that moment.
The restore itself appears in the log, so restoring is itself undoable.

The `--what` flag (experimental) picks what travels back: `repo`
(heads, local bookmarks, tags, working-copy pointers) and
`remote-tracking` (remote-tracking bookmarks). **Git refs are never
restored** — `git_refs`/`git_heads` always come from the *current* view,
so a colocated repo's git-side pointers stay put.

The killer safety mechanic (undocumented, verified by experiment):
**`jj op restore` snapshots the working copy first.** Uncommitted edits
become their own `snapshot working copy` op *before* the restore op is
written — so they remain in the log, diffable and restorable. Time
travel does not cost you your draft.

Edge: restoring to an op where your workspace didn't exist yet prints
`Warning: The current workspace 'default' no longer exists after this
operation. The working copy was left untouched.` The repo view is
degenerate (no working-copy commit) and subsequent commands complain
until you `jj undo` — which always works, because the op log itself was
never touched.

### revert — the inverse of exactly one op

`jj op revert <op>` merges the repo at `<op>` with the repo at
`<op>`'s parent: only *that* op's effect is inverted, later operations
survive. Descendants may need rebasing (`Rebased N descendant commits.`).
Refuses the root and merge ops (`Cannot revert root operation`,
`Cannot revert a merge operation`).

### Second-class citizens: merge ops

Ops with two parents (the `reconcile divergent operations` merges of
lesson 05) are deliberately limited: `undo`/`redo`/`op revert` refuse
them; `op show`/`op log -d` print no diff for them. `jj op restore` is
the only tool that targets them.

### abandon + gc — the only true deletion

`jj op abandon <op>` (or a range `A..B`, `..X`, `X..`) removes ops from
the log — descendants are **reparented onto the root operation**, which
rewrites their content hashes: *every descendant gets a new operation
id*. Abandon refuses the root, merge ops, and the current op (hint:
`jj undo` first). It prints `Abandoned N operations and reparented M
descendant operations.` and, if your working copy recorded a now-abandoned
op, `Warning: The working copy operation … is not updated because it
differs from the repo …` (see lesson 04).

Abandon doesn't delete objects — `jj util gc` does, and only objects
unreachable from the op log (default: older than 2 weeks; `--expire` in
0.46 accepts exactly the string `"now"`). Predecessor commits that become
unreachable vanish from `jj evolog` too — abandon+gc is the one place
jj genuinely forgets.

### restore --what, in practice

`--what` is repeatable, default is both (`[default: repo remote-tracking]`); the help text is the whole
contract: `repo` = "The jj repo state and local bookmarks", `remote-tracking` = "The remote-tracking bookmarks. Do not
restore these if you'd like to push after the undo". Anything else is a clap error
(`invalid value 'foo' for '--what <WHAT>' [possible values: repo, remote-tracking]`). The restore op's description
and `args` do not record which parts were restored (description is always `restore to operation <id>`;
only `args: jj op restore --what remote-tracking 922e3796c9cf` tells you).

### revert is a 3-way merge, so it can conflict *as data*

`jj op revert X` merges (current view) with (X's parent view) using X's own view as the base, per field.
When a later op changed the same field, you do not get an error: you get the same first-class conflicts as
lesson 05 (conflicted bookmark). When the later ops merely *build on* the reverted change, jj rebases them
(`Rebased N descendant commits.`).

### abandon vs the working copy's op pointer

The working copy stores the id of the op it last synced to (`jj debug working-copy` prints it as `Current
operation`). `jj op abandon` rewrites descendant ops, and remaps that pointer only if it pointed at a *head* being
reparented (`cli/src/commands/operation/abandon.rs`, the block after "Remap the operation id of the current
workspace"); otherwise it prints `Warning: The working copy operation X is not updated because it differs from
the repo Y.` and leaves a dangling pointer. A workspace whose pointer lags the head is normal when you use several
workspaces (lesson 04) — and it is the deterministic trigger of the "sibling" error lesson 05 could not reproduce.

### Reading the op log: ordering and limits

`-n` is applied after topological ordering and **before** `--reversed` (help text: "Applied after operations are
reordered topologically, but before being reversed"): `op log --reversed -n 3` is the *newest* three, oldest first.

### Inspecting and detaching

- `--at-op <op>` loads the repo *at* an old operation — read-only
  recommended; with an explicit old op id it implies
  `--ignore-working-copy` (no snapshot; **but `--at-op=@` is the head
  and still snapshots** — add `--ignore-working-copy`, see 2.14), and `@` resolves to the working-copy commit recorded in that
  op's view. Running a *mutating* command at an old op forks the op log
  — indistinguishable from concurrent commands (that's lesson 05's
  laboratory).
- `--no-integrate-operation` runs a command but leaves its op
  **detached**: `Operation left uncommitted because
  --no-integrate-operation was requested: ⟨id⟩`. It exists in the store,
  invisible to `jj op log`, reachable via `--at-op ⟨id⟩`, restorable,
  and `jj op integrate ⟨id⟩` reattaches it (idempotently — or, if the
  log moved on, by *reconciling* it with the current head). Side
  effects outside the repo still happen: `jj git push
  --no-integrate-operation` really pushes.

### Warnings worth knowing

| Trigger | jj says |
|---|---|
| undo a push | `Undoing a push operation often leads to conflicted bookmarks.` + hint: `jj redo` now |
| undo a workspace removal | workspace restored, *directory* not — hint: `jj workspace forget` then `jj workspace add` |

(Both restorations are 0.46-refined; older jj recovered less cleanly.)

## Exercises

**2.1** The undo/redo ladder:

```console
jj describe -m "work in progress"
jj undo                     # Undid operation: … / Restored to operation: …
jj redo                     # Restored to operation: …
jj redo                     # Error: Nothing to redo
jj undo && jj undo          # two steps back in one breath
jj op log -n 4              # the undo/redo ops, with their long descriptions
```

**2.2** Surgical revert — undo the middle, keep the rest:

```console
jj new -m "step one"
jj describe -m "step two"
jj bookmark set feature -r @
jj op log -n 6
jj op revert @-        # revert the describe; bookmark op survives
jj op log -n 3
```

**2.3** Time travel with a safety net (the exercise to remember):

```console
echo 'precious draft' >> src/greet.py
jj op restore @-               # time travel FIRST — no jj command in between:
                                # the restore itself snapshots your dirty files
jj op log -n 2                 # 'snapshot working copy' (args: jj op restore …)
                                # sits directly *below* the restore op
jj log                          # repo is back one operation in time
grep precious src/greet.py     # ...and the draft is gone from the copy
jj op restore @-               # climb back onto the snapshot op
grep precious src/greet.py     # 'precious draft' is back
```

Your uncommitted edit survived time travel as its own op — written by
the *restore*, not by you. That's the safety net: the one command that
rewinds everything is also careful to save your work first.

**2.4** The extreme edge — restore to the root:

```console
jj op restore 000000000000
```

Read the warning, then poke at the degenerate repo: `jj st` says
`No working copy.`, and `jj log -r @` ends in
`` Error: Workspace `default` doesn't have a working-copy commit ``
(exit 1: the view predates your workspace, so there is no `@` to
resolve). Plain `jj log` depends on your config: with jj's default
config it just prints `◆  zzzzzzzz root() 00000000` (exit 0), but if
your `revsets.log` has a bare `@` in it (say `visible_heads() | @ | …`)
you'll get a wall of `Failed to load short-prefixes index` template
warnings and the same `Error:` instead. Then `jj undo` and confirm
everything is sane again. The *view* was
degenerate; the *log* never was — undo always works because it operates
on the log, not the view.

**2.5** Trim history (the one-way door):

```console
jj new -m "keep me"
jj op log -n 2 -T 'id.short() ++ " " ++ description.first_line() ++ "\n"'
jj op abandon @-                         # Abandoned 1 operations and reparented …
                                           # (your @- may be 2.4's undo op — the exact
                                           # target depends on where you are)
jj op log -n 2                           # the abandoned op is gone; the head has a NEW id
jj util gc --expire now                  # reclaim the unreachable storage
```

`abandon` edits the log immediately (gc never touches what's reachable
from it); `gc` only frees disk. If you `jj evolog` a change whose older
versions became unreachable, they're gone from history for good —
abandon+gc is the one place jj genuinely forgets. (Predecessors that
are still reachable from the log survive, as `jj evolog` will show
you.)

**2.6** `--at-op` as a time machine:

```console
jj --at-op @-- log
jj --at-op @----- log        # the repo a handful of ops ago
jj --at-op @ log             # back to the present
```

Jumping to *very* old ops works — each one may print template warnings
about the short-prefixes index as the commit index is rebuilt on demand
(that index↔operation link is lesson 03's subject). But the root op
itself is the degenerate state of 2.4, reached from the other
direction: its view predates the workspace, so
`jj --at-op 000000000000 log -r @` ends in `` Error: Workspace `default`
doesn't have a working-copy commit `` (plain `jj --at-op 000000000000 log`
only shows `root()` with the default config, and fails the same way with
a bare-`@` `revsets.log`).

**2.7** Detached operations:

```console
jj --no-integrate-operation new -m "detached experiment"
# Operation left uncommitted because --no-integrate-operation was requested: <id>
jj op log -n 2                # it's not there
jj --at-op <id> log           # but it exists — inspect it (paste the printed id)
jj op integrate <id>          # reattach it
jj op log -n 2                # now it's in the log
```

Remember the id jj printed — you'll reuse this trick in lesson 05.

The next exercises (2.8–2.14) run in a **fresh lab repo** so they don't
disturb your sandbox: from `sandbox/`, `cd .. && ./new-lab.sh lab-ops &&
cd lab-ops`. They need bash. The remote in 2.8 is a throwaway bare repo
at `../remote.git` (removed by `./reset-sandbox.sh`). Ids and
timestamps are from one run — compare shapes.

**2.8** `jj op restore --what` — rewind half the world:

```console
git init -q --bare ../remote.git
jj git remote add origin ../remote.git
jj git push --bookmark main                      # bookmark: main [add to c698d332ff87]
OP_A=$(jj op log -n 1 --no-graph -T 'id.short(12)')
jj new main -m "second work"; echo more >> README.md
jj bookmark set main -r @; jj git push --bookmark main
OP_B=$(jj op log -n 1 --no-graph -T 'id.short(12)')
jj op restore --what remote-tracking $OP_A       # only the remote-tracking half
jj bookmark list -a
```

Verified:

```text
Restored to operation: 922e3796c9cf (2026-11-06 10:06:57) push bookmark main to git remote origin
main: vzqvwpum d26dcc3c second work
  @git: vzqvwpum d26dcc3c second work
  @origin (behind by 1 commits): qowwykls c698d332 Add farewell
```

Local `main` and `@` stay; the remote-tracking pointer went back ("behind by 1"). The help warns about exactly this
use: restoring remote-tracking state is what you do *not* want before a push. Now the opposite half:

```console
jj op restore $OP_B                              # back to the full state
jj op restore --what repo $OP_A
jj bookmark list -a
```

```text
Restored to operation: 922e3796c9cf (2026-11-06 10:06:57) push bookmark main to git remote origin
Working copy  (@) now at: omrtzpkn f0558565 (empty) (no description set)
Parent commit (@-)      : qowwykls c698d332 main* | Add farewell
Added 0 files, modified 1 files, removed 0 files
main: qowwykls c698d332 Add farewell
  @git: qowwykls c698d332 Add farewell
  @origin (ahead by 1 commits): vzqvwpum/0 d26dcc3c (hidden) second work
```

`repo` moves `@` and local `main` (and updates the files), while `main@origin` keeps pointing at a commit that is
now hidden (`(hidden)`, `ahead by 1`). Both together (`--what repo --what remote-tracking`) is identical to the default.
`jj op restore --what foo X` -> `error: invalid value 'foo' for '--what <WHAT>'` / `[possible values: repo, remote-tracking]`.

**2.9** Reverting an op that later ops built on — rebase, and conflict:

```console
jj new -m A; jj describe -m "A, reworded"
OPDESC=$(jj op log -n 1 --no-graph -T 'id.short(12)')
jj new -m "B on A"; jj new -m "C on B"
jj bookmark set topic -r @-
jj op revert $OPDESC
jj log -r 'ancestors(@,5)' -T 'change_id.short(6) ++ " " ++ commit_id.short(6) ++ " " ++ bookmarks ++ " " ++ description.first_line() ++ "\n"'
```

Verified:

```text
Reverted operation: e690673735c4 (2026-11-06 10:07:22) describe commit 069bee58f82da98d57e67f084998f0657fa97fd7
Rebased 2 descendant commits.
Working copy  (@) now at: sxrkvstr 0303968d (empty) C on B
Parent commit (@-)      : qvzvloml 6fc550f6 topic | B on A
@  sxrkvs 030396  C on B
○  qvzvlo 6fc550 topic B on A
○  yykumv 069bee  A
```

The describe is undone (`A`), yet B, C and the `topic` bookmark survive and ride along (note `A` has its *original*
commit id 069bee58 back — same content, same hash). `jj op show @` lists the three rewrites plus the bookmark move.

Now a dependency that cannot be rebased away — two ops touching the same bookmark:

```console
jj bookmark delete topic        # start from an absent bookmark (see the note below)
jj new -m X; jj bookmark set topic -r @
OPB1=$(jj op log -n 1 --no-graph -T 'id.short(12)')
jj new -m Y; jj bookmark set topic -r @
jj op revert $OPB1
jj bookmark list
```

```text
Reverted operation: febf551ff1b4 (2026-11-06 10:07:30) point bookmark topic to commit 4d8d4f175a68...
Done importing changes from the underlying Git repo.
main: wysktlwn 8e2cbb30 Add farewell
topic (conflicted):
  - xmwtqkyr 4d8d4f17 (empty) X
  + nuuzpyno bfb1cb6a (empty) Y
Hint: Some bookmarks have conflicts. Use `jj bookmark set <name> -r <rev>` to resolve.
```

Revert did not refuse and did not silently drop the later move: "remove X" (the inverse of op1) disagrees with
"move to Y", so you get a conflicted bookmark — same shape as lesson 05's 5.5. (`Done importing changes ...`
is the colocated repo re-syncing Git refs after the revert.) Also remember `jj undo` of the revert is always available. Resolve it now
so it does not clutter the diffs of 2.11-2.13:

```console
jj bookmark set topic -r @
```

(Why the `jj bookmark delete topic` first? Without it `topic` still
points at `B on A`, and `B -> X -> Y` is a straight line of descendants:
jj fast-forwards the 3-way merge to `Y` and the revert leaves *no* conflict.
The conflict needs the two sides to be unrelated: here "absent" versus `Y`.)

(Gotcha from the first try: reverting the *first* `jj new -m A` op of a session when later ops moved `@` is a
silent no-op — the inverse change (head A removed, `@` back) is already superseded. Pick an op whose *effect* is
still visible.)

**2.10** Abandoning the op your working copy points at (the "sibling" error, finally reproducible):

```console
jj workspace add ../side
(cd ../side && jj describe -m "side work")
jj debug working-copy                          # default's "Current operation: OperationId("b355625d6019...")"
WCOP=$(jj debug working-copy | sed -n 's/.*OperationId("\([0-9a-f]\{12\}\).*/\1/p')   # that op, 12 hex chars
jj op abandon $WCOP
jj st
```

Verified (default workspace; the side workspace's command moved the head, so default's pointer lags):

```text
Abandoned 1 operations and reparented 3 descendant operations.
Warning: The working copy operation b355625d6019 is not updated because it differs from the repo 543854a79dd6.
...
Internal error: The repo was loaded at operation fe6fa8f3bfbc, which seems to be a sibling of the working copy's operation b355625d6019
Hint: Run `jj op integrate b355625d6019` to add the working copy's operation to the operation log.
```

exit status 255. Every command in that workspace now fails the same way — even `jj op log` — until you heal it;
`jj --ignore-working-copy op log` still works for looking around. Why: `WorkingCopyFreshness::check_stale`
(`lib/src/working_copy.rs`) finds the closest common ancestor of the working copy's op and the repo's op; it is
neither of them => `SiblingOperation`. The abandoned op object still exists in the store (abandon only unlinks it from the log), so:

```console
jj op integrate b355625d6019
jj op log -n 4 --no-graph -T 'id.short(12) ++ " " ++ description.first_line() ++ " p=" ++ parents.map(|p| p.id().short(6)).join(",") ++ "\n"'
jj st
```

```text
The specified operation has been integrated with other existing operations.
55022bba3703 reconcile divergent operations p=b35562,fe6fa8
b355625d6019 import git head p=6943c7
fe6fa8f3bfbc describe commit 20a4a7d0d24a... p=e4ed73
...
The working copy has no changes.
```

`op integrate` re-adds the "abandoned" op as a second head; the next load reconciles it (lesson 05) and the working
copy is whole again. (Same-workspace variant: abandoning the *current* op is refused —
`Cannot abandon the current operation X` + `Run jj undo to revert the current operation, then use jj op abandon`.)
(Clean up: `cd ../lab-ops && jj workspace forget side && rm -rf ../side && jj abandon 'description(substring:"side work")'` — the last part drops the forgotten workspace's commit so it does not show up as an extra head in 2.13.)
Also verified: `jj --ignore-working-copy describe` still advanced the working copy's op pointer in a single
workspace (so you cannot get the lag that way); only a second workspace or `--at-op` forks produce it.

**2.11** Reading the log: `--reversed`, `-d`, `op show` flags:

```console
FROM=$(jj op log -n 1 --no-graph -T 'id.short(12)')       # remember where the story starts
echo '' >> README.md; jj describe -m "docs: more readme"     # a little history to look at
jj new -m "add util"; echo 'x = 1' > util.py; jj bookmark create feat -r @
jj new -m scratch; echo s > scratch.txt; jj st >/dev/null; jj abandon @
jj op log --reversed -n 3 --no-graph -T 'id.short(8) ++ " " ++ description.first_line() ++ "\n"'
jj op log --reversed --no-graph -T 'id.short(8) ++ " " ++ description.first_line() ++ "\n"' | head -3
SNAP=$(jj op log --no-graph -T 'if(snapshot, id.short(12) ++ "\n")' | sed -n 2p)   # 2nd-newest snapshot: jj bookmark create's
jj op show $SNAP; jj op show $SNAP --summary; jj op show $SNAP --stat; jj op show $SNAP --no-op-diff
```

Verified with a history ending `... new empty commit(0c08cbf4) / snapshot working copy(2314814e) / abandon commit(d38a6755)`:

```text
0c08cbf4 new empty commit
2314814e snapshot working copy
d38a6755 abandon commit 51fb89261c1a66789172e141d099e76fd177f63d
--
00000000 
b844cdea add workspace 'default'
570d7773 import git refs
```

First: `-n 3` takes the *newest* three, then flips them. Second: without `-n`, the root op comes first. The graph form
puts `@` at the bottom of the reversed graph. The four `op show` views of one snapshot op (`jj bookmark create`'s
snapshot, e9f7359e):

```text
(default)  Changed commits:
           ○  + wtoroxuw c1dbcfd3 add util
              - wtoroxuw/1 b671dd91 (hidden) (empty) add util
(--summary) ... same, plus the line   A util.py   under that change
(--stat)    ... plus   util.py | 1 +   /   1 file changed, 1 insertion(+), 0 deletions(-)
(--no-op-diff) only the three header lines: id line, description, args
```

`--no-op-diff` conflicts with `--summary/--stat`: `error: the argument '--no-op-diff' cannot be used with: --summary --stat`.
`jj op log -d --summary -n 3` inlines the same per-op diff under every op. Note `A scratch.txt` shows under the
*snapshot* op (where the file first entered a commit) and again under the *abandon* op (the removed commit still
carries it); the diff describes the commits that changed, not who ran the command.

**2.12** `op diff` across a range, and `--show-changes-in`:

```console
jj op diff --from $FROM --to @ --summary
jj op diff --from $FROM --to @ --show-changes-in 'description(substring:util)'
jj op diff --from $FROM --to @ --show-changes-in 'none()'
```

Verified (history: describe README, add util + bookmark `feat`, scratch commit created then abandoned):

```text
From operation: 8430f8c6746d (2026-11-06 10:08:16) import git head
  To operation: d38a6755b247 (2026-11-06 10:08:16) abandon commit 51fb89261c1a66789172e141d099e76fd177f63d

Changed commits:
○  + vqmprvrw cd53350b (empty) (no description set)
○  + wtoroxuw c1dbcfd3 feat | add util
│  A util.py
○  + tpkkuzwn 3339202b docs: more readme
   - tpkkuzwn/2 d0cda219 (hidden) (empty) (no description set)
   M README.md

Changed working copy default@:
+ vqmprvrw cd53350b (empty) (no description set)
- tpkkuzwn/2 d0cda219 (hidden) (empty) (no description set)

Changed local bookmarks:
feat:
+ wtoroxuw c1dbcfd3 feat | add util
- (absent)
```

(Your output may also list a `topic:` bookmark change: `topic` was sitting on the working-copy commit that `describe` rewrote.)

Two things to notice: the `scratch` commit (created in one op, abandoned in a later one) is **absent** — a range diff
compares two views, not a sum of ops; and changes in the middle collapse to net before/after. `--show-changes-in REVSET` filters the change list
(default from config `revsets.op-diff-changes-in` = `mutable() | immutable_heads()`; no `jj config list revsets`
section exists, use `jj config get revsets.op-diff-changes-in`) and says what it hid:

```text
Changed commits:
○  + wtoroxuw c1dbcfd3 feat | add util
   (Elided 2 newly added and 1 newly removed revisions)
```
and with `none()`: `   (Elided 3 newly added and 1 newly removed revisions)`. Working-copy and bookmark sections are never filtered.
With only `--from X` the `--to` side defaults to `@`; `jj op diff` alone is `--op @` (parent vs @).

**2.13** The revset `at_operation(op, expr)` vs `--at-op`:

```console
L='change_id.short(6) ++ " " ++ commit_id.short(6) ++ " [" ++ bookmarks ++ "] " ++ description.first_line() ++ "\n"'
jj log --no-graph -T "$L" -r 'visible_heads()'                         # now
jj log --no-graph -T "$L" -r 'at_operation(@-, visible_heads())'       # heads that were visible one op ago
jj log --no-graph -T "$L" -r 'at_operation(@---, @)'                   # where @ was at an older op
jj log --no-graph -T "$L" -r 'at_operation(@--, @) | @'                # two eras in ONE query
jj --at-op=@-- log -r @                                     # the flag form
```

Verified:

```text
now:                         vqmprv cd5335 []
at_operation(@-, heads):     poxvor 51fb89 [] scratch            <- the commit that `jj abandon` hid
at_operation(@---, @):       wtorox c1dbcf [feat] add util
at_operation(@--, @) | @:    vqmprv cd5335 []
                             poxvor b72d0b [] scratch
--at-op=@-- log -r @:         poxvor b72d0b [] scratch            (same commit as the revset form)
```

Differences: the revset form lets you combine eras and bring old commits into the search space; the flag loads *everything* at
the old op. Gotcha, straight from `docs/revsets.md`: "Since `at_operation(op, x)` brings all commits that were visible at the operation to the search
space, `at_operation(op, x) | all()` is equivalent to ...". Consequently the obvious "what has disappeared since?" query is empty:

```console
jj log -r 'at_operation(@--, all()) ~ all()'                    # EMPTY - all() includes the imported commits
jj log -r 'at_operation(@--, all()) ~ ::visible_heads()'        # poxvor b72d0b [] scratch   <- correct
jj log -r 'at_operation(@--, visible_heads()) ~ visible_heads()'  # same answer, simpler
```

and `jj log -r b72d0b` shows it too (an explicit id may reach hidden commits). `at_operation(nosuch, @)` ->
`Error: Operation ID "nosuch" is not a valid hexadecimal prefix`.

**2.14** Does it snapshot? (correction to "--at-op implies --ignore-working-copy")

```console
n() { jj --ignore-working-copy op log --no-graph -T 'id.short() ++ "\n"' | wc -l; }   # count the ops
echo dirty >> dirty.txt
n                                                        # N
jj --at-op=@-- log -r @ >/dev/null; n                    # N   (no snapshot)
jj log -r 'at_operation(@--, @)' >/dev/null; n           # N+1 (the normal startup snapshot ran first)
echo dirtier >> dirty.txt                                # dirty the tree again: each probe needs something to snapshot
jj --at-op=@ --ignore-working-copy op log -n 1 >/dev/null; n   # N+1 (no new op)
jj --at-op=@ op log -n 1 >/dev/null; n                  # N+2 (SNAPSHOTS!)
```

Verified counts (in a lab with 13 ops at the start): `13 -> 13`, `13 -> 14`, `14 -> 14`, `14 -> 15`. So `--at-op=<old>` really is read-only,
but `--at-op=@` is *not*: `is_at_head_operation()` in `cli/src/cli_util.rs` treats `None | Some("@")` as the head, so the working
copy is still snapshotted (the `op log --help` text says to use `--at-op=@ --ignore-working-copy` for non-mutating inspection;
lesson 05's remark "`--at-op=@` ... documented recipe for reading the log without mutating anything" needs the extra flag).

## Verify

```console
./check.sh 02
```
