# T2 test report — lessons 04 and 05 (jj 0.46.0)

**Tested text, not prior jj knowledge.** Throwaway copy: `/tmp/oplog-test-t2.Yzqw/tut`
(deleted after this report). `PATH` had `tut/tools` first; `jj --version` printed
`jj 0.46.0-7d382314f9420b4b8d932245b49c99492c812b9f`.

Primary sequence: one `./reset-sandbox.sh`, lesson 04 exactly as written, then lesson 05
exactly as written on the resulting state. Additional resets in the same throwaway copy were
used only for the clearly-labelled diagnostic replays that isolate 4.5, 4.7, 5.1 and 5.6.
No jj/git command was run in the live repository.

## Setup / harness note

**MINOR (latent, timing-dependent).** One invocation of `./reset-sandbox.sh` printed the full
success banner but exited 3. Mechanism: the script uses `set -euo pipefail` and ends with
`jj op log … | head -6`; the fresh log has 7 operations (including root), so `head` closes the
pipe. jj exits 3 when it gets SIGPIPE, and `pipefail` propagates it. Five immediate reruns
exited 0, so it is a scheduling-dependent flake. This breaks `./reset-sandbox.sh && …` chains.

Suggested fix: replace the final pipeline with `jj op log -n 6 …`, or add `|| true`, or avoid
`pipefail` for that line.

---

## Lesson 04 — Workspaces: one repo, many working copies, one log

### Commands run (abridged)

- **4.1** from `sandbox/`: `jj workspace add ../side-task`; `jj workspace list`;
  `cat ../side-task/.jj/repo`; `jj op log -n 3`; from `../side-task`, `jj op log -n 3`.
- **4.2** from `../side-task`: `jj describe -m "side work"`; from `../sandbox`,
  `jj op log -n 2`; `jj log -T 'commit_id.short() ++ " " ++ working_copies ++ "\n"' --no-graph`.
- **4.3** `OLD=$(jj op log -n 1 … | cut -c1-12)`; append `interference`; `jj st`;
  from `../side-task`, capture `HEAD=$(jj op log -n 1 …)`, `jj op restore "$OLD"`;
  back in `../sandbox`, `jj st`.
- **4.4** `jj workspace update-stale`; `grep interference src/greet.py`;
  `jj op log -n 1`; `jj op log -n 4`.
- **4.5** append `more interference` without snapshotting; from `../side-task`,
  `jj op restore "$OLD"`; back in `../sandbox`, `jj workspace update-stale`;
  `jj op log -n 6`.
- **4.6** from `../side-task`: create `side.txt`, `jj st`; from `../sandbox`,
  `jj undo`; `jj undo --allow-cross-workspace`; from `../side-task`, `jj st`,
  `jj workspace update-stale`; back in `../sandbox`, `jj st`.
- **4.7** from `../side-task`: `jj edit 'default@'`; append `side edit` to `README.md`;
  `jj st`; from `../sandbox`, `jj st`; append `main edit` to `src/greet.py`; `jj st`;
  `jj log -n 5`.

### Matches (brief)

- 4.1: workspace created; `../side-task/.jj/repo` is a text pointer to the shared repo;
  both workspaces show the same log. The `add workspace 'side-task'` op has no workspace tag;
  `create initial working-copy commit in workspace side-task` is tagged `side-task@`.
- 4.2: side-task's `describe` op is tagged `side-task@`; `working_copies` prints
  `side-task@` / `default@` as expected.
- 4.3: the stale error appears exactly as quoted (plus an extra `See https://…` line), names
  the working copy's last op (the snapshot), not the restore op, and subsequent commands
  (including `jj op log`) refuse.
- 4.4: `update-stale` on the clean path writes no new op; the head remains the restore op;
  the interference text is gone from disk; the snapshot op containing it is still in the log.
- 4.6: the cross-workspace `jj undo` refusal, `--allow-cross-workspace`, side-task staleness,
  `update-stale`, and final sandbox `jj st` all behave as described (the word `Fresh` is not
  literally printed; see clarity issues).
