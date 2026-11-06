# t5 v1 verification report: lessons 01, 02, 03

Method: throwaway copy of the tree under /tmp, isolated HOME and JJ_CONFIG (default jj config plus user.name/email), `JJ_EDITOR=true`, `./reset-sandbox.sh` first, every exercise run literally and in order, labs made with `./new-lab.sh`. After the lesson text was fixed, the changed lab sections (2.8-2.14, 3.12) were replayed in a second fresh copy. Both copies are deleted.

## Root cause behind several deviations

The earlier drafts were run with the author's personal jj config, where `revsets.log = "visible_heads() | @ | ..."` has a bare `@`. With jj's default config (what a learner has):

- `jj log` after `op restore 000000000000` prints only `root()` and exits 0.
- There is no "wall" of `Failed to load short-prefixes index` warnings.
- `jj log -r @` still errors with ``Workspace `default` doesn't have a working-copy commit``.

I confirmed the wall and the Error come back with the author's config.

## Lesson 01

- 1.1, 1.2, 1.3, 1.5, 1.6: PASS.
- 1.4: FIXED. The text said `2>/dev/null` is "load-bearing" and that jj prints a wall of warnings. With the default config there are none. The text now says the warnings appear only if `revsets.log` has a bare `@`.
- 1.5, `jj op show 0000` comment: FIXED. It promised a warning wall; it is now conditional on that config.
- `./check.sh 01`: 5 passed, 0 failed.

## Lesson 02

- 2.1: PASS. FIXED a theory sentence: it said `jj redo` prints "just the summary", but redo also prints the working-copy lines.
- 2.2, 2.3, 2.5, 2.7: PASS.
- 2.4: FIXED. The text promised a wall of warnings and `Error` from `jj log`. The text now describes the real output:
  - `jj st` prints `No working copy.`
  - `jj log -r @` gives the Error.
  - Plain `jj log` depends on the config, as described above.
- 2.6: FIXED. The root-op claim (`--at-op 000000000000 log` ends in Error) is now stated for `log -r @`, with the default-config behaviour.
- 2.8: PASS. The shapes of all quoted outputs match.
- 2.9, first half (revert with rebase): PASS.
- 2.9, second half (revert gives a conflicted bookmark): FIXED.
  - Run literally, `topic` already existed (on `B on A`). B -> X -> Y is a straight line, so jj fast-forwards the 3-way merge to `Y` and there is NO conflict, which contradicts the quoted output.
  - Fix: `jj bookmark delete topic` before `jj new -m X`, plus an explanatory note. The conflict now reproduces.
  - Also turned the "Resolve with ..." sentence into a command (`jj bookmark set topic -r @`). Otherwise the leftover conflict leaks `topic??` and extra `topic:` sections into the 2.10-2.13 outputs.
- 2.10: FIXED.
  - `WCOP=b355625d6019` was a hard-coded id from the author's run, so it was an unknown op for a learner. It is now computed from `jj debug working-copy`.
  - The cleanup line now also abandons the `side work` commit. Otherwise it stays a visible head and breaks the single-head "now:" result in 2.13.
- 2.11: FIXED. `SNAP=... | head -1` selected the `jj st` snapshot (scratch), but the text discusses the `jj bookmark create` snapshot (util.py). It is now `sed -n 2p`.
- 2.12: PASS. Added a note that a `topic:` bookmark entry may appear. Elided counts (2/1 and 3/1) match.
- 2.13: FIXED.
  - `$L` was defined only in a trailing parenthetical; it is now the first line of the block.
  - The command `at_operation(@---, ::@)` disagreed with the result table, which says `at_operation(@---, @)`. The command now matches the table.
  - All other outputs match in shape.
- 2.14: FIXED.
  - `jj ... op log --no-graph | wc -l` counts lines, not ops (3 or more lines per op). It is now an `n()` helper using `-T 'id.short() ++ "\n"'`.
  - The final `--at-op=@ op log` step reported no new op, because the previous step had already snapshotted `dirty.txt`. A second `echo dirtier >> dirty.txt` is added before the last two probes. The counts N, N, N+1, N+1, N+2 now reproduce.
- `./check.sh 02`: 10 passed, 0 failed after 2.10. After the 3.5 `op abandon`, checks 2.1-2.7 fail honestly, same as 01.

## Lesson 03

- 3.1-3.4: PASS. 3.4 flock: `jj new` waited about 2.5 s silently.
- 3.5: PASS. Added "(or `02`)" to the sentence about re-running `./check.sh 01` failing honestly.
- 3.6: PASS.
- 3.7: PASS. The `debug` and `object` command lists match.
- 3.8: PASS.
- 3.9: FIXED. It said the root tree lists `README.md`, `f.txt` and `src`; the lab has no `f.txt`. The verified output block still shows `f.txt` in the 3.10 listing; that is real output from an earlier run and is left alone.
- 3.10: FIXED. The size comment said `~99 bytes`; it is 79 here, now `~80-100`. The `debug working-copy` and `debug local-working-copy` snapshot behaviour was confirmed (op count 7 -> 7, then 7 -> 8).
- 3.11: PASS. Directory counts differ slightly per run; added "(they vary ...)".
- 3.12: FIXED.
  - `KEEP=$(head -1 /tmp/unreach.txt)` is luck-dependent: its view may be shared with a reachable op, and then the "view not found" demo does not happen.
  - `KEEP` is now `@---` taken before the abandon, whose view is unique. This reproduces the half-kept-op error deterministically.
  - Added a note that the op counts in the comments are from one run (a lab here has 12, not 9, ops before the abandon).
- `./check.sh 03`: 6 passed, 0 failed (3.7 needs the `lab-internals` directory).

## Requested changes to files I may not edit

- `check.sh` (02): optional. The INFO line "2.11-2.14" is fine. After lesson 03's 3.5 abandon, `check.sh 02` also fails, as 01 does. If you want, add "(or 02)" to any README remark about this.
- `README.md`: if it states the "wall of short-prefixes warnings" as general behaviour, it should say this happens only with a bare-`@` `revsets.log`.
- `reset-sandbox.sh`: no change needed. It removes `remote.git`, `side` and `lab-*`, which covers 2.8, 2.10 and 3.7.
- Lessons 04-08 may carry the same config-dependent claims about warning walls and the root op. I did not check them.
