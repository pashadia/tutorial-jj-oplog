# Lesson 08 — True op-log sync: jj Commit Cloud

## Theory

Lesson 06 established the rule: the op log **never travels**. Every clone
grows its own, and `git fetch` converges commits, not histories *of the
repo*. If you genuinely want N machines to share one op log, there are two
possible designs:

- **Replicate + merge** — every machine keeps a local op log; the machines
  exchange operations and merge logs. Divergence becomes a permanent
  fact of life, on every machine.
- **Relocate** — the op log lives in exactly one place, a server, and every
  client reads and writes it remotely. There is no second log to merge;
  the only divergence left is *concurrent appends*, same as on one machine.

**jj Commit Cloud** (the checkout at `../jj-commit-cloud`) is a working
proof-of-concept of the second design. In its own words: "a proof-of-concept
or reference implementation of a commit cloud for jj … an intern project
for one intern sponsored by Google. No guarantee of completeness,
performance, or API stability is promised at this time." Apache-2.0, closed to PRs, no CI. Read it
as an experiment that answers a question, not as a product.

### How it works

The client is a **forked `jj` binary** (not a plugin — stock jj has no
plugin hooks for this). It registers implementations of jj-lib's storage
traits — `Backend`, `OpStore`, `OpHeadsStore`, `IndexStore`,
`WorkingCopy` — that make gRPC calls instead of touching disk
(`lib/src/cc_op_store.rs`, `lib/src/cc_op_heads_store.rs`, …). A repo
initialized by it records the choice in `type` files:

```console
.jj/repo/store/type       → commit_cloud
.jj/repo/op_store/type    → commit_cloud
.jj/repo/op_heads/type    → commit_cloud
(and .jj/repo/index/type, .jj/working_copy/type)
```

The CLI surface is exactly three commands — **there is no `jj cc sync`,
`push`, or `pull`**, and that absence is the whole point: with no local op
log, every read *is* the download and every mutating command *is* the
upload. (`cli/src/main.rs`: `Cc { Init, ImportGit, Daemon }`.)

State is split into three namespaces (our reading of the ER diagram in
`docs/database_schema.md` and `server/db/schema_sqlite.sql`):

| Namespace | Key | Holds | Shared across clients? |
|---|---|---|---|
| project | `project_id` | commits, trees, blobs | yes — shared content store |
| repo | `repo_id` | `operations`, `views`, `op_heads` | **this is the op log** |
| workspace | repo+user+name | checkout pointer | no — one row per checkout |