- 4.7: `jj edit 'default@'` produces no warning and puts both workspaces on one change.

### Discrepancies

1. **BLOCKER — 4.5 does not demonstrate the dirty path.**

   As written, the second `jj op restore "$OLD"` is a no-op: 4.3's restore already left the
   head at a view equal to `$OLD`, and 4.4 wrote no op. Observed:

   ```text
   Restored to operation: <old-op> (…) describe commit <…>
   Nothing changed.
   ```

   Then:

   ```text
   Attempted recovery, but the working copy is not stale.
   ```

   No `Concurrent modification detected, resolving automatically.` was printed, no
   `reconcile divergent operations` op was created, and `jj op log -n 6` showed a
   `snapshot working copy` op with `args: jj workspace update-stale` instead of the expected
   fork-and-heal pair.

   Expected (lesson): `jj workspace update-stale` prints
   `Concurrent modification detected, resolving automatically.` /
   `Updated working copy to fresh commit …`, and the log shows a snapshot op plus a
   `reconcile divergent operations` op.

   Root cause: `$HEAD`, captured in 4.3 as the snapshot op, is never used; 4.5 restores to
   `$OLD` instead of `$HEAD`. `jj op restore "$HEAD"` is the op that moves the view *forward*
   to the snapshotted interference, making the dirty working copy stale.

   Diagnostic verification: replaying 4.1–4.4 and changing only 4.5's `"$OLD"` to `"$HEAD"`
   produced the exact expected messages, a dirty snapshot op and a two-parent reconcile.
   This is not merely a consequence of 4.5's failure: 4.7 fails independently (next item).

2. **BLOCKER — 4.7's “silently Fresh — your old tip, same tree” is false; the exercise cannot
   reach the divergent markers.**

   Observed after side-task's `jj st` snapshot of the shared change:

   ```text
   Error: The working copy is stale (not updated since operation <hash>).
   Hint: Run `jj workspace update-stale` to update it.
   See https://docs.jj-vcs.dev/latest/working-copy/#stale-working-copy for more information.
   ```

   The same error came from the subsequent `jj st` and `jj log -n 5`; no two tips and no
   `(divergent)` markers appear. Expected (lesson): `jj st` is “silently Fresh — your old tip,
   same tree”, then the second edit snapshots and `jj log` shows the change with two tips.

   Cause: side-task's snapshot rewrote the shared working-copy commit and jj updated **both**
   `default@` and `side-task@` to the rewritten commit. In a diagnostic replay, `jj op show
   <side-task-snapshot>` printed:

   ```text
   Changed working copy default@:
   + <new-commit> (divergent)
   - <old-commit> (hidden)
   Changed working copy side-task@:
   + <new-commit> (divergent)
   - <old-commit> (hidden)
   ```

   The new commit's tree includes the `README.md` edit, so the sandbox's recorded tree no
   longer matches the desired tree: `check_stale` returns `WorkingCopyStale`. The lesson's
   theory table already says staleness is about tree changes; the prose “Neither workspace was
   ever *stale* — the trees matched” contradicts it.

   Diagnostic verification of a fix: after side-task's snapshot, running
   `jj workspace update-stale` in the sandbox (instead of `jj st`) with the uncommitted
   `main edit` snapshots on the stale line, prints `Concurrent modification detected, resolving
   automatically.`, creates a reconcile, and `jj log -r 'divergent()'` shows two tips. The
   exercise can be salvaged by expecting the stale error and using `update-stale`, but the
   “silently Fresh” narrative must be rewritten.

3. **MINOR — 4.4's head comparison is wrong.**

   The comment says `jj op log -n 1` should show “same head as `$HEAD`”. In the as-written run
   `$HEAD` is the snapshot op `911ba…`/`d3df…`, but 4.3's `jj op restore "$OLD"` created a
   `restore to operation` op (`84a5…`/`5bd4…`), and that is what `jj op log -n 1` shows. The
   substantive claim (“update-stale wrote NO op”) is true: the head did not change from just
   before `update-stale` to just after. The comparison target in the comment is the bug.

