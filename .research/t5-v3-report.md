# t5 v3 verification report (lessons 06, 07, 08)

Method: throwaway copy of the tutorial under /tmp, isolated HOME/JJ_CONFIG, non-interactive
JJ_EDITOR, pinned jj 0.46.0, rsync + flock present. Lessons 06 and 07 run literally in order
after `./reset-sandbox.sh`; 7.6-7.15 in one bash session (variables re-sourced between tool
calls, definition order checked by hand). All fixes were made in the real tree, lessons only.

## check.sh
- `./check.sh 06`: 11 passed, 0 failed.
- `./check.sh 07`: 12 passed, 0 failed (2 INFO lines: 7.3, 7.14/7.15 timing).
- `./check.sh 08`: INFO only.

## Lesson 06
| ex | result | note |
|----|--------|------|
| 6.1, 6.2, 6.3 | PASS | outputs match (comm count 0) |
| 6.4 | FIXED | text said `jj log -r <id>` finds the hidden competing commit. The *change* id gives `Revision ... doesn't exist`; the *commit* id (from the "Abandoned" line) works and shows `(hidden)`. Reworded. `jj undo` bringing it back verified. |
| 6.5 | PASS | `jj converge` with an editor script works; `(conflict)` + `b.txt 2-sided conflict` as described. (JJ_EDITOR script must not use `#!/bin/bash` on NixOS - my harness issue, not the lesson's.) |
| 6.6 | PASS | undo/fetch/import as written; push-<id> was not conflicted in my run (lesson already says "may"). |

## Lesson 07
| ex | result | note |
|----|--------|------|
| 7.1, 7.2 | PASS | |
| 7.3 | FIXED | in the colocated sandbox the two `--at-op` commands print `Warning: Failed to update Git HEAD ref ... Expected reference content` on stderr (also in a fresh colocated lab). Added a note. Head-marker counts 2 -> 1 as claimed. |
| 7.4 | FIXED (text) | could not reproduce either error (stale / concurrent) in 4 delay variants; both commands succeeded. Added the "may not reproduce" sentence. |
| 7.5 | n/a | writing exercise |
| 7.6 | FIXED | later commands hard-coded the author's op ids (`rm .../heads/5348fd666271*`, `op integrate 5348fd666271`) which do not exist for a learner. Added `AH`/`BH` variables in 7.6 and used `$BH` in 7.8 and 7.11 (+ `$AH` in the 7.7 prose command); added a note that every hash/`/N` suffix in transcripts is the author's. comm count 5 and 8-op log shape verified. |
| 7.7 | FIXED (text) | first error reproduced, but the op named on line 2 was B's `describe` op, not B's head (author's run said head). Added "can differ" sentence. Recovery, `shared (conflicted)`, divergent suffixes (/2,/1 vs lesson /2,/0) OK. Fixed `refs/jj/keep/...` wording. Colocated variant re-tested: same error shape, heals with `.git/objects`. |
| 7.8 | PASS (after $BH fix) | 11 files, 1/3/5 users, "operation not found" error, `rm` recovery verified |
| 7.9 | PASS | reconcile, 2 markers -> 1, stale working copy, update-stale, 12 of 12 common ops |
| 7.10 | PASS | ping-pong and one-writer end verified |
| 7.11 | FIXED (text) | second bookmark list output omitted `shared (conflicted)` block + Hint; added. Rest verified. |
| 7.12 | PASS | recovery commit path as in lesson |
| 7.13 | FIXED | block 1 did `cp -a ma2 idx` while cwd was `del/` (left there by 7.12) -> `cp: cannot stat 'ma2'`. Added `cd "$LAB"`. Also: `export JJ_OP_USERNAME=alice ...` in the `ab` block stays set for 7.14/7.15 in the same shell (harmless; not changed). Added missing `Concurrent modification detected...` line to the last output. Counts 11/4/1, 13/1/9, "Finished indexing 9 commits." verified. |
| 7.14 race | PASS | 30 bookmarks, 1 head, 15 reconcile ops, 14 "Concurrent modification" (exactly as the lesson) |
| 7.14 flock | PASS | 14 ms vs 2488 ms |
| 7.14 Dropbox | FIXED | block started a background sync loop that waits for a `stop` file and never stopped it (no `wait`, no `touch stop`, no final pass/count the following paragraph relies on). Appended `sleep 10; touch stop; wait; rm stop`, final quiet sync and survivor count, error grep. Run: 3 of 24 failed, 21 survivors, identical on both machines, same "operation not found" error (timing-dependent; the lesson already says so). |
| 7.15 fetch race | FIXED (text) | fork reproduced (reconcile with fetch as sibling). `FETCH:`/`FETCH took` lines come from the author's timing wrapper; added a note. |
| 7.15 undo of push | FIXED | transcript was internally odd: `@origin ... db73ffb1 (empty) B on top of A`. Real: after undo `main@origin` is the pre-push commit (`seed`, "behind by 2 commits"). Replaced the block's ids/lines with a consistent real run. The two "more outcomes" (same-commit push no-op, `undo; redo`) re-verified. |

Undefined-reference audit for 7.x: `$LAB`, `$T1` (7.6), `sync_repo` (7.9) are used only after
definition; 7.9 ends in `mb2/`, 7.10 re-`cd`s, 7.12 ends in `del/` (fixed in 7.13); 7.14 runs
`sync_repo` (needs 7.9 in the same shell - already stated at the top). No directory is used
that an earlier exercise did not create (ma2, mb2, pa, pb, st, hd, del, idx, ab, race, lk,
s1, s2, remote.git, seed, pusher, me, u3 all created before use).

## Lesson 08 citation audit
All cited files exist in jj-commit-cloud: lib/src/{cc_op_store,cc_op_heads_store,repo}.rs,
cli/src/main.rs, cli/src/commands/init.rs, docs/database_schema.md, server/db/schema_sqlite.sql,
server/src/{reconcile_op_heads.rs,store/sqlitestore.rs}, common/proto/op_store.proto,
common/src/conversions/op_store.rs, cli/tests/{test_project_repo_split,test_concurrent_op_heads}.rs,
docs/design/{observable-change-log,op-log-scope-decision}.md; and jj-upstream/lib/src/repo.rs.
Verified present: `Cc { Init, ImportGit, Daemon }`; type string `commit_cloud`; MAX_RETRIES = 3 (+ jitter,
exponential backoff); `heads.len() <= 1`; description assertion "reconcile divergent operations"
(test line 369; upstream repo.rs:787); ReconcileOpHeads RPC called from get_op_heads;
write-race string in sqlitestore.rs:490 (wrapped as "CAS conflict: ..." -> Aborted);
`wc_commit_ids: map<string,bytes>`; view_from_proto sets tags/git_refs/git_head empty;
OperationMetadata has hostname/username/attributes; gc is a no-op; resolve_operation_id_prefix
only matches root; 16-byte truncated SHA-1 (server/src/hash_utils.rs:222); jj-lib/jj-cli 0.43.0;
`git_heads` in 0.46 (core/src/op_store.rs:188); test names and "20 workers"; schema tables;
"cell F" ("one operation record and one full view per snapshot").
Deviations found (all FIXED in lesson 08):
1. "`add_commit_cloud` - the five factories": it registers four (backend, op store, op heads
   store, index store); the WorkingCopy factory is in cli/src/main.rs `create_working_copy_factories`.
2. Quote "Every caller can read or write any project/repo" is NOT in the checkout; it is in
   ../jj-commit-cloud-onboarding/04-network-protocol.md. Attribution corrected.
3. observable-change-log.md quote was spliced; replaced with the exact sentence.
4. README quote ended at "API stability." - real text "...API stability is promised at this time." Fixed.
5. "State is split into three namespaces (docs/database_schema.md)": doc never says "namespace" -
   reworded as our reading of the ER diagram + schema.
6. Type-file list incomplete (also index/type, working_copy/type) - added.
7. "verified against 0.46": it is a one-line claim in docs/design/design-notes.md:138 - cited.
8. 8.4: both tests are raw-gRPC; user-visible behaviour is only inferable. Added pointers
   (error_util.rs, update_op_heads, test_cli_command_auto_reconciles_divergent_op_heads).
9. **8.5/8.6 were wrong**: I ran jj-cc-server (sqlite) and the prebuilt target/debug/jj. The second
   `jj cc init --repo-id shared --workspace-name desk` FAILS: `CAS conflict: write race detected
   on stale old_op_head_ids: head 000...0 no longer active in repo shared` (init always writes an
   `add workspace` op on top of root). `jj workspace add` from a cloud client leaves a broken dir.
   Working route: `cp -a` the first client dir (same workspace name): op logs are identical,
   the other side goes `working copy is stale` until `jj workspace update-stale`, and `jj undo`
   in one reverts the other's last op. 8.5/8.6 and one theory sentence rewritten accordingly.
Each numbered exercise (8.1-8.6) is answerable from the cited files after these edits.

## Requested changes to files I may not edit
- reset-sandbox.sh: no change needed (it already removes lab-*).
- check.sh: optional - 7.14 check only counts bookmarks; fine. No failures.
- README.md: if it describes 8.5/8.6 as "two-machine join works" or lists 8.x as unverified, update
  to say the second `jj cc init` on an existing repo-id fails (CAS conflict) in the checkout.
- jj-commit-cloud-onboarding/06-interactive-tutorials.md "Tutorial 2" does the same failing
  second `cc init --repo-id` (outside tutorial scope; worth knowing).
