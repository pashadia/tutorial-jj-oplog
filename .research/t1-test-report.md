# T1 test report — jj op-log tutorial, lessons 01–03

**Tutorial under test:** `/home/bogdan/work/google-jj/tutorial-oplog`
**Throwaway copy:** `/tmp/oplog-test-t1.Qt3m/tut` (sandbox at `.../tut/sandbox`)
**jj:** `0.46.0-7d382314f9420b4b8d932245b49c99492c812b9f` (`tools/jj`, first on `PATH`)
**Method:** `./reset-sandbox.sh` once (lesson 01); lessons 02 and 03 continued on the
same sandbox. Every `console` block was run in order, literally, from `sandbox/`.
Lesson 03's two-terminal 3.4 was simulated with a background
`flock -x .jj/repo/op_heads/heads/lock sleep 3` and a timed `jj new`. Extra one-off
experiments used scratch repos under the same `$T`. No `jj`/`git` command was run in
the live repository. Hashes/timestamps are elided where they do not matter.

**Severity rubric used here**

- **BLOCKER** — following the text as written cannot produce the stated result, an
  instruction is impossible, or the lesson's own `check.sh` fails.
- **MINOR** — a quoted message/output differs, or a prose fact is wrong, without
  stopping the exercise.
- **NOTE** — ambiguity, missing context, or cosmetic/readability issue.

**At a glance**

| Lesson | `check.sh` | BLOCKER | MINOR | NOTE |
|---|---|---|---|---|
| 01 — The second history | 3 pass / **1 fail** | 2 | 4 | 2 |
| 02 — The undo toolbox | **7 pass / 0 fail** | 0 | 1 | 4 |
| 03 — Under the hood | 4 pass / **1 fail** | 1 | 3 | 3 |

---

## Lesson 01 — The second history

### Commands run (abridged)

1. `jj op log` (1.1)
2. `echo 'draft' >> src/greet.py`; `jj op log -n 3`; `jj st`; `jj op log -n 3`;
   `jj st`; `jj op log -n 2`; `jj util snapshot` (1.2)
3. `jj op log -T builtin_op_log_oneline`; `jj op log -T builtin_op_log_redacted`;
   the `id.short() … workspace_name …` custom template; `jj op log --no-graph -n 1
   -T 'json(self)'` (1.3)
4. `jj op show`; `jj op log -p -n 4`; `jj op log -d -n 20 | grep -A2 'Changed local
   bookmarks:'`; `jj op diff --from @-- --to @` (1.4)
5. `jj op show @-`; `jj op show @--`; `jj op show @-2`; `jj op show 0000`;
   `jj op show @+` (1.5)
6. `echo 'more draft' >> src/greet.py`; `JJ_OP_USERNAME=colleague
   JJ_OP_HOSTNAME=laptop jj op log -n 2` (1.6)
7. `./check.sh 01`

No command in the main flow failed unexpectedly. The expected failures are listed
below.

### Discrepancies

#### D1.1 — [BLOCKER] 1.1 asks for two `import git …` ops that do not exist

The lesson says:

> A fresh colocated repo is born as: `root()` → `add workspace 'default'`
> → `import git refs` → `import git head` — then everything you did.

1.1 then says:

> Identify: the root op, `add workspace 'default'` (no workspace field, no
> args — why?), **the two `import git …` ops**, the snapshot/commit pairs from the
> seed script, and the bookmark op.

Observed on the freshly reset sandbox — the complete log, not a slice:

```console
$ jj op log
@  8b2aee724ae8 bogdan@nixos default@ 1 second ago, lasted 3 milliseconds
│  point bookmark main to commit 3167903d541dac2867fa08beb6dae74bbe8d9ec1
│  args: jj bookmark set main -r @-
○  3d2a7359d336 bogdan@nixos default@ 1 second ago, lasted 3 milliseconds
│  commit 9aa77d15b5a66f2b0c87379d1bb87c66f9774a31
│  args: jj commit -m 'Add farewell'
○  88ea55e6d4bd bogdan@nixos default@ 1 second ago, lasted 3 milliseconds
│  snapshot working copy
│  args: jj commit -m 'Add farewell'
○  10ca535fb515 bogdan@nixos default@ 2 seconds ago, lasted 3 milliseconds
│  commit e1139cf3f16a271892cd4c23292e2355c0d7e4c8
│  args: jj commit -m 'Initial project'
○  314a44672eae bogdan@nixos default@ 2 seconds ago, lasted 5 milliseconds
│  snapshot working copy
│  args: jj commit -m 'Initial project'
○  a2f697a70a68 bogdan@nixos 2 seconds ago, lasted 5 milliseconds
│  add workspace 'default'
○  000000000000 root()
```

There is **no** `import git refs` and **no** `import git head` op. The other 1.1
targets (root, `add workspace`, two snapshot/commit pairs, bookmark op) are all
present, and every `args:` line matches a command in `reset-sandbox.sh`.

Cause: `reset-sandbox.sh` runs `jj git init --colocate .` in an *empty* directory,
so there are no git refs/commits to import. I verified the lesson's four-op birth
sequence in a scratch repo that had a git commit *before* `jj git init --colocate`:

