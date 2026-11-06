# t5-v2 report: lessons 04 and 05 executed literally (jj 0.46.0)

Method: throwaway copy of the tree under /tmp, isolated HOME and JJ_CONFIG, `./reset-sandbox.sh` first,
then every exercise run in order (04 right after reset; 05 after a reset, as the lesson says).
Edited only lessons/04-workspaces-one-log.md and lessons/05-forks-and-healing.md.

## Lesson 04

| Ex | Result |
|---|---|
| 4.1-4.4, 4.6, 4.7 | PASS |
| 4.5 | PASS (edited text matches reality: divergent `vpyxpsrv/0`,`/1`, only `interference` on disk) |
| 4.8, 4.9, 4.10 | PASS (quoted `op show` shape, errors and exit codes exact) |
| 4.11 | FIXED: the `ls -A` comment listed C-locale order; reworded to `.git .jj late.txt notes.txt README.md src` plus "order depends on your locale" |
| 4.12 | FIXED (real bug): with `jj workspace add ../scratch-2 --name scratch` the new wc commit has the SAME tree as the old directory's (both are empty children of the same parent), so by the freshness rule the old dir stays `Fresh`. `jj st` showed no stale error and snapshotted draft.txt into the NEW workspace's commit, and `update-stale` printed "Attempted recovery, but the working copy is not stale." Fix: added `-r main` to the `workspace add` (different tree, so `WorkingCopyStale`), added an explanatory sentence, corrected the quoted line to `Added 0 files, modified 1 files, removed 2 files`. Re-verified: stale error, "Concurrent modification detected", draft.txt/unsaved.txt gone from disk but present in commits. |
| 4.13-4.15 | PASS |
| 4.16, 4.17, 4.18 | PASS (exit 255, integrate graph, recovery commit text, auto-update-stale all as quoted) |
| Clean up | PASS |

check.sh 04: 17 passed, 0 failed.

## Lesson 05 (after `./reset-sandbox.sh`)

| Ex | Result |
|---|---|
| 5.1-5.7 | PASS (5.1/5.4/5.5 show the cosmetic Git HEAD warning the text predicts; 5.7 produced divergent changes) |
| 5.8 | FIXED: the heal was a plain `jj log`, so the rebased child carried wall-clock time, not the quoted `13:00:09`. Changed to `at 9 log` and explained. The flipped variant now says "fresh lab" (was "fresh sandbox") and "heal with `at 9 log`". Both variants re-verified (same graphs and parent order as quoted). Added a note that the pinned UTC clocks display in the local timezone (quotes were UTC+1). |
| 5.9 | PASS |
| 5.10 | FIXED: heal command `jj log` changed to `at 9 log` (same timestamp reason). Stale error, conflict, file show and resolve --list as quoted. |
| 5.11 | FIXED: setup was only a vague comment; spelled out fresh lab, the forks, and "no heal before copying". Identical reconcile op on both copies confirmed. The tie claim had no command; added a copy-and-heal loop (confirmed: different `@` in different copies). |
| 5.12 | PASS |
| 5.13 | PASS |
| 5.14 | FIXED (real bug): strace is present and reproduces `Error: Concurrent working copy operation. Try again.` in a fresh lab. In the lab as it stands after 5.12/5.13 (divergent @, many ops) the snapshot phase takes more flocks, `when=9` hits the wrong call and P1 succeeds (exit 0). Fix: run it in a fresh lab (command added), plus a note that `when=` must be the index of the second working_copy.lock LOCK_EX (when=11 verified in the crowded state). |
| 5.15 | FIXED (text only): removed the leftover draft reference "d3b exercise 2.10" and "The lesson-05 theory section"; says to run in the same lab-forks. Reproduced with the quoted output (255, "reparented 3 descendant operations", reconcile op with two parents). |

check.sh 05: 9 passed, 0 failed (5.7 and 5.12-5.14 are INFO). Check 5.11 needs ../copy1 and ../copy2 left in place after the exercise (they are; reset-sandbox.sh removes them).

## Requested changes to files I may not edit

None required. Observations:
- Lesson 04's clean-up block does not remove ../side-task; lesson 05 relies on reset-sandbox.sh, which does remove it.
- Exercise 5.15 creates ../side; reset-sandbox.sh already removes it. The 5.11 tie loop deletes its own ../tie* directories.