4. **MINOR — `check.sh 04` is not robust to the stale sandbox and mislabels 4.5.**

   After the lesson exactly as written, `check.sh 04` reported 2 passed / 3 failed (see below).
   The 4.1 workspace-existence check failed only because `jj workspace list` was run from the
   stale sandbox; the workspace existed. The hint “run: `jj workspace add ../side-task`” is
   misleading. The `4.5` check greps for `--allow-cross-workspace`, which is 4.6's undo, not
   4.5's dirty-path behaviour; it cannot detect the 4.5 bug. It passed after a manual
   `jj workspace update-stale` even though 4.5 as written had failed.

### check.sh results

As written, after 4.7:

```text
Lesson 04
  FAIL  4.1  a second workspace 'side-task' exists
        → run: jj workspace add ../side-task
  PASS  4.1  its .jj/repo is a pointer file to the shared repo
  PASS  4.3  the shared-view rewind reached your workspace (a stale update happened)
  FAIL  4.5  a cross-workspace undo happened (--allow-cross-workspace)
        → run: jj undo --allow-cross-workspace (after a side-task op)
  FAIL  4    sandbox still sane (seeded history reachable)
        → reset-sandbox.sh if you went too far

Result: 2 passed, 3 failed.
```

After running `jj workspace update-stale` in the sandbox (the documented recovery, not part of
4.7), the same check reported:

```text
Result: 5 passed, 0 failed.
Lesson 04 complete ✔ — proceed to the next lesson.
```

That pass does not validate 4.5; see discrepancy 4.

### Clarity issues

- 4.7's “Neither workspace was ever *stale*” is contradicted by the observed stale error and
  by the tutorial's own freshness table (tree changed → stale).
- The unused `$HEAD` in 4.3 plus the incorrect 4.4 comment is a strong signal that 4.5 was
  intended to use `$HEAD`; as written the reader cannot tell why `$HEAD` exists.
- `jj st` never prints the word `Fresh`. The comments in 4.6/4.7 mean “no stale error”; a
  literal tester sees `Working copy changes: M src/greet.py` and may think the exercise failed.
  Suggest saying “no stale error” in the comments.
- `grep interference src/greet.py` (4.4) exits 1 when the fix worked (no match); it is shown as
  a bare command. Under `set -e` this aborts a reader's shell. Suggest
  `! grep -q interference src/greet.py` or note “expected exit 1”.
- `cat ../side-task/.jj/repo` (4.1) prints a path with no trailing newline; the next command's
  output is glued to it (`../../sandbox/.jj/repo+ jj op log`). Suggest `cat …; echo`.
- The stale-error block in the theory omits the actual trailing
  `See https://docs.jj-vcs.dev/latest/working-copy/#stale-working-copy for more information.`
  line; harmless, but not byte-exact.
- 4.6's final `jj st` shows `M src/greet.py` because the shared change still contains the 4.3
  interference edit. The lesson says “Fresh — your pointer was never side-task's business”;
  the freshness is right but the visible output is not explained.
- 4.7's side-task `jj st` reports `M src/greet.py` as well as `M README.md` (the shared change
  already contains the earlier interference), which the lesson does not mention.

### Suggested minimal fixes

1. **4.5:** change `jj op restore "$OLD"` to `jj op restore "$HEAD"`. Keep 4.3's `HEAD`
   capture. Verified to produce the quoted `Concurrent modification detected…`,
   `Updated working copy to fresh commit …`, the dirty snapshot op and the reconcile op.
2. **4.4:** change the comment to “same head as just before `update-stale` (the restore op)”,
   or capture a `BEFORE` variable immediately before `update-stale` and compare that.
3. **4.7:** replace the sandbox's `jj st` with `jj workspace update-stale`, and rewrite the
   prose: the second workspace *does* become stale because the shared commit's tree changed;
   `update-stale`'s dirty path is what forks the change. Verified to yield divergent tips.
   Alternatively, drop the “silently Fresh” claim and move the change-divergence demo to a
   `--at-op` recipe.