```console
$ jj op log --no-graph -T 'description ++ "\n"'
import git head
import git refs
add workspace 'default'

```

So the lesson's sentence is true only for a non-empty colocated git repo. In the
provided sandbox, 1.1's "the two `import git …` ops" is impossible to satisfy.

#### D1.2 — [BLOCKER] `jj op log` snapshots first; `jj st` never creates the promised op

The lesson's 1.2 block is:

```console
echo 'draft' >> src/greet.py
jj op log -n 3
jj st
jj op log -n 3        # new top op: "snapshot working copy", args: jj st
jj st
jj op log -n 2        # second jj st added nothing — clean copy, no op
jj util snapshot      # No snapshot needed.
```

Observed (clean reproduction in a second copy):

```console
$ echo 'draft' >> src/greet.py
$ jj op log -n 3
@  8ffc96373c48 bogdan@nixos default@ now, lasted 3 milliseconds
│  snapshot working copy
│  args: jj op log -n 3
○  492b5ac7179d bogdan@nixos default@ now, lasted 2 milliseconds
│  point bookmark main to commit 56845af05405f17ca587e019bb4219ca029bd58a
│  args: jj bookmark set main -r @-
...
$ jj st
Working copy changes:
M src/greet.py
...
$ jj op log -n 3
@  8ffc96373c48 bogdan@nixos default@ now, lasted 3 milliseconds
│  snapshot working copy
│  args: jj op log -n 3
○  492b5ac7179d ...
...
```

The first `jj op log -n 3` already snapshotted the dirty working copy. After
`jj st` the top op is still `args: jj op log -n 3`; **there is no `jj st` op at all**,
and the second `jj op log -n 3` shows the *same* top op. The lesson's quoted comment
`# new top op: "snapshot working copy", args: jj st` is therefore doubly wrong:
the top op is not new, and the snapshot belongs to `jj op log`.

This is internally inconsistent with the lesson's own theory:

> `jj op log` itself snapshots by default. To inspect without mutating:
> `jj op log --at-op=@ --ignore-working-copy`.

Consequence: `./check.sh 01` fails 1.2 (see below). The check's hint ("run a couple
of `jj st` with dirty files first") works only if the tester creates *new* dirt
first; after 1.2 the working copy is clean, so a plain `jj st` creates nothing.

#### D1.3 — [MINOR] A snapshot made by `jj st` records `args: jj status`

The lesson says a `jj st` with dirty files is "attributed to `jj st`" and 1.2
quotes `args: jj st`. Observed when `jj st` really is the command that snapshots
(fresh dirty edit, then `jj st`, nothing else):

```console
$ jj op log -n 1 --no-graph -T 'description.first_line() ++ " | " ++ attributes ++ "\n"'
snapshot working copy | args: jj status
```

jj (0.46.0) canonicalises the built-in alias `st` to `status` in the `args:`
attribute. The same appears in 2.3 (`args: jj status`). This does **not** break
`check.sh`: its pattern is `grep -q '^args: jj st'`, and `jj st` is a prefix of
`jj status`, so the loose grep matches. The lesson's literal quote is still wrong.

#### D1.4 — [MINOR] 1.4's `jj op log -d -n 20` emits 126 lines of warning noise

The expected output in 1.4 is just the `Changed local bookmarks:` match. Observed
(measured at the exact lesson-01 state, 8 ops, 4 warning blocks):

```console
$ jj op log -d -n 20 2>&1 >/dev/null | wc -l
126
$ jj op log -d -n 20 2>&1 >/dev/null | head -6
Warning: In template expression
 --> 1:1
  |
1 | format_commit_summary_with_refs(self, format_commit_ref_names(bookmarks))
  | ^-----------------------------------------------------------------------^
  |
  = In alias `format_commit_summary_with_refs(commit, refs)`
...
  = Failed to load short-prefixes index
Failed to resolve short-prefixes disambiguation revset
Workspace `default` doesn't have a working-copy commit
```

The warnings are on **stderr**, so the pipe to `grep` still yields the one match:

```console
$ jj op log -d -n 20 2>/dev/null | grep -c 'Changed local bookmarks:'
1
```

With `-n 3` (not reaching the birth ops) the stderr count is 0. The warning block is
triggered by diffing the `add workspace 'default'` op against the root view, which
has no working-copy commit for `default`. The lesson does not mention this at all,
and the line `Workspace 'default' doesn't have a working-copy commit` reads like
the degenerate state 2.4 teaches, so a tester may think the repo is broken.

#### D1.5 — [MINOR] `jj op show 0000` prints the same 126-line warning block

1.5 says:

```console
jj op show 0000       # root op by prefix
```

Observed:

```console
$ jj op show 0000 2>&1 >/dev/null | wc -l
126
$ jj op show 0000 2>/dev/null
000000000000 root()
$ jj op show 0000 >/dev/null 2>&1; echo $?
0
```

