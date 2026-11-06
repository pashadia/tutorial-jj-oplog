# DRAFT d3b — lesson 02 additions (2.8 ...): restore --what, revert with dependents, abandon vs the working copy, op-log queries, at_operation()

Status: all exercises run on jj 0.46.0 in a throwaway copy (isolated HOME/JJ_CONFIG, user tut@host). Ids are from
real runs; they will differ for readers. Sources cited are in /home/bogdan/work/google-jj/jj-upstream.

## Theory addendum (insert before "Inspecting and detaching")

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

## Exercises

**2.8** `jj op restore --what` — rewind half the world:

```console
git init -q --bare ../remote.git
jj git remote add origin ../remote.git
jj bookmark track main@origin
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
is the colocated repo re-syncing Git refs after the revert.) Resolve with `jj bookmark set topic -r @`.
Also remember `jj undo` of the revert is always available.

(Gotcha from the first try: reverting the *first* `jj new -m A` op of a session when later ops moved `@` is a
silent no-op — the inverse change (head A removed, `@` back) is already superseded. Pick an op whose *effect* is
still visible.)

**2.10** Abandoning the op your working copy points at (the "sibling" error, finally reproducible):

```console
jj workspace add ../side
(cd ../side && jj describe -m "side work")
jj debug working-copy                          # default's "Current operation: OperationId("b355625d6019...")"
WCOP=b355625d6019                              # that op (12 hex chars)
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
Also verified: `jj --ignore-working-copy describe` still advanced the working copy's op pointer in a single
workspace (so you cannot get the lag that way); only a second workspace or `--at-op` forks produce it.

**2.11** Reading the log: `--reversed`, `-d`, `op show` flags:

```console
jj op log --reversed -n 3 --no-graph -T 'id.short(8) ++ " " ++ description.first_line() ++ "\n"'
jj op log --reversed --no-graph -T 'id.short(8) ++ " " ++ description.first_line() ++ "\n"' | head -3
jj op show <snapshot-op> ; jj op show <snapshot-op> --summary ; ... --stat ; ... --no-op-diff
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
jj op diff --from 8430f8c6 --to @ --summary
jj op diff --from 8430f8c6 --to @ --show-changes-in 'description(substring:util)'
jj op diff --from 8430f8c6 --to @ --show-changes-in 'none()'
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
jj log -T "$L" -r 'visible_heads()'                         # now
jj log -T "$L" -r 'at_operation(@-, visible_heads())'       # heads that were visible one op ago
jj log -T "$L" -r 'at_operation(@---, ::@)'                 # the @ ancestry at an older op
jj log -T "$L" -r 'at_operation(@--, @) | @'                # two eras in ONE query
jj --at-op=@-- log -r @                                     # the flag form
```

(`L='change_id.short(6) ++ " " ++ commit_id.short(6) ++ " [" ++ bookmarks ++ "] " ++ description.first_line() ++ "\n"'`, with `--no-graph`.) Verified:

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
echo dirty >> dirty.txt
jj --ignore-working-copy op log --no-graph | wc -l       # N
jj --at-op=@-- log -r @ >/dev/null                       # N   (no snapshot)
jj log -r 'at_operation(@--, @)' >/dev/null              # N+1 (the normal startup snapshot ran first)
jj --at-op=@ --ignore-working-copy op log -n 1           # N+1 (no new op)
jj --at-op=@ op log -n 1                                 # N+2 (SNAPSHOTS!)
```

Verified counts: `13 -> 13`, `13 -> 14`, `14 -> 14`, `14 -> 15`. So `--at-op=<old>` really is read-only,
but `--at-op=@` is *not*: `is_at_head_operation()` in `cli/src/cli_util.rs` treats `None | Some("@")` as the head, so the working
copy is still snapshotted (the `op log --help` text says to use `--at-op=@ --ignore-working-copy` for non-mutating inspection;
lesson 05's remark "`--at-op=@` ... documented recipe for reading the log without mutating anything" needs the extra flag).

## check.sh additions (sketch)

```bash
  maybe "2.8  a restore op with --what was run" \
    "op_attrs | grep -q 'args: jj op restore --what'" "run: jj op restore --what remote-tracking <op>"
  maybe "2.9  a revert op exists and a bookmark is conflicted or rebased" \
    "op_descs | grep -q '^revert operation '" "run: jj op revert <op>"
  maybe "2.10 an abandon was followed by an integrate (reconcile with a non-head parent)" \
    "op_descs | grep -q 'reconcile divergent operations'" "see 2.10"
  info  "2.11-2.13 are read-only; no durable state to check"
```