So: same `--repo-id` on two machines = **one shared op log** (in the model — but
see 8.5: this checkout's CLI cannot actually *join* an existing repo-id); same
`--project-id` but different `--repo-id` = isolated op logs over shared
content (proved by `cli/tests/test_project_repo_split.rs` — client 2 can
`jj show` client 1's commits via the shared index, but their op logs and
undos never interact).

The server's schema is the op log, one row per operation, never pruned
(`server/db/schema_sqlite.sql`):

```sql
CREATE TABLE operations (repo_id TEXT, op_id BLOB, data BLOB, …);
CREATE TABLE views      (repo_id TEXT, view_id BLOB, data BLOB, …);
CREATE TABLE op_heads   (repo_id TEXT, op_id BLOB, …);
```

### Divergence, contention, conflicts

Two clients writing at once is the interesting case, and the design is
explicit about it:

- **Concurrent publish from the same head**: both call
  `update_op_heads([H], H′)` / `([H], H″)`. One wins; the loser's command
  fails with an `Aborted` gRPC error — `write race detected on stale
  old_op_head_ids: head <hex> no longer active in repo <repo_id>`
  (`server/src/store/sqlitestore.rs`). CAS on the *exact set* of heads,
  retried by the user.
- **Concurrent appends** (both sides add a head): the repo now has two op
  heads — a genuine fork. `lib/src/cc_op_heads_store.rs` calls a
  `ReconcileOpHeads` RPC **on every repository load**; the server runs
  jj-lib's own `resolve_op_heads()` — the *same* 3-way view merge you met
  in lesson 05 — and publishes a normal merge operation:

  ```text
  reconcile divergent operations
  ```

  with the divergent heads as parents (`server/src/reconcile_op_heads.rs`,
  which asserts that exact description). The merge is guarded by the same
  exact-set CAS, `MAX_RETRIES = 3` with jittered exponential backoff to
  desynchronize racing reconcilers.

- **The stock-jj contrast** (this is the "aha"): locally, divergent heads
  produce `Concurrent modification detected, resolving automatically.` on
  your next command (lesson 05). In the cloud the server collapses the
  heads *before* your client ever sees them — that message never appears.
  Instead, the reconciliation is simply there in `jj op log` as a
  two-parent operation. Recovery has moved onto the hot path of every
  command.

What the 3-way merge can and cannot represent (`common/proto/op_store.proto`
+ `common/src/conversions/op_store.rs`):

- **Bookmarks keep their conflict shape** (`RefTarget` with add/remove
  terms) — two clients moving `main` concurrently yield a conflicted
  bookmark, resolved with stock `jj bookmark set` exactly as in lessons 05 and 06.
- **`wc_commit_ids` is `map<string, bytes>` — no conflict shape.** Two
  clients that share a workspace *name* have their checkout pointers
  merged *silently*, by operation end time (earliest head wins). Nothing
  enforces safety here; the rule is a convention:
  `jj cc init --workspace-name <machine-name>` on every machine. Break it
  and one machine's pointer moves out from under it — repaired by
  `jj workspace update-stale` (lesson 04).
- **Tags, `git_refs`, `git_head` are dropped on the wire** — a view
  round-tripped through the cloud comes back *normalized* without them,
  so a tag set on one client vanishes on the next read. A view is not
  fully replicated.

### Costs, caveats, and the open question

- The op log is **never pruned** — `OpStore::gc` is a no-op, so `jj util
  gc` can't expire anything; one full view is stored per snapshot.
- Op ids are 16-byte truncated SHA-1 of the server's own canonical form —
  not jj's BLAKE2b ids; short op-id prefixes are unimplemented
  (`resolve_operation_id_prefix`), so `jj op show <prefix>` doesn't work
  on cloud repos (full ids do).
- **No auth, no TLS, no ACLs** ("Every caller can read or write any
  project/repo" — the sibling onboarding guide
  `../jj-commit-cloud-onboarding/04-network-protocol.md`, not the checkout;
  in the checkout `docs/design/requirements.md` §14 lists TLS as a non-goal and
  the only auth code is an optional `JJ_CC_AUTH_TOKEN` bearer header in
  `lib/src/git_importer.rs`). **Offline is fatal**, not queued: no
  local mirror, no retry; commands fail if the server is unreachable.
- **Version trap**: the checkout pins jj-lib/jj-cli **0.43.0** — while
  this tutorial targets 0.46.0, where the `View` shape already moved on
  (`git_head` → `git_heads`). The PoC cannot drop into a 0.46 install;
  treat everything it runs as 0.43-era behavior. (Its design docs,
  however, say "Verified against jj-lib 0.46.0" — `docs/design/design-notes.md`.)
- The project's *own* design docs currently debate whether the op log
  belongs in a cloud at all — the alternative proposal is "Keep jj's
  operation log **exactly as jj intends it: local, and never transmitted.**
  Add a second, commit-cloud-specific log — a log of _observable change_ — and
  propagate only that" (`docs/design/observable-change-log.md` §1). The PoC proves it *can* be
  done; whether it *should* is an open argument (`docs/design/op-log-scope-decision.md` calls this design "cell F" and prices it).

## Exercises

This lesson is a **reading lab** — the sandbox stays untouched. Paths
below assume the checkout sits at `../jj-commit-cloud`; every claim names
its source so you can follow along without it.

**8.1** Map the architecture. Open `cli/src/main.rs` (how the stock CLI is
extended), `lib/src/repo.rs` (`add_commit_cloud` — four store factories: backend, op
store, op-heads store, index store; the fifth, the working-copy factory, is
registered in `cli/src/main.rs`),
and `cli/src/commands/init.rs` (`--project-id` / `--repo-id` / 
`--workspace-name` help text). Answer: why is there no `sync` command,
and what would one even do?

**8.2** Trace the reconcile path. In `server/src/reconcile_op_heads.rs`,
find: the fast path (`heads.len() <= 1`), the jj-lib adapters, the
`MAX_RETRIES = 3` + backoff loop, and the asserted description of the
merge operation. Then compare with stock jj's *local* healing in
`jj-upstream/lib/src/repo.rs` (search for `reconcile divergent
operations`). Same machinery, different execution site — write one
sentence on why that difference means the stock
`Concurrent modification detected` message can't appear in the cloud.

**8.3** Catalog what crosses the wire. Read `common/proto/op_store.proto`
(`OperationMetadata`, `View`, `RefTarget`, `RemoteRef`) and
`common/src/conversions/op_store.rs` (`view_to_proto` / `view_from_proto`).
List the view fields that don't survive the round trip, and predict the
user-visible consequence of each (tags, git refs, git head). Which
operation metadata fields *do* travel — and what does that mean for
`jj op log` forensics across machines (hostname! username!)?

**8.4** Find the contention story. Read
`cli/tests/test_concurrent_op_heads.rs`:
`test_sqlite_concurrent_write_race_fails_on_stale_old_heads` (the `Aborted`
CAS conflict) and `test_stress_concurrent_op_heads_writes_sqlite` (20
concurrent appends, all surviving). Both tests speak raw gRPC, so what the
*user* sees on the losing client has to be inferred: follow the error up
through `server/src/error_util.rs` (`CasConflict` → `Status::aborted`) and
`update_op_heads` in `lib/src/cc_op_heads_store.rs` (→ `OpHeadsStoreError::Write`).
Then read `test_cli_command_auto_reconciles_divergent_op_heads` in the same
file for the append side: a CLI command just succeeds.

**8.5** The two-machine join — **tried, and the obvious route fails**.
Nothing in either checkout runs two `jj cc init` with the same `--repo-id`
(`cli/tests/test_project_repo_split.rs` uses a *different* repo-id per client).
Sketch the exact commands (two clients, same `--repo-id`, *distinct*
`--workspace-name`s) and predict what happens. Then try it with the prebuilt
binaries (8.6). Observed: the first `jj cc init` works; the second prints

```text
Error: Failed to initialize workspace: TransactionCommit(OpHeadsStore(Write { new_op_id: OperationId("…"), source: Status { code: Aborted, message: "CAS conflict: write race detected on stale old_op_head_ids: head 00000000000000000000000000000000 no longer active in repo shared", … } }))
```

Explain why from `cli/src/commands/init.rs` (`Workspace::init_with_factories`
always commits an `add workspace` op on top of the *root* op) and the CAS in
`server/src/store/sqlitestore.rs`. `jj workspace add --name desk ../desk` from
the first client doesn't work either (it leaves a broken `../desk`). So in this
PoC a second client can only be a **copy** of the first client's directory
(`cp -a laptop desk`) — which carries the same workspace name. Finish the
exercise on that: explain what protects each client's checkout pointer when the
names are distinct, and what silently overwrites it when they collide (§
`wc_commit_ids` merge, tie-break by operation end time).

**8.6** *(Optional — heavyweight, 0.43-era)* Run it for real. The checkout
already has `target/debug/jj` and `target/debug/jj-cc-server` built (otherwise
`cargo build` in the checkout). Start
`./target/debug/jj-cc-server --port 8080 --store-type sqlite` (the database
defaults to `~/.jj-cc-server/commit_cloud.db`; add `--sqlite-path <file>` to keep
it elsewhere), then in one directory
`./target/debug/jj cc init --server http://localhost:8080 --project-id demo
--repo-id shared --workspace-name laptop` and try the same with
`--workspace-name desk` in a second one (it fails: 8.5). Make a second client
with `cp -a` of the first directory instead; run commands in both. Observed:
`jj op log` is identical in both, the other client reports `The working copy is
stale (not updated since operation …)` until `jj workspace update-stale` (the
copy shares the workspace name), and `jj undo` in one reverts the other's last
operation. Keep it on localhost: there is no authentication. Expect 0.43
behavior, not 0.46.

## Verify

```console
./check.sh 08     # informational — this lesson's deliverable is your notes
```