The command succeeds and the root op is shown, but only after the same four
template-warning blocks (short-prefixes index + `Workspace 'default' doesn't have a
working-copy commit`). The lesson says only "root op by prefix". This is the same
class of warning that 2.6 later documents for very old `--at-op` targets; here it
is undocumented.

#### D1.6 — [MINOR] `jj op show @+` error wording differs from the quoted comment

Lesson comment:

```console
jj op show @+         # Error: resolved to no operations
```

Observed:

```console
$ jj op show @+
Error: The "@+" expression resolved to no operations
$ echo $?
1
```

The phrase "resolved to no operations" is present (and the theory's
"`resolved to more than one operation` … or `resolved to no operations`" is
directionally right), but the exact `Error:` line is not what the lesson quotes.
The same wording issue is likely for the "more than one" case; not exercised here.

#### D1.7 — [NOTE] "exactly three lines" is only true for ops with attributes

The theory says "A default `jj op log` entry is exactly **three lines**". The
`add workspace 'default'` entry is two lines and the root entry is one line
(the lesson explains why immediately afterwards), so the absolute "exactly" is
slightly at odds with its own example. Cosmetic.

#### D1.8 — [NOTE] `-n 20` exceeds the log length

At lesson-01 time the log has 8 entries (root included); `-n 20` is harmless but
guarantees the diff walk reaches the root, which is precisely what triggers D1.4.
`-n 4` would show the bookmark op and avoid the noise.

### Matched (not discrepancies)

- Default `jj op log` format: 12-hex id, `user@host`, `workspace@`, relative time +
  `lasted N milliseconds`, `args:` line; `add workspace 'default'` has neither a
  workspace field nor `args:`; root displayed as `000000000000 root()`.
- Two snapshot/commit pairs from the seed script; bookmark op; all `args:` lines
  match `reset-sandbox.sh`.
- `jj util snapshot` prints `No snapshot needed.` on a clean copy.
- 1.3: `builtin_op_log_oneline`, `builtin_op_log_redacted` (`user-64dc
  workspace-ab88@` + `(redacted)`), the custom template, and `json(self)` all work;
  `workspace_name` has the trailing `@`, JSON has the bare name.
- 1.4: `jj op show` shows `Changed commits:` then `Changed working copy
  default@:`; `-p` shows `Modified regular file src/greet.py`; the commit op shows
  `Modified JJ-COMMIT-DESCRIPTION:`; `jj op diff --from @-- --to @` prints the
  expected sections, `+`/`- (absent)` bookmark lines.
- 1.5: `@-`, `@--` work; `jj op show @-2` exactly matches
  `Error: Operation ID "@-2" is not a valid hexadecimal prefix`; `0000` resolves
  the root; `@+` errors (wording aside).
- 1.6: the `JJ_OP_USERNAME`/`JJ_OP_HOSTNAME` override works and the new snapshot op
  is attributed to `colleague@laptop`.
- Theory: `jj op log` snapshots by default; `--at-op=@ --ignore-working-copy`
  writes no op (verified); `jj commit` writes two ops.

### `check.sh 01` results

Verbatim, after the full lesson:

```text
Lesson 01
  FAIL  1.2  a snapshot op created by 'jj st' exists
        → run a couple of jj st with dirty files first: jj st snapshots the working copy
  PASS  1.3/1.5  op-log templates and the op grammar were exercised
  PASS  1.6  an op is attributed to colleague@laptop
  PASS  1    sandbox still sane (seeded history reachable)

Result: 3 passed, 1 failed.
```

The 1.2 failure is **inherent to the text**, not a tester mistake. A clean-copy
reproduction of the 1.2 block confirmed the top op is `args: jj op log -n 3` and no
`args: jj st/status` op exists. The check's hint is also misleading: after 1.2 the
copy is clean, so simply re-running `jj st` does nothing; a *new* dirty edit is
needed. I verified that a new dirty edit + `jj st` produces `args: jj status`, which
makes the check pass (as a prefix match), and the full `check.sh 01` then reports
4/0 — but that required deviating from the lesson.

### Clarity issues

- The 1.2 comment and the theory contradict each other; a student who reads the
  theory will expect `jj op log` to snapshot, then be confused by the comment.
- The 1.4/1.5 warning walls are 126 lines of stderr and include a phrase that looks
  like a corrupt-workspace error. They deserve one sentence in the lesson (and
  perhaps `2>/dev/null` in 1.5's root example).
- "attributed to `jj st`" should say "`args: jj status`" (jj canonicalises the
  alias), or at least be shown as an example.
- 1.1's "the two `import git …` ops" is silent about the precondition (a non-empty
  colocated git repo). The why-question about `add workspace 'default'` is answered
  by the theory, but the missing imports are not.

### Suggested minimal fixes

1. **1.2:** put `jj st` *before* the first `jj op log`, e.g.
   `echo ...; jj st; jj op log -n 3   # new top op: snapshot, args: jj status` and
   delete/rewrite the stale `# new top op …` comment on the second `jj op log`.
   Alternatively, add a second dirty edit before a deliberate `jj st` and leave the
   op-log call in place — but then say plainly that `jj op log` snapshotted first.