4. **4.4:** use `! grep -q interference src/greet.py` (or add “expected exit 1”).
5. **4.1:** use `cat ../side-task/.jj/repo; echo`.
6. **check.sh 04:** use `jj --ignore-working-copy workspace list` (and similar read-only
   checks) so a stale sandbox does not produce false FAILs; rename the `4.5` check to `4.6`;
   add a check for 4.5 (e.g. a dirty snapshot plus reconcile, or the absence of
   `Attempted recovery, but the working copy is not stale.`).

---

## Lesson 05 — Forks and healing: concurrent operations on one machine

### Commands run (abridged)

- **Primary run:** lesson 05 was started on the state left by lesson 04 as written. 5.1 failed
  immediately (stale sandbox; see discrepancy 1). The sandbox was then repaired with
  `jj workspace update-stale`, and 5.1–5.7 were run from the top.
- **5.1** capture `BASE`; two `jj --at-op "$BASE" new -m …`; `ls .jj/repo/op_heads/heads/`;
  `jj st`; `jj op log -n 5`.
- **5.2** capture `BASE`; three `jj --at-op "$BASE" new -m "fork N"`; `jj log`;
  `jj op log -n 5 --no-graph -T '…parents…'` (the two-line template from the lesson).
- **5.3** `DET=$(jj --no-integrate-operation new -m "detached X" …)`; `jj new -m "meanwhile…"`;
  `jj op integrate "$DET"`; `jj op log -n 4`.
- **5.4** capture `BASE`; two `--at-op` forks (`left`, `right`);
  `jj op log --at-op=@`; `jj --at-op "$(ls .jj/repo/op_heads/heads | head -1)" op log -n 3`;
  `jj op log`.
- **5.5** `jj bookmark set main -r @- 2>/dev/null`; capture `BASE`;
  `jj --at-op "$BASE" bookmark move main`; `jj --at-op "$BASE" bookmark delete main`;
  `jj log`; `jj bookmark list`.
- **5.6** `jj undo`; `jj op restore @-`; `jj op revert @`.
- **5.7** the three-round `for i in 1 2 3; … & … & wait; done` loop with
  `JJ_OP_USERNAME=alice` / `bob`; `jj st`; `jj op log -n 6`;
  `jj log -r 'divergent()' --no-graph -T …`.
- **Clean-baseline diagnostics:** fresh reset, then 5.1 alone and 5.6 on the resulting
  two-parent merge head, to isolate the warnings and the `@-` error from lesson 04's state.

### Matches (brief)

- 5.1 (after repair): two head-marker files, `Concurrent modification detected, resolving
  automatically.`, and a two-parent `reconcile divergent operations` op.
- 5.2: exactly one reconcile op with three parents; the multi-line template works as one shell
  command.
- 5.3: the detached op id is extracted, `jj op integrate` prints
  `The specified operation has been integrated with other existing operations.`, and the
  reconcile puts the detached op beside the “meanwhile” op.
- 5.4: `jj op log --at-op=@` prints the quoted error and a hint listing both head ids; one-side
  `--at-op <id> op log` works; the next `jj op log` heals with those two ids as parents.
- 5.5: `main??` appears, and `jj bookmark list` prints exactly the quoted conflict block
  (`- old`, `+ new`, `@git: new`, hint).
- 5.6: the `jj undo` refusal is exact (`Cannot undo a merge operation` +
  `Hint: Consider using `jj op restore` instead`).
- 5.7: all six race descriptions (`race A1`–`A3`, `B1`–`B3`) appear in the op log, the op log
  forks and heals repeatedly, and `divergent()` shows several tips. No corruption observed.

### Discrepancies

1. **BLOCKER — state dependency: 05 cannot start after 04 as written.**

   Lesson 04's 4.7 leaves the sandbox stale. The first 5.1 command therefore fails:

   ```text
   $ BASE=$(jj op log -n 1 --no-graph -T 'id' | cut -c1-12)
   Error: The working copy is stale (not updated since operation <hash>).
   Hint: Run `jj workspace update-stale` to update it.
   See https://docs.jj-vcs.dev/latest/working-copy/#stale-working-copy for more information.
   ```

   `BASE` is empty; the next two commands fail with
   `Error: Operation ID "" is not a valid hexadecimal prefix`; `ls .jj/repo/op_heads/heads/`
   shows **one** marker (the lesson expects two); `jj st` and `jj op log -n 5` repeat the stale
   error. Root cause is 4.7, but the lesson's “05 continues on the same state” makes this a
   real sequence failure. After a manual `jj workspace update-stale`, 5.1–5.7 (except 5.6)
   ran.

