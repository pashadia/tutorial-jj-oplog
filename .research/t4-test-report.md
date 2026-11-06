# t4 test report: lessons 04, 05, 06 executed literally (jj 0.46.0)

Method: throwaway copy of tutorial-oplog under /tmp, isolated HOME/JJ_CONFIG
(user.name/email set), non-interactive JJ_EDITOR, bash. Lesson 04 -> 05 run
back to back with no reset (as 05's preamble says). Lesson 06 was run after
`./reset-sandbox.sh` (primary run); a second run of 06 straight after 05 was
done to see what a learner without a reset gets. 4.7 was also run in
isolation on a fresh sandbox. Nothing in the real tree was modified except this file.

Legend: PASS = output matches lesson text; DEV = deviation.

## Lesson 04

| Step | Result | Notes |
|---|---|---|
| 4.1 workspace add / list / cat / op log | PASS | `cat ../side-task/.jj/repo` prints `../../sandbox/.jj/repo` (no newline, echo needed). Both op logs identical. |
| 4.2 attribution | PASS | `describe commit ...` tagged `side-task@`; `working_copies` shows `side-task@` and `default@`. |
| 4.3 interference | PASS | `jj st` in sandbox: `Error: The working copy is stale (not updated since operation 5cb0934f534e).` plus Hint plus an extra third line `See https://docs.jj-vcs.dev/latest/working-copy/#stale-working-copy for more information.` (cosmetic; lesson elides it). `jj op log` also refuses; `--ignore-working-copy op log` and the log from side-task work. |
| 4.4 clean update-stale | PASS | `Updated working copy to fresh commit db3e92590b20`; 'interference' gone; `jj op log -n 1` is still $RESTORE (no new op); `jj op show $SNAP` shows the edit. |
| 4.5 dirty path | DEV (wording) | Output: `Concurrent modification detected, resolving automatically.` then `Working copy (@) now at: ultxrwvu/1 b8bfe3fe (divergent) (no description set)` ... `Updated working copy to fresh commit b8bfe3feb1a4`. The op log is as claimed (snapshot op `a6696fc2dff6` + `reconcile divergent operations`). BUT: (a) the working-copy change `ultxrwvu` is now **divergent** (/0 = snapshot of 'more interference' on top of the old base, /1 = the commit with 'interference' that the restored pointer names); (b) only `interference` is on disk, `more interference` is NOT (it is in commit 2e2623b0, `ultxrwvu/0`). The lesson's "Both edits survive as commits" is true but silent about the divergence and the missing line. |
| 4.6 cross-workspace undo | PASS | Refusal text matches (`Refusing to undo operation 133e7e72de81 because it was performed in workspace side-task` + Hint). `--allow-cross-workspace` works, side-task stale, update-stale removes side.txt (`removed 1 files`), sandbox `jj st` fresh. |
| 4.7 shared-change footgun, literal after 4.5/4.6 | DEV | Because 4.5 already left `ultxrwvu` divergent, `jj log -n 5` shows THREE tips (`ultxrwvu/0`, `/1`, `/2`), not "two tips". |
| 4.7 on a fresh sandbox (isolated) | PASS | `Concurrent modification detected...`; `jj log` shows `qvpxpuys/1 ... default@ side-task@ (divergent)` and `qvpxpuys/0 (divergent)`: exactly two tips. Disk keeps only 'side edit'; 'main edit' lives in the /0 tip. |
| check.sh 04 | PASS | 7/7. |

Corrections for 04:
- 4.5 after the `jj log`/last line, add: "Note the result: the snapshot of 'more interference' and the commit your restored pointer names are two commits of the same change, so your working-copy change is now `(divergent)` (`ultxrwvu/1`), and only `interference` is on disk; `more interference` lives in the other tip (`jj log -r 'divergent()'`). Both edits survive as commits." Then add a clean-up step: `jj abandon <the /0 tip>` is optional, or "start 4.7 from a fresh sandbox".
- 4.7 intro: "Start from a clean slate so you see exactly two tips: `cd .. && ./reset-sandbox.sh && cd sandbox && jj workspace add ../side-task`. (If you skip this, 4.5's divergence is still there and you will see three tips.)"
- Optional: 4.3 comment `# Error: The working copy is stale ...` could mention the extra `See https://...` line.

Verdict 04: runnable, check passes; fix 4.5 wording and make 4.7 independent of 4.5.

## Lesson 05 (run straight after 04, no reset)

| Step | Result | Notes |
|---|---|---|
| preamble `jj st` | PASS | Sandbox not stale, but `jj st` shows the state left by 4.7 (divergent `@`, dirty README/greet.py). |
| 5.1 fork | PASS | Two marker files; `Warning: Failed to update Git HEAD ref` (once, as predicted); `Concurrent modification detected`; reconcile op with two parents. |
| 5.2 three forks | PASS | Warning printed twice; one reconcile op `4f63a7` with 3 parents. |
| 5.3 detached op | PASS | DET captured; `The specified operation has been integrated with other existing operations.`; reconcile op beside moving-on op. |
| 5.4 look without healing | PASS | `Error: The "@" expression resolved to more than one operation` + `Hint: Try specifying one of the operations by ID: ca776d15f611, 8d8138b8928c`; single-head view works; next `jj op log` heals. |
| 5.5 bookmark conflict | PASS | `Warning: Failed to export some bookmarks: main@git: Deleted ref had been modified in Git` printed at the `bookmark delete` step (before the reconcile), not at `jj log`; lesson wording ("you'll also see") is fine. `main??` in log; `jj bookmark list` shows `main (conflicted):` with `-`/`+`/`@git` and the Hint, as quoted. |
| 5.6 second-class citizens | PASS | `Cannot undo a merge operation` (+Hint to use `jj op restore`), `Cannot revert a merge operation`, `@-` resolves to more than one operation (+ Hint listing ids), `op restore $BASE` works, main conflict gone. |
| 5.7 real race | DEV (cross-lesson) | Works (3 rounds, divergent `tnvzponw` /0../N). But the final `jj log -r 'divergent()'` also lists 3 extra lines for `ultxrwvuymzq` (empty description) inherited from 4.5/4.7. |
| check.sh 05 | PASS | 6 passed, 0 failed (+1 INFO). |

Corrections for 05:
- Replace the preamble "Arriving straight from lesson 04? ... `jj st`" with: "Arriving from lesson 04? Run `cd .. && ./reset-sandbox.sh && cd sandbox` first: lesson 04 leaves divergent changes and a second workspace that would clutter 5.7's `divergent()` output (and break lesson 06)."

Verdict 05: PASS; only the start-state advice should change.

## Lesson 06 (after `./reset-sandbox.sh`)

| Step | Result | Notes |
|---|---|---|
| 6.1 wire up | PASS | `bookmark: main [add to f72447028cd7]`; clone prints `Setting the revset alias trunk() to main@origin`. Clone's own ops (`add workspace`, `add git remote`, `fetch ... into empty repo`, `check out git remote's branch: main`) are attributed to `bogdan@nixos`: the new attribution note is **verified**. `colleague@colleague-box` appears from the first later op (`snapshot working copy` in 6.2). |
| 6.2 exchange | PASS | `Creating bookmark push-zxknomkxtqsz`, fetch shows `push-...@origin [new] untracked`; same change_id+commit_id both sides; op ids differ. |
| 6.3 count | PASS | Prints `0`; the single shared id is the all-zero virtual root (verified with raw `comm`). |
| 6.4 conflict | PASS | A: `jj new main -m ...`, `bookmark move`, push OK + `Warning: The working-copy commit became immutable; a new commit has been created on top of it.` B: rejected with `Warning: The following references unexpectedly moved on the remote: refs/heads/main (reason: stale info)` + Hint + `Error: Failed to push some bookmarks`. B fetch: `main (conflicted)` with `- old / + B / + A`, `??`. `bookmark set main -r @` then push says `move sideways from 51983c81e7d5 to a09464862bfc`. A's fetch: `Abandoned 1 commits that are no longer reachable:` + `Rebased 1 descendant commits.`; `jj log -r 51983c81` shows `zrzsnszu/0 ... (hidden)`. All claims **verified**. |
| 6.5 divergence | PASS | `bookmark track 'push-*' --remote origin` -> `Started tracking 1 remote bookmarks.`; B `push --change @` is `move sideways`; A `push --named a-take=@` is `add`; B fetch `a-take@origin [new] untracked`. Before tracking, `jj log -n 8` shows one tip, but already marked `zxknomkx/1 ... (divergent)` (so the "(divergent)" marker is visible even with one tip). After `track`, `jj log -r 'divergent()'` shows `/0` (A take) and `/1` (colleague take). `jj converge`: summary block, then `There are divergent descriptions ... Do you want to merge them now? (Yn)`; editor opens once; result `(conflict)`, `b.txt    2-sided conflict`, hint `jj new zxknomkx`. `--no-interactive` -> `Could not determine which description to use.` / `Error: Could not converge change`. All **verified**. Note: if the editor is closed unchanged, the new commit's description is the conflict-marker text (`(conflict) <<<<<<< conflict 1 of 1`). |
| 6.6 undo across fetch | PASS | A's fetch (`push-zxknomkxtqsz@origin [updated] tracked`); `jj undo` -> `push-zxknomkxtqsz@origin (ahead by 1 commits, behind by 1 commits): ... (hidden) colleague feature`, i.e. rewound; second fetch restores it; `jj git import` -> `No import needed in colocated workspaces.`; `--ignore-working-copy git import` -> `Nothing changed.`. **Verified.** |
| check.sh 06 (as shipped) | **FAIL** | 10 passed, 1 failed: `6.4 the colleague resolved the conflict (its log has two 'push bookmark main' ops)`. |
| check.sh 06 (patched) | PASS | All 11 pass with the fix below. |

Diagnosis of the failure: the CHECK is wrong, not the lesson. B's first push is rejected before any op is written, so B's log has exactly ONE `push bookmark main` (the sideways one), preceded by `point bookmark main ... (jj bookmark set main -r @)`. Colleague log excerpt: `push bookmark main`, `point bookmark main` (bookmark set), `fetch from git remote(s) origin`, `point bookmark main` (bookmark move), `new empty commit`. The "two ops" count only holds on A's side (its 6.1 push plus its 6.4 push), which is why the sibling check passes.

Corrected check (replace the colleague check in check.sh, lines for "6.4 the colleague resolved"); tested, passes:

```bash
  maybe "6.4  the colleague resolved the conflict (a 'bookmark set main' op, then a successful 'push bookmark main')" \
    "c=\$(jj --ignore-working-copy --repository ../colleague op log --no-graph -T 'description ++ \"\\n\" ++ attributes ++ \"\\n\"'); grep -q '^push bookmark main' <<<\"\$c\" && grep -q 'jj bookmark set main' <<<\"\$c\"" \
    "in ../colleague: fetch, 'jj bookmark set main -r @', 'jj git push --bookmark main' (the rejected first push leaves no op)"
```

Nit: the sibling check's label "both users pushed main (two 'push bookmark main' ops on your side)" is misleading; both ops are A's (6.1 and 6.4). Suggest "you pushed main twice (6.1 and 6.4)".

Other observations / suggested lesson tweaks:
- 06 has no "start fresh" instruction. Run straight after 05 it breaks at 6.1: `jj git push --bookmark main` -> `Error: Won't push commit 9ac48a58b664 since it has no description` (leftover divergent change from lesson 04), the clone is empty/`Nothing changed.`, and 6.4 collapses (`Revision main doesn't exist`). Add at the top of Exercises: "Start from a clean slate: `cd .. && ./reset-sandbox.sh && cd sandbox`."
- 6.5 `jj converge`: add "In the editor, replace the conflict-marker text with a one-line message (e.g. `converged take`) and save; if you save unchanged the commit description keeps the markers."
- 6.6: after the second step `jj bookmark list` also shows `push-<id>` as `(conflicted)` after the fetch in this flow (A's tracked local push-<id> was rewritten by "A take", B's push moved the remote). Optionally note "(push-<id> shows conflicted here because both of you rewrote it; ignore)". The "rewinds" claim itself is correct.
- 6.5 side effect: colleague's `jj log` also shows A's abandoned-then-visible `A's competing move` head (zrzsnszu) as a stray branch; harmless.

Verdict 06: lesson text accurate on every new claim (6.1 attribution, 6.3 `0`, 6.4 warning and `Abandoned 1 commits`, 6.5 prompt and `(conflict)`, 6.6 rewind). check.sh 06 has one wrong check (fix above); add a reset instruction at the top.

## Summary verdicts

- 04: PASS with two wording fixes (4.5 divergence note, 4.7 fresh-start).
- 05: PASS; change the start-state advice to "reset".
- 06: PASS in content; check.sh needs the one-line fix; add reset instruction.