2. **1.1 / theory:** change "the two `import git …` ops" to "note the *absence* of
   `import git …` ops here: `jj git init --colocate` on an empty directory has
   nothing to import; you see them when the git repo already has refs". If the
   tutorial wants them present, seed the sandbox with a git commit before
   `jj git init --colocate`.
3. **1.2 quote:** change `args: jj st` to `args: jj status` everywhere (or note the
   alias canonicalisation).
4. **1.4:** use `-n 4` (enough for the bookmark op) or add `2>/dev/null`, and add a
   sentence explaining the birth-op warnings; then reference that sentence in 1.5.
5. **1.5:** change `# Error: resolved to no operations` to
   `# Error: The "@+" expression resolved to no operations`.
6. **1.7:** soften "exactly three lines" to "three lines when the op has a
   workspace and attributes (two/one otherwise)".

---

## Lesson 02 — The undo toolbox

### Commands run (abridged)

1. `jj describe -m "work in progress"`; `jj undo`; `jj redo`; `jj redo`;
   `jj undo && jj undo`; `jj op log -n 4` (2.1)
2. `jj new -m "step one"`; `jj describe -m "step two"`;
   `jj bookmark set feature -r @`; `jj op log -n 6`; `jj op revert @-`;
   `jj op log -n 3` (2.2)
3. `echo 'precious draft' >> src/greet.py`; `jj st`; `jj op log -n 1`;
   `jj op restore @----`; `jj log`; `grep precious src/greet.py`;
   `jj op log -n 2`; `jj op restore @-`; `grep precious src/greet.py` (2.3)
4. `jj op restore 000000000000`; `jj log`; `jj undo` (2.4)
5. `jj new -m "keep me"`; `jj op log -n 2 -T 'id.short() …'`;
   `jj op abandon @-`; `jj op log -n 2`; `jj util gc --expire now` (2.5)
6. `jj --at-op @-- log`; `jj --at-op @----- log`; `jj --at-op @ log`;
   `jj --at-op 000000000000 log` (2.6)
7. `jj --no-integrate-operation new -m "detached experiment"`;
   `jj op log -n 2`; `jj --at-op <printed id> log`; `jj op integrate <printed id>`;
   `jj op log -n 2` (2.7; the placeholder was replaced with the printed 12-hex id)
8. `./check.sh 02`

Expected non-zero exits: `jj redo` (`Nothing to redo`), `grep precious` after the
restore (draft gone), `jj log` after restoring to root, and the root `--at-op`
variant. Everything else exited 0.

### Discrepancies

#### D2.1 — [MINOR] 2.6's "the root works too" is false

The lesson says:

> Jumping to *very* old ops (try the root: `jj --at-op 000000000000 log`) works
> too, but prints template warnings about the short-prefixes index — the commit
> index has to be rebuilt on demand for ops that old.

Observed:

```console
$ jj --at-op 000000000000 log
Warning: In template expression
...
Failed to resolve short-prefixes disambiguation revset
Workspace `default` doesn't have a working-copy commit
Error: Workspace `default` doesn't have a working-copy commit
$ echo $?
1
```

It prints the predicted short-prefixes warnings, but it does **not** work: the
root view has no workspace, so `jj log` fails. This is the same degenerate-view
condition 2.4 deliberately demonstrates. The main 2.6 commands (`@--`, `@-----`,
`@`) all work and show the expected three states.

#### D2.2 — [NOTE] 2.3 does not actually demonstrate the "restore snapshots first" safety net

The theory calls this "the killer safety mechanic (undocumented, verified by
experiment): `jj op restore` snapshots the working copy first". In 2.3, however,
`jj st` runs *before* the restore and does the snapshot, so the restore has nothing
to snapshot. The draft survives, but it was captured by `jj st`, not by `restore`.

I verified the claim separately in a scratch repo: dirty file, then
`jj op restore @-` as the *first* jj command after the edit, yields:

```console
$ jj op log -n 3 --no-graph -T 'description.first_line() ++ " | " ++ attributes ++ "\n"'
restore to operation b782… | args: jj op restore @-
snapshot working copy | args: jj op restore @-
commit 915d… | args: jj commit -m C
```

So the mechanic is real; the exercise just doesn't exercise it. The comment
`jj st # snapshot op captures the draft` is accurate but defeats the lesson's
stated point.

#### D2.3 — [NOTE] 2.1's "prints two lines" is really four (two semantic + WC update)

`jj undo` printed:

```text
Undid operation: 22db0eac1d6b (…) describe commit 40a3…
Restored to operation: aaa7c91ef119 (…) snapshot working copy
Working copy  (@) now at: xlkpkppz 40a3fafe (no description set)
Parent commit (@-)      : wxslqllu 3167903d main | Add farewell
```

`jj redo` similarly prints `Restored to operation:` plus the two working-copy lines.
The two semantic lines the lesson names are correct; the line-count claim is not
literal. The `--quiet` claim was verified separately: both commands are silent with
`--quiet`.