2. **BLOCKER — 5.6's `jj op restore @-` is ambiguous on a merge head.**

   Observed:

   ```text
   $ jj op restore @-
   Error: The "@-" expression resolved to more than one operation
   Hint: Try specifying one of the operations by ID: <parent-1>, <parent-2>
   ```

   Expected (lesson): “...but restore works: land before the reconcile.” The head is a
   two-parent reconcile op, so `@-` is a set of two operations and `op restore` requires one.
   Consequently the next command also fails:

   ```text
   $ jj op revert @
   Error: Cannot revert a merge operation
   ```

   instead of reverting “just that op”. The lesson's third command is only valid *after* a
   successful restore.

   Diagnostic verification: `jj op restore <one-parent-id>` (e.g. the bookmark-move parent)
   succeeds and prints `Restored to operation: …`; `jj op revert @` then works and prints
   `Reverted operation: …`. The clean-baseline run reproduced the `@-` ambiguity exactly, so
   this is not a lesson-04 state artifact.

3. **MINOR — undocumented collocated-Git warning in 5.1/5.2/5.4.**

   The second and subsequent `jj --at-op` forks print:

   ```text
   Warning: Failed to update Git HEAD ref
   Caused by:
   1: Could not prepare reference edit, "reference"="HEAD", "referent"="HEAD"
   2: Expected reference content <hash>
   ```

   The lesson shows none of this. It is harmless here (the forks are created, the reconcile
   heals, two/three markers appear), but it looks like an error. It reproduced on a clean reset
   with only 5.1, so it is inherent to the colocated sandbox, not to lesson 04's leftovers.
   Suggest a note (“colocated repositories warn when a second fork cannot move Git HEAD”) or a
   non-colocated sandbox for these lab exercises.

4. **MINOR — undocumented bookmark-export warning in 5.5.**

   `jj --at-op "$BASE" bookmark delete main` printed:

   ```text
   Deleted 1 bookmarks.
   Warning: Failed to export some bookmarks:
     main@git: Deleted ref had been modified in Git
   ```

   The lesson only quotes the later `jj bookmark list` conflict block, which did match. The
   warning is colocated-Git noise, but it is unexplained. Suggest mentioning it or suppressing
   it in the same way as other quoted output.

5. **NOTE — 5.7 hides stderr, so “no errors” is not directly observable.**

   Both race commands redirect `>/dev/null 2>&1`. The op log confirms all six descriptions and
   the forks/reconciles, so the claim is consistent, but any per-process warnings (including
   the Git HEAD warning above) are invisible. Also, the post-race `jj st` prints a leftover
   bookmark-conflict warning from 5.5 (`These bookmarks have conflicts: main`), which 5.7 does
   not mention. Suggest capturing each subshell's status/stderr to files, or state explicitly
   that the op log is the evidence.

6. **NOTE — `check.sh 05` does not check 5.3, 5.4 or 5.6, and its 5.1 check is not specific.**

   The 5.1 check greps the whole op log for any `reconcile divergent operations` op. Lesson 04
   already created several, so 5.1 can “pass” even if its own forks fail. 5.7's check is the
   literal command `true`. 5.6 is not checked at all, so the 5/0 result below was obtained
   while 5.6 was failing. Suggest adding checks for 5.3 (integrated op), 5.4 (two-head error /
   one-side log), 5.6 (successful restore + revert), and making 5.1's check require a new
   reconcile after the 5.1 base.

### check.sh results

After the repaired 5.1–5.7 run (5.6 failing):