#### D2.4 — [NOTE] 2.4's `jj log` is a hard error plus ~100 warning lines, not merely "noisy"

After `jj op restore 000000000000`, the lesson says:

> run `jj log` (noisy: the workspace has no working-copy commit)

Observed: 126 lines of template warnings on stderr, ending in

```text
Error: Workspace `default` doesn't have a working-copy commit
```

and exit status 1. The lesson's parenthetical is directionally right and its
theory says "subsequent commands complain", but "noisy" understates a fatal
`Error:`. `jj undo` then succeeds (with the same warning wall), exactly as the
lesson says ("which always works, because the op log itself was never touched").

#### D2.5 — [NOTE] 2.5's "trim history" actually abandons the 2.4 undo op

`jj op log -n 2` before the abandon shows:

```text
@  914930c7cc59 new empty commit
○  44e18c753e2e undo: restore to operation c85e2756…
```

So `jj op abandon @-` abandons the `undo` op left by 2.4 (not a generic history
op). The observable result matches the text — `Abandoned 1 operations and
reparented 1 descendant operations.`, and the head changes from `914930c7cc59` to
`555682156d65` — but the target is state-dependent and worth a sentence.

### Matched (not discrepancies)

- 2.1: `jj describe`/`undo`/`redo` ladder; `Error: Nothing to redo`;
  `undo: restore to operation <full 128-hex>` and `redo: …` descriptions;
  `Undid operation:` / `Restored to operation:`; the chain-collapsing target
  (`undo` op points at the old snapshot, not the redo op); `--quiet`.
- 2.2: reverting the middle describe leaves the bookmark op in place; the bookmark
  stays on the commit, which is now described `step one`; `jj op log -n 3` shows
  the revert op and the surviving bookmark op.
- 2.3: `jj st` snapshots; `jj op log -n 1` shows the snapshot; `jj op restore
  @----` prints `Restored to operation: … new empty commit`; `jj log` is back at
  the target; `grep precious` exits 1 (draft gone); `jj op log -n 2` shows the
  snapshot op *before* the restore op; `jj op restore @-` restores the snapshot;
  `grep precious` finds `precious draft` again.
- 2.4: the exact warning `Warning: The current workspace 'default' no longer
  exists after this operation. The working copy was left untouched.` (plus an
  extra `Hint:` line) is printed; `jj undo` always works.
- 2.5: `Abandoned 1 operations and reparented 1 descendant operations.`; the head
  gets a new id; `jj util gc --expire now` succeeds.
- 2.6: `@--`, `@-----`, and `@` all work and show the expected past/present states.
- 2.7: exact message `Operation left uncommitted because
  --no-integrate-operation was requested: ba07bb17a157`; the op is absent from
  `jj op log -n 2`; `--at-op ba07bb17a157 log` shows it; `jj op integrate` makes it
  the new top op.
- Theory (verified separately): `jj op revert 000000000000` →
  `Error: Cannot revert root operation`; `jj op revert 'root()'` →
  `Error: Operation ID "root()" is not a valid hexadecimal prefix`;
  `jj op abandon 000000000000` → `Error: Cannot abandon the root operation`;
  `jj op abandon @` → `Error: Cannot abandon the current operation …` + `Hint:
  Run jj undo …`; `jj util gc --expire 2w` → `Error: --expire only accepts 'now'`;
  `jj util gc --expire now` works; `jj op restore` really does snapshot first.

### `check.sh 02` results

Verbatim:

```text
Lesson 02
  PASS  2.1  an undo op and a redo op exist
  PASS  2.2  a revert op exists
  PASS  2.3  the snapshot safety net: 'precious draft' survived time travel
  PASS  2.3  a restore op exists
  PASS  2.5  a commit described 'keep me' exists
  PASS  2.7  the detached experiment was integrated
  PASS  2  sandbox still sane (seeded history reachable)

Result: 7 passed, 0 failed.
Lesson 02 complete ✔ — proceed to the next lesson.
```

No check issues in this lesson.

### Clarity issues

- 2.3's safety-net lesson is undermined by its own `jj st`; the text should either
  drop it or add a second dirty edit immediately before the restore.
- 2.4 says "noisy"; the actual `jj log` is a fatal `Error:` plus ~100 warning
  lines. Worth quoting the final error line.
- 2.5's `@-` is the previous exercise's `undo` op; the exercise is still valid, but
  "trim history" is a slightly misleading label for that specific target.
- 2.7's `⟨id⟩` is clearly a placeholder, but a literal copy-paste will fail with
  `Operation ID "⟨id⟩" is not a valid hexadecimal prefix`; the lesson does say
  "Remember the id jj printed", so this is only a small speed bump.

### Suggested minimal fixes

1. **2.3:** remove the `jj st` line (or follow it with a second dirty edit) so the
   draft is actually unsnapshotted when `jj op restore @----` runs; update the
   comments to say the *restore* wrote the snapshot op. If you keep `jj st`, say
   plainly that it is doing the capture and that the restore would also have done
   it.
2. **2.6:** replace "works too" with "at the root itself it prints the same
   short-prefixes warnings and then fails with `Error: Workspace 'default' doesn't
   have a working-copy commit`, because the root view has no workspace"; keep the
   main three commands.
3. **2.4:** say "`jj log` fails (exit 1) after ~100 lines of template warnings,
   ending in `Error: Workspace 'default' doesn't have a working-copy commit`"
   instead of just "noisy".
4. **2.1:** say "the two semantic lines are `Undid operation:` / `Restored to
   operation:`; jj also prints its usual working-copy update lines" or show the
   full output.
5. **2.5:** add "(here `@-` is the undo op 2.4 just created)".

---

## Lesson 03 — Under the hood

### Commands run (abridged)

1. `find .jj/repo -maxdepth 2 -type d | sort`;
   `cat .jj/repo/op_store/type .jj/repo/op_heads/type .jj/repo/index/type`;
   `ls .jj/repo/op_heads/heads/`;
   `wc -c .jj/repo/op_store/operations/* | tail -1` (3.1)
2. `jj op log -n 1 --no-graph -T 'id ++ "\n"'`;
   `ls .jj/repo/op_store/operations/ | wc -l`;
   `ls .jj/repo/op_store/views/ | wc -l` (3.2)
3. `strings .jj/repo/op_store/operations/$(ls .jj/repo/op_store/operations | head -1)`
   (3.3)
4. Two-terminal lock test simulated:
   `flock -x .jj/repo/op_heads/heads/lock sleep 3 &` then, after `sleep 0.2`,
   `jj new -m "blocked?"`; wall-clock timed in the shell (3.4)
5. `ls .jj/repo/index/op_links | wc -l`; `jj debug reindex`;
   `ls .jj/repo/index/op_links | wc -l` (3.5)
6. `for i in $(seq 1 20); do jj describe -m "churn $i" >/dev/null; done`;
   `ls .jj/repo/op_store/operations | wc -l`; `jj op abandon ..@----`;
   `jj util gc --expire now`; `ls .jj/repo/op_store/operations | wc -l` (3.6)
7. `./check.sh 03`

No unexpected failures. `jj debug reindex` exited 0; `jj op abandon` and
`jj util gc` exited 0.

### Discrepancies

#### D3.1 — [BLOCKER] `check.sh 03`'s 3.5 check cannot pass after 3.6

The lesson's own order is 3.5 (reindex) **then** 3.6 (20 describes). Observed:

```console
$ ls .jj/repo/index/op_links | wc -l
27
$ jj debug reindex
Finished indexing 17 commits.
  (now: 1 op_link — the lesson's "# 1" is correct *here*)
...
$ for i in $(seq 1 20); do jj describe -m "churn $i" >/dev/null; done
$ ls .jj/repo/op_store/operations | wc -l
44
$ jj op abandon ..@----
Abandoned 40 operations and reparented 4 descendant operations.
$ jj util gc --expire now
$ ls .jj/repo/index/op_links | wc -l
22
```

Then:

```text
Lesson 03
  PASS  3.1  the op store is a separate file store
  PASS  3.2  ids are 128-hex and views dedupe
  FAIL  3.5  the index was rebuilt (few op_links left)
        → run: jj debug reindex
  PASS  3.6  history was trimmed (op log is short)
  PASS  3  sandbox still sane (seeded history reachable)

Result: 4 passed, 1 failed.
```

`check.sh` tests `[ "$(ls .jj/repo/index/op_links | wc -l)" -le 5 ]`. The 20
describes each add an index segment/op_link, and `jj util gc` explicitly does not
touch the index (the lesson says so itself: "it never touches `op_heads/` or the
`index/` directory. Only `jj debug reindex` shrinks the index."). So a tester who
follows 3.5 then 3.6 can never get a green 3.5. Re-running `jj debug reindex` by
hand after 3.6 brings it back to 1 and makes the check pass — I verified that — but
the lesson does not ask for that, and doing so deviates from the text.

#### D3.2 — [MINOR] 3.6's `>/dev/null` does not silence jj's working-copy lines

The loop is written as:

```console
for i in $(seq 1 20); do jj describe -m "churn $i" >/dev/null; done
```

Observed: 40 lines (two per iteration) still appear, because jj writes the
working-copy update to **stderr**:

```text
Working copy  (@) now at: notvrzow eb2860bc (empty) churn 1
Parent commit (@-)      : xrvpztsk a91ac7dc (empty) detached experiment
Working copy  (@) now at: notvrzow 612c295e (empty) churn 2
Parent commit (@-)      : xrvpztsk a91ac7dc (empty) detached experiment
...
```

`jj describe -m x >/dev/null` alone shows the same two lines; adding `2>&1` fully
silences them (`jj describe -m x >/dev/null 2>&1` prints nothing). The lesson
clearly intends a quiet loop.

#### D3.3 — [MINOR] "30 `jj describe`s → 61 ops" is false for a clean working copy

The theory says:

> Growth is ~one op + one view + one index segment per mutating command — double
> when a snapshot precedes it (30 `jj describe`s → 61 ops, ~360 bytes per op
> *including* the view).

Measured in a fresh scratch repo (two seed commits, clean working copy):

```text
ops before 30 describes: 5
ops after 30 describes: 35   (delta 30)
views: 35
avg bytes/op: 316
max op size: 325; min op size: 222
```

i.e. **+30 ops, not +60**, because a `jj describe` on a clean working copy writes
one op (no snapshot op). To reach 61 you need a dirty edit before each describe (or
a `jj commit`, which does snapshot+commit). The "~360 bytes per op including the
view" part is roughly right (316 B/op + ~120 B/view in this repo). The 3.6 loop
itself confirms the ~1-op-per-describe rate: the sandbox had 24 ops before the
loop and 44 after (+20 describes), so the pre-abandon count is consistent with +20.

#### D3.4 — [MINOR] The empty-`heads/` error is quoted without its "Internal error" wrapper

The theory says:

> An empty `heads/` dir is the one unrecoverable state:
> `Error: Corrupt repository: no head operation`.

Observed (scratch repo; moved `op_heads/heads/*` away, then ran `jj st`/`jj op log`):

```text
Internal error: Unexpected error from operation heads store
Caused by:
1: Failed to read operation heads
2: Corrupt repository: no head operation
```

Exit status 255. The quoted phrase is the *cause* line, not the top-level error;
the lesson's exact-quote convention overstates it. (I restored the head files and
the repo was fine.)

#### D3.5 — [NOTE] 3.1's `cat` concatenates the three type files with no separators

```console
$ cat .jj/repo/op_store/type .jj/repo/op_heads/type .jj/repo/index/type
simple_op_storesimple_op_heads_storedefault
```

The files have no trailing newlines, so the output runs together. It is readable
if you know the three expected values, but a `for`/`paste` loop would be clearer:

```console
for f in op_store op_heads index; do echo "$f/type: $(cat .jj/repo/$f/type)"; done
```

#### D3.6 — [NOTE] The lock paths in the table do not exist while idle

The theory table lists `.jj/working_copy/working_copy.lock` and
`.jj/repo/git_import_export.lock`. In a clean, idle sandbox `ls` shows:

```text
.jj/working_copy/checkout
.jj/working_copy/tree_state
.jj/working_copy/type
(no working_copy.lock)
(no .jj/repo/git_import_export.lock)
```

These locks are created on demand. The op-heads lock is the one exercised in 3.4;
it likewise did not exist before `flock` created it. A one-line "created on
demand" would prevent a tester from thinking the paths are wrong. Also note
`flock` is util-linux, not available by default on macOS; the exercise assumes
Linux/NixOS.

#### D3.7 — [NOTE] Op/view sizes are state-dependent and can exceed the quoted ranges

The theory says operations are "~220–330 bytes" and views "~60–300 bytes".
Measured:

- Normal describe ops: 222–325 B (matches).
- `undo` ops (description contains a full 128-hex target): 358–366 B (slightly
  above the range).
- Views in the post-lesson sandbox (with bookmarks `main`/`feature`): 448 B each
  (above the 300 B upper bound); views in a bookmark-free scratch repo: ≤124 B.

The ranges are approximations, but the upper bounds are not universal. Worth a
"typically" or a note that bookmark/remote-ref-heavy views are larger.

### Matched (not discrepancies)

- 3.1: `find` shows the expected `op_store/{operations,views}`,
  `op_heads/heads`, `index/{changed_paths,op_links,segments}`; type files contain
  `simple_op_store`, `simple_op_heads_store`, `default`; one zero-byte head marker;
  `wc -c operations/*` = 7237 total over 23 ops (~315 B/op).
- 3.2: `id` is exactly 128 hex chars; 23 operation files, 17 view files — fewer
  views, so dedupe is observable.
- 3.3: `strings` shows the description (`restore to operation …`), hostname
  (`nixos`), username (`bogdan`), and `args` key.
- 3.4: the background `flock` held the op-heads lock; `jj new -m "blocked?"`
  waited silently and succeeded after ~3 s (the theory quotes 2.7 s; same
  behavior), exit 0, no lock message.
- 3.5: `jj debug reindex` printed `Finished indexing 17 commits.` and reduced
  `op_links` from 27 to 1 (the lesson's `# 1` is correct at this point).
- 3.6: the churn loop, `jj op abandon ..@----` (`Abandoned 40 operations and
  reparented 4 descendant operations.`), and `jj util gc --expire now` worked;
  operation files went 44 → 4; the post-gc op log has 5 entries (root + 4), well
  under the check's ≤15.
- Theory: root op is virtual (no `0000…` file in `operations/`); op ids are
  128-hex; views dedupe; `--expire` accepts only `now` (verified `2w` is rejected
  with `Error: --expire only accepts 'now'`); `jj debug reindex` is the index
  shrinker; gc leaves `op_heads/` and `index/` alone.

### `check.sh 03` results

Verbatim, after the full lesson (3.5 then 3.6, as written):

```text
Lesson 03
  PASS  3.1  the op store is a separate file store
  PASS  3.2  ids are 128-hex and views dedupe
  FAIL  3.5  the index was rebuilt (few op_links left)
        → run: jj debug reindex
  PASS  3.6  history was trimmed (op log is short)
  PASS  3  sandbox still sane (seeded history reachable)

Result: 4 passed, 1 failed.
```

The 3.5 failure is caused by the lesson's own 3.6, not by the tester. Re-running
`jj debug reindex` after 3.6 (a deviation) leaves 1 op_link and makes `check.sh 03`
report 5/0 — I verified that follow-up.

### Clarity issues

- 3.5's `# 1` is true only until 3.6 runs; the check should say so, or 3.5 should
  come last.
- 3.6's `>/dev/null` is misleading; `2>&1` is needed.
- The growth-number claim should distinguish clean describes from dirty ones.
- The empty-heads quote should show the full chained error, or say "ends with".
- The `cat` output runs together; the lock files are created on demand; `flock`
  is Linux-specific.
- 3.3's `ls … | head -1` picks a lexicographically first op, not the oldest or
  newest; harmless, but a fixed prefix (e.g. `$(jj op log -n 1 -T id)`) would be
  reproducible if the lesson wants a specific op.

### Suggested minimal fixes

1. **3.5/3.6 ordering:** either move `jj debug reindex` after 3.6 (and say so in
   3.5's `# 1` comment), or append `jj debug reindex` to 3.6, or change
   `check.sh`'s 3.5 check to something that holds after 3.6 (e.g. require at least
   one `op_links` entry and a "reindex was observed" marker — but `check.sh` is
   read-only, so reordering is the cleanest).
2. **3.6:** use `>/dev/null 2>&1` in the loop.
3. **Growth claim:** change "30 `jj describe`s → 61 ops" to "30 describes on a
   clean working copy → 30 ops; with an edit before each (so each command also
   snapshots), → ~61 ops".
4. **Empty heads:** quote the full block:
   `Internal error: Unexpected error from operation heads store` /
   `Caused by: … 2: Corrupt repository: no head operation`, or write "ends with
   `Corrupt repository: no head operation`".
5. **3.1:** use a `for` loop to print `type` files separately; add "lock files are
   created on demand" to the table.
6. **Sizes:** say "typically 220–370 B for operations and 60–450 B for views,
   depending on bookmarks/remote refs".

---

## Cross-cutting tooling observations

### T1 — [MINOR] `check.sh` mutates a dirty sandbox, despite "never modifies"

`check.sh`'s header says "Never modifies the sandbox. Re-runnable." Its helpers
(`op_descs`, `op_attrs`, `op_users`) call `jj op log`, which snapshots a dirty
working copy by default. Verified in a scratch copy with a dirty file:

```text
ops before dirty check: 9
ops after dirt (no jj): 9
ops after check.sh 01: 10
top op after check:
snapshot working copy | args: jj op log --no-graph -T 'attributes ++ "\n"'
```

So running `check.sh` with uncommitted edits writes a snapshot op. It did not
affect the results in this run because each lesson ends with a clean working copy,
but the "never modifies" contract is false in general. Fix: add
`--ignore-working-copy` to the check helpers (and the `seeded()` `jj log`), or
soften the comment.

### T2 — [NOTE] `check.sh 01`'s 1.2 hint is not directly actionable

The failure hint says "run a couple of `jj st` with dirty files first: `jj st`
snapshots the working copy". After lesson 1.2 the working copy is clean, so a plain
`jj st` does nothing. The tester must create *new* dirt. The hint should say so.
(Once new dirt is created, `args: jj status` satisfies the prefix grep, as noted
in D1.3.)

### T3 — [NOTE] The 1.4/1.5 warning block is a generic "old op" behaviour

The 126-line warning block in D1.4/D1.5 is the same short-prefixes-index warning
2.6 documents for `--at-op` on very old ops. It is triggered whenever an op-diff
reaches the birth ops. One explanation in 1.4 (and a pointer from 1.5) would cover
all three places, and would stop the `Workspace 'default' doesn't have a
working-copy commit` line from looking like corruption.

---

## Priority for fixes

1. **Lesson 01 / 1.2 (BLOCKER):** the `jj op log`-first ordering makes the exercise's
   central observation false and makes `check.sh 01` fail. Reorder `jj st` before
   the first `jj op log` (or explicitly demonstrate that `jj op log` writes the
   snapshot), and fix the `args: jj st` → `args: jj status` quote.
2. **Lesson 01 / 1.1 (BLOCKER):** "the two `import git …` ops" do not exist in the
   sandbox. Either seed git before `jj git init --colocate`, or rewrite 1.1 to
   explain the absence and the precondition.
3. **Lesson 03 / 3.5–3.6 (BLOCKER):** `check.sh 03`'s 3.5 check fails after 3.6 by
   construction. Reorder the exercises or append `jj debug reindex` to 3.6.

Secondary: document/avoid the birth-op warning wall (1.4/1.5), fix 2.6's
"root works too" claim, silence 3.6's loop with `2>&1`, and correct the growth
number.