```text
Lesson 05
  PASS  5.1  divergent ops were healed (a reconcile op exists)
  PASS  5.2  the 3-fork merge op has 3 parents
  PASS  5.5  the bookmark conflict was forked and healed
  PASS  5.7  the race left a divergent change (or you converged it)
  PASS  5    sandbox still sane (seeded history reachable)

Result: 5 passed, 0 failed.
Lesson 05 complete ✔ — proceed to the next lesson.
```

The pass is misleading for 5.6; see discrepancy 6.

### Clarity issues

- 5.6's “restore works” is the main blocker; `@-` is not a single operation when the head is a
  merge. The parent ids are printed in the error, but the lesson does not say to use them.
- 5.6's third comment (“if `@` is now non-merge”) presumes the failed restore succeeded; as
  written it is misleading.
- The Git HEAD warning in 5.1/5.2/5.4 can be mistaken for a failed fork; the exercise still
  works.
- The 5.5 bookmark-export warning is unexplained, and `2>/dev/null` on the preceding
  `bookmark set` hides any failure of that setup step. A reader whose `main` is not behind
  `@-` would silently get a different starting point.
- 5.2's template is split across a line break inside single quotes. It works when pasted as a
  block (the shell shows a `>` continuation if typed line-by-line), but the lesson does not
  say it is one command.
- 5.3's `DET=$(… | tail -1 | grep -oE '[0-9a-f]{12,}')` is fragile: it relies on the operation
  id being the last line. It worked here, but a different jj output order would capture a
  commit id or return empty. A more robust extraction or a printed “operation id” is
  preferable.
- 5.4's `jj op log --at-op=@` intentionally exits 1; a reader with `set -e` will stop. The
  lesson does quote the error, so this is only a note.
- 5.7's divergent ids are shown as `zzzzzzzz/N` in the prose; actual ids are normal change ids.
  This is illustrative, not a bug.

### Suggested minimal fixes

1. **5.6:** replace `jj op restore @-` with `jj op restore <one-parent-id>` using one of the
   ids printed by the error (or by `jj op log`), and say so. Verified: the restore then works
   and `jj op revert @` reverts the restore op. If the goal is only “restore works on a merge
   head”, pick either parent; if the goal is to keep `main`, pick the bookmark-move parent.
2. **5.1/5.2/5.4:** add a sentence that colocated repos may print
   `Warning: Failed to update Git HEAD ref` for the second and later forks; it is harmless and
   does not prevent the two/three head markers. Alternatively, use a non-colocated sandbox for
   this lesson.
3. **5.5:** mention the `main@git` export warning, and remove the silent `2>/dev/null` on
   `bookmark set main -r @-` (or assert its success) so a wrong starting bookmark is visible.
4. **5.7:** capture each subshell's status/stderr (or state that the op log is the evidence);
   mention the leftover `main` bookmark conflict from 5.5.
5. **check.sh 05:** add real checks for 5.3, 5.4 and 5.6; make 5.1's check require a reconcile
   created after the 5.1 base; replace 5.7's `true` with an op-log assertion (e.g. at least
   one `reconcile` and at least one divergent change, or an explicit “informational” label).
6. **5.2/5.3:** add “this is one shell command” for the multi-line template and make the
   detached-op extraction less brittle.

---

## Severity summary

| Severity | Items |
|---|---|
| **BLOCKER** | 4.5 dirty-path no-op; 4.7 false “silently Fresh” (and subsequent stale errors); 5.6 ambiguous `jj op restore @-` (and failed `op revert`); 05 cannot start on 04's stale state |
| **MINOR** | 4.4 wrong `$HEAD` comparison; check.sh 04 false 4.1/4.5/sane failures; 5.1/5.2/5.4 Git HEAD warning; 5.5 bookmark-export warning; reset-sandbox.sh flaky exit 3; check.sh 05 does not check 5.3/5.4/5.6 |
| **NOTE** | 4.1 pointer file has no trailing newline; 4.4 `grep` exits 1; “Fresh” is not literal output; stale-error `See …` line omitted; 4.6/4.7 extra `M src/greet.py` context; 5.7 suppresses stderr and leaves a bookmark conflict; 5.2 multi-line template; 5.3 `DET` extraction fragility |
