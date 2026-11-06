# R4 — jj commit cloud (`jj-commit-cloud`): what it is, what it syncs, and whether it syncs the operation log

**Research task.** Read-only source/doc study for a tutorial chapter on the jj operation log, targeting
jj 0.46.0, whose capstone must cover TRUE operation-log synchronization over a network — something
stock jj never does. This document describes the only code in reach that does it: the jj commit cloud
extension.

---

## 0. Evidence base, and one naming correction

| What | Where | Version / identity |
|---|---|---|
| The implementation | `/home/bogdan/work/google-jj/jj-commit-cloud` | git `eb12f85e1d423d4659567cc6fa95c0184dbd1f21`, committed `2026-11-02 23:58:26 +0100`, detached HEAD; remote `https://github.com/pashadia/jj-commit-cloud.git` |
| An onboarding curriculum written *about* it | `/home/bogdan/work/google-jj/jj-commit-cloud-onboarding` | 11 chapters (`00`–`09`, incl. `01.5`) + `2026 Deliverables.md`, dated Oct 2026; describes branch `srachaba-docs@origin` (2026-09-18) |
| Cross-check only (for stock-jj claims) | `/home/bogdan/work/google-jj/jj-upstream` | `v0.46.0-203-gbdefa37df` |

**Naming.** The brief calls this "jujutsu-sync". That string appears **nowhere** in either checkout
(`grep -ri "jujutsu-sync"` → no match). The extension's own names are:

- README title: `# jj Commit Cloud Proof-of-Concept` (`README.md:1`)
- Cargo workspace members: `server`, `testutils`, `cli`, `lib`, `common`, `daemon` (`Cargo.toml`)
- binaries: `jj-cc-server` (`server/Cargo.toml`), `jj-cc-daemon` (`daemon/Cargo.toml`), and a binary
  named literally `jj` (`cli/Cargo.toml`, `[[bin]] name = "jj"`)
- clap name strings: `"Jujutsu Commit Cloud Server"` (`server/src/main.rs`, `#[command(name = "jj-cc-server", about = ...)]`)
  and `"Commit Cloud Local Daemon"` (`daemon/src/main.rs`)

**Command namespace.** There is no `jj cloud …`. The subcommand is **`jj cc`**:

```rust
// cli/src/main.rs
enum CustomCommands { Cc { #[command(subcommand)] subcommand: CcCommands } }
enum CcCommands {
    /// Initialize a remote Commit Cloud repository and local working copy
    Init(commands::init::CcInitArgs),
    /// Import an existing Git repository into Commit Cloud
    ImportGit(commands::import_git::ImportGitArgs),
    /// Configure Commit Cloud daemon settings
    Daemon(commands::daemon::DaemonArgs),
}
```

---

## 1. What it is

### 1.1 Purpose and self-description

> "This project provides a proof-of-concept or reference implementation of a commit cloud for
> [jj](http://github.com/jj-vcs/jj). It is beginning life as an intern project for one intern
> sponsored by Google. No guarantee of completeness, performance, or API stability is promised at
> this time."
> — `README.md`, opening paragraph

`docs/architecture.md` states the design inversion that makes it interesting for an op-log tutorial:
the client implements jj's **storage traits** as gRPC calls, so "the server owns … the operation log and
views for each repository" (onboarding `01-what-is-commit-cloud.md`, "The vision").

### 1.2 Scope

In scope, from `docs/architecture.md` ("Crates") and the code:

- Implementations of jj-lib's `Backend`, `OpStore`, `OpHeadsStore`, `IndexStore`, and `WorkingCopy`
  traits that make RPCs to a remote server (`lib/src/cc_backend.rs`, `cc_op_store.rs`,
  `cc_op_heads_store.rs`, `cc_index_store.rs`, `cc_working_copy.rs`).
- A custom `jj` binary that registers those factories with `jj_cli::cli_util::CliRunner` and adds the
  `jj cc` subcommands (`cli/src/main.rs`).
- A gRPC server (`jj-cc-server`) over three services — `BackendService`, `OpStoreService`,
  `WorkspaceService` — plus gRPC health (`common/proto/*.proto`, `server/src/main.rs`).
- Pluggable server storage: `MemoryStore`, `SqliteStore`, `SpannerStore` behind one async `Store`
  trait (`server/src/store/mod.rs`, `docs/architecture.md` "Backend Schema & Store").
- A local Unix-domain-socket proxy daemon to avoid per-command connection setup (`daemon/`).
- A one-way Git importer, `jj cc import-git` (`lib/src/git_importer.rs`).

Explicitly out of scope, per the onboarding (`01-what-is-commit-cloud.md`, "What is explicitly out of
scope in the PoC"): "Authentication or authorization", "TLS / encryption in transit", "Scalable blob
storage (GCS/S3) — files are stored inline in SQLite/Spanner rows", "Production deployment, Terraform,
Kubernetes manifests", and "Upstream `jj` plugin/extensibility hooks".

### 1.3 Maturity / status

- **No badges.** `README.md` contains no shields/badges, no CI status, no version, no install
  instructions; it has only the description, the Apache header requirement, and that is all.
- **No CI.** `.github/` contains exactly two files: `ISSUE_TEMPLATE/bug_report.md` and
  `PULL_REQUEST_TEMPLATE.md`. There is no `workflows/` directory.
- **Closed to contributions right now.** `docs/contributing.md`: "During the early stages of this
  project, pull requests will not be accepted. … right now (June-September 2026) it is only
  source-available."
- **Self-declared non-production.** onboarding `08-current-limitations-and-next-steps.md` opens with
  "The PoC is not production software"; onboarding `01-what-is-commit-cloud.md` says the same in the
  same words ("The PoC is not production software. It is a reference implementation").
- **Actively-churning design layer.** `docs/design/` holds 5 documents (~1,600 lines) dated Oct–Nov
  2026 that argue about what the *next* system should be, including one titled
  `op-log-scope-decision.md` whose §1 says "**Recommendation:** none — §4.4 compares the costs;
  acceptance is not an engineering call." None of these are implemented; see §7.4 below.
- **Tests exist and are behavioural.** 10 integration test files under `cli/tests/` spawn a real
  server and run the real `jj` binary (`testutils/src/lib.rs`, `spawn_server`, `TestWorkspace`).

### 1.4 Relationship to Google's internal tooling

No file in either checkout names an internal system, and there is no import, mirror, or compatibility
layer for one. What the checkouts *do* say, precisely:

- Sponsorship and provenance: "an intern project for one intern sponsored by Google" (`README.md`);
  Apache headers "Copyright 2026 Google LLC" (`README.md`, "Source Code Headers"); Google CLA required
  for contributions (`docs/contributing.md`); "Google's Open Source Community Guidelines" adopted
  (`docs/contributing.md`, and `docs/code-of-conduct.md` is Contributor Covenant 3.0).
- Deployment target is Google Cloud: `Dockerfile:1` "Multi-stage Dockerfile for deploying
  jj-cc-server on Google Cloud Run", runtime `CMD` uses `--store-type spanner` with `SPANNER_DATABASE`;
  `server/Cargo.toml` depends on `google-cloud-spanner = "0.34.4-preview"`; onboarding
  `07-decision-log.md` §7 "Spanner as the production target backend — Matches Google's production
  storage choice."
- Two heredity signals in code: `server/src/hash_utils.rs:4` "Matches length-prefixed hashing used
  internally at Google" (that is the op-id/view-id canonicalisation, §2.4), and
  `common/proto/op_store.proto` "We use Protobuf map fields to cleanly represent key-value mappings
  (Google internal does this)".
- The *name* "commit cloud" and the *feature shape* (a per-user cloud copy of unpublished work) mirror
  Google's internal Commit Cloud in the Piper/CitC lineage, but **that lineage is never stated in
  these checkouts** — see "Gaps & uncertainties".
- The contract layer (`jj-commit-cloud-onboarding/2026 Deliverables.md`) is written for a Google-side
  owner: WS-1 "Productionize the Open-Source Commit-Cloud — Audit jj-commit-cloud-poc codebase, storage
  schemas, gRPC protocols", WS-4 "Make jj Extensible (jj_lib Plugin & RPC Architecture)", WS-6
  mentions "Google's functional specs". It even lists as an open question: "Location / ownership of
  `jj-commit-cloud-poc` — Is this a public repository, an internal Google repo, or a branch within
  another repo?" (`2026 Deliverables.md`, 31 October 2026, WS-1 M1).

### 1.5 License

Apache License 2.0. `LICENSE` is the unmodified Apache-2.0 text; `README.md` "Source Code Headers"
prescribes the header for every source file ("Copyright 2026 Google LLC … Licensed under the Apache
License, Version 2.0"). Note the licence/availability split: `docs/contributing.md` calls the project
"only source-available" for now, which is about accepting contributions, not about the licence terms.

---

## 2. What exactly gets synced

### 2.1 Three namespaces, and which one is "the sync unit"

`docs/database_schema.md` and `server/src/store/mod.rs` split all state into three keys:

| Namespace | Key | Holds | Shared across? |
|---|---|---|---|
| **project** | `project_id` | commits, trees, files (blobs), symlinks | **yes** — many repos in one project share the content store |
| **repo** | `repo_id` | `operations`, `views`, `op_heads` | no — this is the op log |
| **workspace** | (`repo_id`,`user`,`workspace_name`) | `commit_id`, `operation_id`, `tree_id` | no — one row per checkout |

The proto makes the intent explicit: `RegisterRepository` is documented as "Register a new repository
**(private op log)** inside a project on the remote backend"
(`common/proto/backend.proto`, service comment). `cli/src/commands/init.rs` says the same in flag help:
`--project-id` "Project ID (owns shared commit/tree/file storage)", `--repo-id` "Optional Repository ID
(**owns operation log**; generates a new UUID if omitted)".

**Consequence for capture in the tutorial:** op-log sharing is achieved by *sharing a `repo_id`*, not a
project. Two machines that pass the same `--repo-id` are two clients of one op log. Two machines with
different `repo_id` but the same `--project-id` have *isolated op logs over shared content* — this is
asserted by `cli/tests/test_project_repo_split.rs::test_multiple_repos_share_project_cas_with_isolated_oplog_and_undo`.

### 2.2 Content (project-level) — synced

Commits, trees, file blobs, and symlink records, keyed by content hash, immutable, deduplicated by id.
`BackendService` RPCs: `ReadCommit`, `WriteCommit`, `ListProjectCommits`, `ReadTree`, `WriteTree`,
`ReadFile` (server-streaming), `WriteFile` (unary), `ReadSymlink`, `WriteSymlink`
(`common/proto/backend.proto`). The server computes the ids itself, in **Git object format**, so
`commit_id` is a real Git SHA-1: `compute_git_commit_hash`, `compute_git_tree_hash`,
`compute_git_blob_hash` (`server/src/hash_utils.rs`), called from `server/src/backend.rs`
(`write_commit`/`write_tree`/`write_file`). `lib/src/cc_backend.rs::write_commit` sends
`commit_id: vec![]` (`common/src/conversions/backend.rs::commit_to_proto`) and takes back the id the
server computed — an interesting inversion of jj's usual client-computed ids.

Caveat: symlink RPCs return `tonic::Status::unimplemented("Not implemented yet")`
(`server/src/backend.rs`, `read_symlink`/`write_symlink`), even though `symlinks` exists in both schemas.
Git submodules are not modelled at all.

### 2.3 Repo-level: **the operation log is synced — in full**

Yes. Unambiguously, and this is the whole point of the extension. Evidence:

1. The `OpStore` trait is implemented over three RPCs — `ReadOperation`, `WriteOperation`, `ReadView`,
   `WriteView` — with `repo_id` as the key (`common/proto/op_store.proto`, `lib/src/cc_op_store.rs`).
   There is no local op store on disk; see §2.6.
2. `OpHeadsStore` is `GetOpHeads` / `UpdateOpHeads` / `ReconcileOpHeads`
   (`common/proto/op_store.proto`, `lib/src/cc_op_heads_store.rs`).
3. The schema stores them as first-class tables, one row per operation, one per view, one per head:

```sql
-- server/db/schema_sqlite.sql
CREATE TABLE IF NOT EXISTS operations (
    repo_id TEXT NOT NULL, op_id BLOB NOT NULL, data BLOB NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (repo_id, op_id));
CREATE TABLE IF NOT EXISTS views (
    repo_id TEXT NOT NULL, view_id BLOB NOT NULL, data BLOB NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (repo_id, view_id));
CREATE TABLE IF NOT EXISTS op_heads (
    repo_id TEXT NOT NULL, op_id BLOB NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (repo_id, op_id));
```

`docs/database_schema.md` draws the same entity-relationship graph (`repos ||--o{ operations`,
`repos ||--o{ views`, `repos ||--o{ op_heads`, `op_heads ||--|| operations`).
4. The proto comment claims the difference from upstream jj explicitly:

```protobuf
// common/proto/op_store.proto
// Service interface for remote Operation Store and OpHeads Store RPCs
// An operation is a single step in time (like running `jj describe`), making history undoable
```

**How an operation is represented.** `Operation` is stored as protobuf `data`, field-for-field from
jj-lib's `Operation` (`common/src/conversions/op_store.rs::operation_to_proto`):

```protobuf
message OperationMetadata {
  int64 start_time_millis = 1; int64 end_time_millis = 2; string description = 3;
  bool is_snapshot = 4; optional string workspace_name = 5;
  string hostname = 6; string username = 7; map<string, string> attributes = 8;
}
message CommitPredecessors { bytes commit_id = 1; repeated bytes predecessor_ids = 2; }
message Operation {
  bytes view_id = 1; repeated bytes parents = 2; OperationMetadata metadata = 3;
  repeated CommitPredecessors commit_predecessors = 4; bool commit_predecessors_set = 5;
}
```

So **the rewrite/evolog provenance travels**: `commit_predecessors` plus
`commit_predecessors_set` (which distinguishes "empty map" from "written by pre-0.30 jj" —
`common/src/conversions/op_store.rs::operation_from_proto` rebuilds `Option<BTreeMap<...>>`).
Note the lossy bits: `TimestampRange` loses `tz_offset` (`operation_from_proto` hardcodes
`tz_offset: 0`), and `start/end` survive only as millis.

**Ids are computed server-side**, deterministically over sorted map keys
(`server/src/hash_utils.rs::hash_operation`, `hash_view`):
`gix::objs::compute_hash(Sha1, Kind::Blob, buf)` truncated to `OPERATION_ID_LENGTH = 16` /
`VIEW_ID_LENGTH = 16` (`common/src/lib.rs`). Canonicalisation uses length-prefixed fields
(`append_length_prefixed_bytes`) "to prevent boundary hash collisions".
**Important**: this is *not* jj's own operation-id algorithm. jj hashes with BLAKE2b-512 — "BLAKE2b-512
hash length in bytes" (`jj-upstream/lib/src/simple_op_store.rs:69`), `OperationId::new(blake2b_hash(
operation).to_vec())` (`:207`), same for `ViewId` (`:162`) — and the inputs are jj's own serde form,
not this length-prefixed canonicalisation. `docs/design/op-log-scope-decision.md` §3.1 makes the
consequence explicit: "Normal `ViewId` and `OperationId` values are content hashes, and `OperationId`
includes local metadata (`hostname`, `workspace_name`, wall-clock time), so two machines produce
different ids for the same logical change." The cloud's ids are 16-byte truncated SHA-1 of a different
canonical form, and those are what `jj op log` shows.

### 2.4 The view — exactly which fields are synced, and which are dropped

```protobuf
// common/proto/op_store.proto — with the authors' own comment
// git fields (git_refs, git heads, etc) in upstream Views proto are omitted here
message View {
  repeated bytes head_ids = 1;
  map<string, bytes> wc_commit_ids = 2;
  map<string, RefTarget> local_bookmarks = 3;
  map<string, RemoteRef> remote_bookmarks = 4;
}
message RefTarget { repeated RefTargetTerm removes = 1; repeated RefTargetTerm adds = 2; }
message RemoteRef { RefTarget target = 1; bool is_tracked = 2; }
```

Mapping to jj-lib 0.43's seven `View` fields (enumerated in `docs/design/op-log-scope-decision.md` §3.3):

| jj `View` field | Synced? | Where |
|---|---|---|
| 1 `head_ids` (`HashSet<CommitId>`) | **yes** | `View.head_ids` |
| 2 `local_bookmarks` (`RefTarget`) | **yes**, add/remove terms preserved → **conflicted bookmarks survive** | `View.local_bookmarks` |
| 3 `local_tags` | **NO — dropped, silently** | `view_from_proto` sets `local_tags: BTreeMap::new()` |
| 4 `remote_views` (remote-tracking refs + tracked flag) | **partly** — flattened to `"<bookmark>@<remote>" → {target, is_tracked}`; rebuilt with `rsplit_once('@')` | `view_to_proto` / `view_from_proto` |
| 5 `git_refs` | **NO — dropped** | `view_from_proto` sets `git_refs: BTreeMap::new()` |
| 6 `git_head` / `git_heads` | **NO — dropped** | `view_from_proto` sets `git_head: RefTarget::absent()` |
| 7 `wc_commit_ids` (`BTreeMap<WorkspaceNameBuf, CommitId>`) | **yes** — the working-copy pointer | `View.wc_commit_ids` |

Consequences worth stating in the tutorial, all citable from `common/src/conversions/op_store.rs`:

- **`jj tag` is not durable in the cloud.** A tag set on one client is gone on the next read
  (round-trip through `write_view`/`read_view` erases it), because `local_tags` is never serialised.
- **A view is not fully replicated.** Round-tripping a view through the cloud *normalises* it: tags,
  `git_refs` and `git_head` disappear. Two clients can therefore never `git export` from cloud state.
- **Ref targets keep their conflict shape.** `ref_target_to_proto` writes `removed_ids()` and
  `added_ids()`; `ref_target_from_proto` reconstructs with `RefTarget::from_legacy_form(removed, added)`.
  A bookmarked-but-conflicted ref is representable, and jj's own 3-way ref merge runs on it (§4.3).
- **`wc_commit_ids` is `map<string, bytes>` — one commit per workspace, no `Merge`.** That is a hard
  ceiling on merging working-copy pointers, discussed in §4.4.

### 2.5 Is the full op history kept, or a truncated subset?

**Full, and never pruned.** Three independent mechanisms, all no-ops:

- `lib/src/cc_op_store.rs`:
  ```rust
  async fn gc(&self, _head_ids: &[OperationId], _keep_newer: SystemTime) -> OpStoreResult<()> { Ok(()) }
  ```
  So `jj util gc` (which calls `OpStore::gc` in stock jj) cannot expire anything.
- The `Store` trait has no `delete_operation`, `delete_view`, or prune method at all
  (`server/src/store/mod.rs` lists every method), and neither `schema_sqlite.sql` nor `schema_spanner.sql`
  has a retention column or sweep.
- Write paths never overwrite: `put_operation`/`put_view` are plain inserts keyed by content hash;
  `op_heads` rows are added/removed, `operations`/`views` rows never are.

There is also **no server-side filtering**: every operation any client wrote — including
`is_snapshot: true` snapshot operations, working-copy-pointer moves, and `jj op abandon` operations —
is stored. This is exactly the "every operation from every machine, each with a complete view"
design that `docs/design/op-log-scope-decision.md` §4.3 calls cell **F**, and that
`docs/design/observable-change-log.md` §1 argues *against* keeping.

### 2.6 How are other clients' operations "integrated" into the local op log?

**They are not integrated — there is no local op log to integrate into.** This is the single most
important architectural fact for the tutorial, and it is easy to miss.

`jj cc init` writes three `type` files (asserted in `cli/tests/test_op_log_command.rs` and
`cli/tests/test_cloud_init.rs`):

```
.jj/repo/store/type        -> "commit_cloud"   (Backend)
.jj/repo/op_store/type     -> "commit_cloud"   (OpStore)
.jj/repo/op_heads/type     -> "commit_cloud"   (OpHeadsStore)
.jj/repo/index/type        -> "commit_cloud"   (IndexStore)
.jj/working_copy/type      -> "commit_cloud" | "local"
```

plus `.jj/repo/store/config.toml`:

```toml
server_url = "http://…"
project_id = "…"
repo_id = "…"          # UUID if not supplied
use_daemon = true
daemon_socket = "…"    # optional
```
(`lib/src/util.rs::CommitCloudConfig`, asserted in `cli/tests/test_cloud_init.rs::test_cc_init_creates_local_workspace`.)

Every `OpStore`/`OpHeadsStore` method is an RPC. There is no `.jj/repo/op_store/operations/`
directory, no `.jj/repo/op_heads/heads/` — so:

- **"Upload"** happens because there is nothing else to write to: when the client's transaction calls
  `OpStore::write_operation`, the operation is *created* on the server.
- **"Download"** happens because there is nothing else to read from: `OpStore::read_operation` on an
  op id the client has never seen is just another RPC, indistinguishable from reading its own.
- The client's **only** local cache is the commit index (`lib/src/cc_index_store.rs`), which wraps
  jj's `DefaultIndexStore` and, on each `get_index_at_op`, calls `ListProjectCommits` and
  `add_commit_recursive` for any commit id in the project that the index lacks. That is how another
  client's commits become nameable (`jj show <id>`) before any of their ops are relevant — proved by
  `cli/tests/test_project_repo_split.rs`, which requires client 2 to `jj show` and `jj new` client 1's
  commit even though they are in *different* repos of the same project.

So the correct statement for the tutorial is: **the cloud replaces the op log rather than replicating
it.** Convergence is not achieved by merging two logs; it is achieved by the absence of a second log.
Nothing in the client has to "apply" another client's operation; the next `jj` command simply reads a
log that already contains it. The only genuine synchronisation problem left is the one that also exists
inside one machine — concurrent appends creating divergent *op heads* — and that is handled by the
server (§4).

### 2.7 Working-copy / checkout state — synced, twice

Two distinct things are stored, and the tutorial should not conflate them:

1. **The pointer** `wc_commit_ids[workspace]` inside every view — the commit the workspace *should*
   have checked out (jj's own model, `core/src/op_store.rs:193` per `docs/design/design-notes.md` §6).
2. **The `workspaces` row** — the cloud's own bookkeeping, outside any operation:

```protobuf
// common/proto/workspace.proto
message WorkspaceState { string repo_id = 1; string user = 2; string workspace_name = 3;
                         bytes commit_id = 4; bytes operation_id = 5; bytes tree_id = 6; }
```
`lib/src/cc_working_copy.rs` pushes this on `init_working_copy` **and** on every
`LockedCommitCloudWorkingCopy::finish(new_operation_id)`; `user` comes from jj config
`user.email` (`resolve_user`, whose error string is: "User email (user.email) is not configured in
user settings. Run `jj config set --user user.email <email>`"). `tree_id` is used by
`WorkspaceService::CheckWorkingCopyChanges` to answer "does this checkout have unsnapshotted
changes" (`server/src/workspace.rs`). Note the push is best-effort — `let _ = run_async(...)` — so a
failed workspace-state update does not fail the command.

### 2.8 Summary table — what crosses the wire, what does not

| Thing | Synced? | Source of truth |
|---|---|---|
| operation objects (metadata, parents, view_id, predecessors) | **yes, all of them, forever** | `OpStoreService`, `operations` table |
| views (heads, bookmarks, remote-tracking bookmarks, wc pointers) | **yes, minus §2.4 drops** | `views` table |
| op heads (the divergence set) | **yes**, with CAS | `op_heads` table |
| commits / trees / blobs / symlinks* | yes (content, project-scoped) | `BackendService` |
| tags | **no** | `local_tags` dropped in `view_from_proto` |
| `git_refs`, `git_head(s)` | **no** | dropped in `view_from_proto` |
| commit index | **no** — rebuilt locally per client | `lib/src/cc_index_store.rs` |
| working-copy *files* on disk | no (each client materialises its own) | `CommitCloudWorkingCopy` wraps `LocalWorkingCopy` |
| jj config, aliases, revsets | no | — |
| *symlink RPCs currently `unimplemented`* | — | `server/src/backend.rs` |

---

## 3. Architecture

### 3.1 Crate graph

From `docs/architecture.md` ("Crates") and the Cargo manifests:

```
cli (bin: jj)  ──► cc-lib ──► jj-lib 0.43.0
   │                 │
   │                 └──► common (protox/tonic stubs, conversions)  ──► jj-lib
   └──► jj-cli 0.43.0
jj-cc-server ──► common, jj-lib 0.43.0, gix, rusqlite, google-cloud-spanner
jj-cc-daemon ──► common (proxy only)
testutils    ──► builds server + daemon + jj in build.rs, drives them
```

`docs/architecture.md` describes the client as implementing "**Backend**, **OpStore**, **OpHeadsStore**,
**IndexStore**, and **WorkingCopy**" and the RPC layer as "three services: **BackendService**,
**OpStoreService**, and **WorkspaceService**".

### 3.2 The client "plugin": a fork of the CLI, not a plugin

`cli/src/main.rs` builds the whole stock CLI and injects two things:

```rust
fn main() -> ExitCode {
    CliRunner::init()
        .add_store_factories(create_store_factories())          // "commit_cloud" backend/op_store/op_heads/index
        .add_working_copy_factories(create_working_copy_factories())
        .add_subcommand(run_custom_command)                      // `jj cc …`
        .run().into()
}
```

Registration by name string is in `lib/src/repo.rs::StoreFactoriesExt::add_commit_cloud`
(`self.add_backend("commit_cloud", …)`, `add_op_store`, `add_op_heads_store`, `add_index_store`).
Because factories are registered under a *name*, the choice is persisted per repo in the `type` files
above — so a repo is permanently bound to this build of the binary. `docs/design/op-log-scope-decision.md`
§4.3 (cell F) flags the same thing: "the stock `jj` binary registers only built-in implementations
(`cli/src/cli_util.rs:4137`), so this requires either a custom binary or an upstream change."

**Every stock jj command therefore runs unchanged, over the network**: `log`, `new`, `describe`,
`op log`, `undo`, `sparse`, `workspace`, `util gc`. That is the sense in which the "plugin" is a
whole-binary replacement.

### 3.3 The daemon: lazy spawn on first RPC, no op-log watching, no debounce

This matters because the brief asks "does it watch the op log?" — **it does not watch anything.**

- `daemon/src/main.rs` is a pure proxy: it binds a Unix socket and re-exports `BackendService`,
  `OpStoreService`, `WorkspaceService` to the remote server via `RemoteConnectionManager`.
  `daemon/src/proxy_op_store.rs` is one-line pass-throughs for all seven RPCs. There is no cache.
  (onboarding `07-decision-log.md` §9: "Goal: eliminate TCP handshake overhead"; onboarding
  `08-current-limitations-and-next-steps.md` §4: "The daemon proxies RPCs but does not cache blobs or
  operations locally. No LRU eviction, no cache invalidation, no offline mode.")
- **Trigger** is the client, not a watcher: `lib/src/client.rs::connect_channel` tries
  `UnixStream::connect(socket)`; on failure it calls `spawn_daemon(server, socket)`, which runs
  `jj-cc-daemon --server … --socket …` in its own process group with stdio nulled and polls the socket
  for up to 3 seconds. Failure to spawn is non-fatal:
  `"Warning: failed to start daemon ({e}), falling back to direct gRPC"`.
  If the binary cannot be found: `"Could not locate 'jj-cc-daemon' binary. Ensure it is built and in PATH."`
  Timeout: `"Timed out waiting for daemon to start at {}"`.
- Socket path: `/tmp/jj-cc-daemon-<USER>-<hash(server_url)>.sock` (`get_default_daemon_socket`), or
  `daemon_socket` from `config.toml`.
- `--idle-timeout` is declared (`daemon/src/main.rs`, `#[arg(long)] idle_timeout: Option<u64>`) but
  **never read**; grep for `idle_timeout` finds only the declaration. The daemon also has no
  auto-exit; it dies when its process group does.
- Test evidence: `cli/tests/test_daemon.rs::test_daemon_auto_spawn_on_cli_command` asserts the socket
  does not exist before a `jj describe` and does after.

**A snapshot is therefore still stock-jj behaviour**: the working copy is snapshotted when a command
runs (plus jj's own filesystem-monitor debounce, which is upstream behaviour, not cloud code).
`LockedCommitCloudWorkingCopy::snapshot` just forwards to the inner `LocalWorkingCopy`
(`lib/src/cc_working_copy.rs`). Nothing in this codebase schedules snapshots.

### 3.4 The server: one binary, three stores, three deploy shapes

`server/src/main.rs`:

```
jj-cc-server --host <ip, default 127.0.0.1> --port <u16, default 8080>
             --store-type <memory|sqlite|spanner>   (default: memory)
             --sqlite-path <path>  (default: $HOME/.jj-cc-server/commit_cloud.db)
             --spanner-db <projects/…/databases/…>  (env: SPANNER_DATABASE)
```

It serves gRPC + `tonic_health`, logs `"jj-cc-server listening on {}"` (which the test harness greps
for), and shuts down on Ctrl-C.

Deployment: a two-stage `Dockerfile` "for deploying jj-cc-server on Google Cloud Run", building
`--release --bin jj-cc-server`, `ENV PORT=8080`, `EXPOSE 8080`, and running
`jj-cc-server --host 0.0.0.0 --port ${PORT:-8080} --store-type spanner --spanner-db ${SPANNER_DATABASE}`.
`docs/workflow.md` gives the two local invocations:

```bash
sjjs --port 8080 --store-type sqlite
sjjs --port 8080 --store-type spanner --spanner-db <SPANNER_LINK>
```

Storage semantics that matter: `SqliteStore` holds one `Arc<Mutex<Connection>>` and runs every call in
`tokio::task::spawn_blocking`, so one process serialises SQLite access; `SpannerStore` uses
`single_use()` transactions for reads and `write_only_transaction()` for writes.

### 3.5 Auth: there is none, with one vestigial hook

- No TLS, no interceptor, no token check anywhere in `server/`. `server/src/main.rs` builds
  `Server::builder().add_service(...)` with no `interceptor`, and `grep -ri "authorization\|bearer\|
  interceptor\|tls"` over `server/` finds nothing.
- Identity is self-asserted free text in two places: `OperationMetadata.username`/`hostname` (from the
  client's jj config / machine) and the `user` field of the `workspaces` row, taken from `user.email`.
  Onboarding `04-network-protocol.md` states it plainly: "There is **no TLS** and **no authentication**
  in the PoC. Every caller can read or write any project/repo."
- `lib/src/git_importer.rs::make_request` optionally adds a bearer token:
  ```rust
  if let Ok(token) = std::env::var("JJ_CC_AUTH_TOKEN") {
      if let Ok(val) = format!("Bearer {}", token).parse() {
          req.metadata_mut().insert("authorization", val);
  ```
  This is the **only** reference to `JJ_CC_AUTH_TOKEN` in the tree, it is used only by the Git
  importer, and the server never inspects the header. It is a placeholder for the auth work in
  onboarding `08-current-limitations-and-next-steps.md` §1 ("No authentication … No authorization …
  No TLS") and Step 4 ("Add auth interceptors and repository ACLs").
- The nearest thing to a security boundary is accidental: cross-*project* content reads fail because
  `read_commit`/`read_view` first call `ensure_project_registered_error`/`ensure_repo_registered_error`
  (`server/src/error_util.rs`) and then look up inside the given namespace. Asserted by
  `cli/tests/test_project_repo_split.rs::test_cross_project_isolation_blocks_access_to_other_projects_commits`
  (client in `project-beta` cannot `jj show` a commit id from `project-alpha`). Any caller who *knows*
  the right `project_id` is still allowed.

### 3.6 Offline and network partitions

**Offline is fatal, not deferred.** There is no write queue, no dirty flag, no local op mirror, and no
retry logic beyond the daemon's lazy reconnect. Any command that loads the repository issues
`ReconcileOpHeads`/`ReadOperation`/`ReadView`/`ReadCommit` and fails with a transport error if the
server is unreachable. Evidence:

- `cli/tests/test_cloud_init.rs::test_cc_init_fails_on_invalid_server_addr` (`--server
  http://invalid-server-domain-does-not-exist:9999`) asserts **failure**.
- `lib/src/client.rs`: the only network fallback is daemon→direct gRPC, not server→local.
- `lib/src/cc_working_copy.rs` wraps `LocalWorkingCopy`, so files remain on disk and a stale checkout
  can still be read/edited with an editor — but no `jj` command will run.
- onboarding `01-what-is-commit-cloud.md` and `08-current-limitations-and-next-steps.md` §4 both say
  "no offline mode".

The designed-for-but-unbuilt offline story is in `docs/design/requirements.md` **RQ-2-4** ("Work
continues while disconnected, **including writes**"), RQ-6-1..6-5, and `docs/design/design-notes.md`
§2a ("local + bounded push"). None of it is in `lib/`.

### 3.7 Read path (per command)

`docs/architecture.md` + `onboarding/04-network-protocol.md` "Example call flow: `jj log`", verified in
source: `RepoLoader::load_at_head` → `CommitCloudOpHeadsStore::get_op_heads` → `ReconcileOpHeads` RPC,
then `read_operation` per parent the index needs, `read_view` for each, `CommitCloudIndexStore::
get_index_at_op` (`ListProjectCommits` + `add_commit_recursive` over `read_commit`), then rendering.

### 3.8 Write path (publishing an operation)

1. Client builds the new view and operation locally (in memory), then
   `write_view` (server computes `view_id` = truncated SHA-1),
   `write_operation` (server computes `op_id`), then
   `update_op_heads(old_ids, new_id)`.
2. The server does a **stale-head check** inside one SQL transaction: every id in `old_ids` must still
   be an active head, else `StoreError::CasConflict` → gRPC `Aborted` (§4.1).
3. If the client's `old_ids` were empty, the server **appends** without checking (this is the
   "no CAS" branch, used by tests and by `import-git` to add a head).

`lib/src/cc_op_heads_store.rs::lock()` returns a no-op `CommitCloudOpHeadsStoreNoLock` with the comment
"TODO: Add support for concurrency control with locking to prevent race conditions during concurrent
client operations from overwriting operation heads." The op-heads lock is thus *absent* in the cloud
path, which is why the CAS is load-bearing.

---

## 4. Conflict and divergence handling

### 4.1 The two distinct failure modes

**(a) Client A and client B publish from the same head.** Both call `update_op_heads([H], H')` and
`update_op_heads([H], H'')`. One wins; the other gets `Aborted` with

```
write race detected on stale old_op_head_ids: head <hex> no longer active in repo <repo_id>
```
(`server/src/store/memorystore.rs:175`, `server/src/store/sqlitestore.rs:490`,
`server/src/store/spannerstore.rs:489`; mapped by `server/src/error_util.rs`:
`StoreError::CasConflict(_) => tonic::Status::aborted(msg)`).
Asserted by `cli/tests/test_concurrent_op_heads.rs::test_sqlite_concurrent_write_race_fails_on_stale_old_heads`
(`assert_eq!(status.code(), tonic::Code::Aborted); assert!(status.message().contains("CAS conflict"))`).

In practice this race is rare, because the *only* writes are inside one `jj` command on one client, and
the loser's command simply fails and is retried by the user.

**(b) A head is appended without removing the old one** (`old_ids = []`), or two clients append
concurrently. Then the repo has **more than one op head** — a genuine fork of the op log. This is the
interesting case, and it is normal, not exceptional: `test_stress_concurrent_op_heads_writes_sqlite`
appends 20 heads concurrently and asserts all 20 survive.

### 4.2 Divergent op logs are resolved **on the server**, by jj's own merge, into a new merge operation

This is the heart of the extension and deserves the tutorial's attention.
`lib/src/cc_op_heads_store.rs`:

```rust
async fn get_op_heads(&self) -> Result<Vec<OperationId>, OpHeadsStoreError> {
    self.get_op_heads_with_reconciliation().await      // ← every single repo load
}
// get_op_heads_without_reconciliation() exists but is marked:
// "Currently unused … implemented here to make the distinction … for future use"
```

So **the reconciliation RPC is on the hot path of every command**. `server/src/reconcile_op_heads.rs`:

1. `store.get_op_heads(repo_id)`; if `heads.len() <= 1`, return it (fast path).
2. Otherwise, on a `spawn_blocking` thread (because `load_at_head()` is not `Send`), build jj-lib
   adapters — `ServerBackend`, `ServerOpStore`, `ServerOpHeadsStore`, `ServerIndexStore`,
   `ServerSubmoduleStore` (`server/src/jj_lib_adapters.rs`) — with default `UserSettings` and call
   `repo_loader.load_at_head()`. The comment says exactly what that does:

   > "Calling `load_at_head()` invokes `jj_lib::op_heads_store::resolve_op_heads()`, which identifies
   > divergent operation heads, performs a 3-way view merge, creates a new merge operation, and
   > eventually invokes the `Store` trait … with strict exact CAS verification."

3. `ServerOpHeadsStore::update_op_heads` maps to `update_op_heads_compare_and_swap(repo_id,
   expected_exact_heads = old_ids, new_id)` — atomically replacing the *whole set* only if it is
   unchanged (`server/src/jj_lib_adapters.rs`, `server/src/store/*`).
4. If the CAS loses (another client or another reconciler moved the heads), retry: `MAX_RETRIES = 3`,
   `BASE_BACKOFF_MS = 25`, sleep `(25 << attempt) + rand(0..15)` ms; the comment notes the jitter is
   "to desynchronize concurrent reconciliation attempts on the same repo". After 3 failures:
   `"Failed to reconcile op heads for repo {repo_id}: {e}"` as `Status::internal`.
5. On total failure the heads are left **untouched** — asserted by
   `test_reconcile_repo_op_heads_fails_after_exhausting_retries_on_missing_operation`.

**What the merge produces.** A normal jj operation whose `parents` are the divergent heads and whose
`view_id` points at the 3-way-merged view. Its description is jj-lib's own string:

```
reconcile divergent operations
```

This is asserted twice in `server/src/reconcile_op_heads.rs`'s own test —
`assert_eq!(server_op.metadata.description, "reconcile divergent operations")` — and the same string
appears in jj 0.46's own test snapshots (`jj-upstream/cli/tests/test_converge_command.rs`). The test
also asserts the merged view keeps **both** branches' bookmarks (`branch-a` and `branch-b`) and that
parent set == `{op_a, op_b}`.

**Therefore**: in the cloud, `jj op log` on any client shows a linear-looking history with an extra
node `reconcile divergent operations`, inserted by the server, that has two parents. Nothing is
rewritten; no operation is dropped; both clients' work is in one DAG.

### 4.3 Bookmarks

Concurrent bookmark moves are **not** resolved by discarding a side, because `RefTarget` is
`Merge<Option<CommitId>>` on the wire (`common/proto/op_store.proto`, `ref_target_*` in
`common/src/conversions/op_store.rs`). jj's 3-way ref merge inside the view merge produces a
**conflicted bookmark** — several `adds` terms — which the user resolves with `jj bookmark set
<name> -r <rev>`. This is stock jj semantics applied to a view the server merged; nothing
cloud-specific. A tutorial demo can force it by appending two heads each moving `main`.

### 4.4 Working-copy pointers: silently merged, by wall clock

`wc_commit_ids` maps each workspace name to **one** commit and the proto has no `Merge` for it, so the
view merge cannot represent a disagreement. The in-repo design analysis is explicit
(`docs/design/op-log-scope-decision.md` §5.2):

> "When two views disagree about a `wc_commit_ids` entry, `merge_wc_commit` keeps `self_id` unless one
> side is absent or a trivial merge applies (`lib/src/repo.rs:1650-1676`). 'Self' is the view being
> merged into: reconciliation orders divergent heads by end time and merges each later one into the
> earliest, so the earliest head's value is kept (`lib/src/repo.rs:883`, `lib/src/op_heads_store.rs:154`).
> No conflict object is created and no user is asked. The winner is determined by operation end times,
> not by which machine is local."

Same claim in `docs/design/design-notes.md` §6 ("A contested pointer is resolved silently … the
tie-break is wall-clock end time").

**User-visible consequence**: if two clients share a `repo_id` *and* a workspace name (both default to
`default` — `cli/src/commands/init.rs` `--workspace-name` default), one of them can have its pointer
moved out from under it. Stock jj then reports a stale working copy when that client next runs
(`"The working copy is stale (not updated since operation {})."` — `jj-upstream/cli/src/command_error.rs:277`,
quoted as the reference behaviour in `docs/design/design-notes.md` §6), and the repair is
`jj workspace update-stale`. The design work's rule is to give each machine a distinct workspace name
(`docs/design/requirements.md` **RQ-3-7**: "A workspace is named for the node that owns it, so two nodes
cannot name the same workspace"); **nothing in the code enforces this** — it is a convention the user
must follow with `jj cc init --workspace-name <machine>`.

### 4.5 Change-id rewrites, rebasing, "healing": none

- No rewriting of any kind: `operations` and `views` rows are immutable inserts; ids are content hashes
  (`server/src/hash_utils.rs`); the CAS only replaces *op head pointers*, never data.
- No auto-rebase, no auto-`converge`, no conflict resolution on the client. The client's only
  automatic action is the reconciliation RPC. jj 0.46's `jj converge` exists upstream
  (`jj-upstream/cli/tests/test_converge_command.rs`) but the cloud adds nothing of the kind.
- If two clients amend the same change concurrently, both commits (same `change_id`, different
  `commit_id`) exist in the graph and both are reachable from the merge operation's view `head_ids`.
  The merge does not pick one; the user sees two visible heads and `jj log` shows both. That is stock
  jj divergence semantics, and it is why divergent change ids are not a cloud-specific problem here.
- Grotesque corner: `update_op_heads` with empty `old_ids` is the "append" branch and skips the stale
  check entirely (`server/src/store/memorystore.rs`, `if ids_to_remove.is_empty() { … push … }`), so a
  client that believes it has no heads can always add one. `import-git` uses that.

### 4.6 Exact user-visible strings gathered from source

| Where | String |
|---|---|
| jj-lib merge op description (appears in `jj op log`) | `reconcile divergent operations` |
| root op description served by the cloud | `root()` (`server/src/op_store.rs`, synthesised on demand) |
| op log after `jj cc init` (test assertion) | `add workspace 'default'root()` (`cli/tests/test_op_log_command.rs`) |
| Git-importer op description | `Imported from Git repository` (user `git-importer`, hostname `localhost`, timestamps `0`) |
| server log line per RPC | `Reconcile op heads for repo: {}`, `Get op heads for repo: {}`, `Reading operation: {} for repo: {}`, `Writing operation for repo: {}` |
| missing object read | `operation should have been present in cloud database: {} in repo: {}`; `view should have been present in cloud database: {} in repo: {}` |
| unregistered namespace | `repository should have been registered before {action}: {repo_id}`; `project should have been registered before {action}: {project_id}` |
| merge-commit restriction | `The Commit Cloud backend does not support creating merge commits with the root commit as one of the parents.` (`server/src/backend.rs` and `lib/src/cc_backend.rs`) |
| unimplemented | `Not implemented yet` (symlinks) |
| client daemon fallback | `Warning: failed to start daemon ({e}), falling back to direct gRPC` |

Note the absence: stock jj prints `Concurrent modification detected, resolving automatically.` when a
load finds divergent heads (`jj-upstream/cli/tests/test_log_command.rs:923`). **That message should not
appear in a cloud repo**, because `CommitCloudOpHeadsStore::get_op_heads` collapses the heads via the
server *before* jj-lib sees them. The divergence is instead visible as the
`reconcile divergent operations` commit in `jj op log`. That contrast is a good "aha" for the chapter.

---

## 5. Commands

### 5.1 The three `jj cc` subcommands (complete list; there is no fourth)

**`jj cc init`** — clap doc: *"Initialize a remote Commit Cloud repository and local working copy"*
(`cli/src/main.rs`, struct in `cli/src/commands/init.rs`).

| Flag | Default | Meaning (from help text) |
|---|---|---|
| `--server <URL>` | required | `Remote gRPC server URL (e.g. http://localhost:8080)` |
| `--project-id <ID>` | required | `Project ID (owns shared commit/tree/file storage)` |
| `--repo-id <ID>` | none → server generates a UUID | `Optional Repository ID (owns operation log; generates a new UUID if omitted)` |
| `--create` | off | `Explicitly create a new remote repository if it does not exist yet` — **ignored**: the function body begins `let _ = args.create;`, and the code comment says `//TODO: Add server side guard for repository creation with --create`. Registration is unconditional. |
| `--workspace-name <NAME>` | `default` | `Workspace name (defaults to "default")` |
| `--working-copy-type <TYPE>` | `commit_cloud` | `Working copy type ("commit_cloud" or "local")`; invalid values give `Unsupported working copy type: '{other}' (expected 'commit_cloud' or 'local')` |
| positional `<DESTINATION>` | `.` | `Destination directory for the local workspace` |

Behaviour: `commit_cloud` → `RegisterRepository` RPC → write `config.toml` → `Workspace::init_with_factories`
with all five factories; then prints `Initialized remote Commit Cloud repository`. Server-side, an
existing `repo_id` in the same project is **returned as-is** (`server/src/backend.rs`, "Repository '{}' is
already registered under project '{}', not '{}'" is the error for a *different* project), so reusing
`--repo-id` is how a second machine attaches to an existing op log.

**`jj cc import-git`** — *"Import an existing Git repository into Commit Cloud"* (`cli/src/commands/import_git.rs`).

| Flag | Meaning |
|---|---|
| `--git-dir <PATH>` | `Path to the existing .git directory (or project root containing .git)` |
| `--project-id <ID>` | `Target Project ID in Commit Cloud (owns shared commit/tree/file storage)` |
| `--repo-id <ID>` | `Target Repository ID in Commit Cloud (owns operation log)` — must already exist |
| `--server <URL>` | `Remote Commit Cloud server URL (e.g. http://localhost:8080)` |

Prints `Opening Git repository at {:?} for Target Project ID '{}' / Repo ID '{}'...`, then on success
`✅ Git repository imported successfully!`, `Cloud Repository ID: {}`, and the next-step hint
`jj cc init --server {} --project-id {} --repo-id {} .`. One-way; it uploads blobs with
`CONCURRENT_BLOB_UPLOADS: usize = 32`, writes the root commit, then publishes one operation
(`publish_op_head`) that inherits the existing head's view, adds the imported head ids, sets bookmark
`main`, and chains `parents = old_op_head_ids`.

**`jj cc daemon`** — *"Configure Commit Cloud daemon settings"* (`cli/src/commands/daemon.rs`). Three
mutually exclusive flags: `--enable`, `--disable`, `--status` (conflicts declared in clap). They only
edit `use_daemon` in `config.toml` and print:

```
Commit Cloud daemon mode enabled.
Commit Cloud daemon mode disabled (using direct gRPC).
Commit Cloud Daemon Status:
  Enabled: {}
  Server URL: {}
  Repo ID: {}
  Custom Socket: {}        # only when set
```

### 5.2 What is *absent* from the CLI, and why that is the point

There is **no** `jj cc sync`, `push`, `pull`, `clone`, `status`, `log`, or `resolve`. A grep of
`cli/src` for `"cloud"` / `CloudCommands` finds nothing but the `Cc` variant. This is not an
omission — with a remote-only op store there is nothing to sync: every read of the op log *is* the
download, and every command that mutates state *is* the upload. The tutorial should say this
explicitly, because it is the sharpest contrast with `jj git push`/`fetch`.

### 5.3 The stock commands that become "cloud" commands

Everything (`log`, `new`, `describe`, `op log`, `op show`, `undo`, `sparse`, `workspace add|list|forget`,
`util gc`, `file`, `diff`, `edit`). Two caveats:

- **`jj op show <prefix>` / prefix resolution is broken**: `CommitCloudOpStore::resolve_operation_id_prefix`
  returns `SingleMatch` only for the root operation and `NoMatch` otherwise, with the comment
  "TODO: Implement server RPC to resolve short operation ID prefixes for commands like `jj op show <prefix>`".
  Full operation ids work; short prefixes do not. `jj op log` itself only needs what it reads directly.
- **`jj util gc` cannot prune**: `OpStore::gc` is `Ok(())` (see §2.5).
- `jj workspace forget` / `workspace list` work against the cloud `wc_commit_ids` and the
  `workspaces` table (tests `test_workspace_forget_cli`, `test_workspace_forget_nonexistent_cli_warning`).

---

## 6. Workflow

### 6.1 The documented single-machine loop (`docs/workflow.md`)

Four numbered sections, quoted in condensed form:

1. **"Setup Aliases & Start the Server"** — aliases `sjjs` (server), `sjj` (the cloud `jj`), `sjjvfs`
   (VFS daemon `jjfsd`, from a sibling project); then `sjjs --port 8080 --store-type sqlite` or the
   Spanner form.
2. **"Initialize a Commit Cloud Workspace"** —
   ```bash
   mkdir -p /tmp/vfs_demo && cd /tmp/vfs_demo
   sjj cc init --server http://localhost:8080 --project-id <PROJECT_ID>
   ```
3. **"Sparse Checkout & VFS Integration"** — `sjj sparse set --clear`, mount with
   `sjjvfs /tmp/vfs_mount /tmp/vfs_demo`, browse `cat /tmp/vfs_mount/commits/<commit_id>/file.txt`
   and `cat /tmp/vfs_mount/workspaces/default/file.txt`, then `sjj sparse set --add file.txt` to
   materialise a path. (The VFS binary lives in `jj-vfs-poc`, a separate repo — onboarding
   `08-current-limitations-and-next-steps.md` §3, and `testutils/src/lib.rs::find_jjfsd_bin`
   looks for it externally.)
4. **"Import an Existing Git Repository"** — the `jj cc import-git` invocation shown in §5.1.

### 6.2 Multi-user / multi-machine workflows the code actually supports

Three distinct shapes, and the tutorial should distinguish them because they have different op-log
consequences:

**(i) One project, several repos (isolated histories, shared content).** Each client runs
`jj cc init --project-id shared-proj --repo-id repo-client-N`. Each gets its own op log; commits,
trees and blobs are shared. `cli/tests/test_project_repo_split.rs` demonstrates the full loop: client 1
describes a commit; client 2's `jj log` does **not** contain it; client 2 can nevertheless
`jj show <client-1-commit-id>` (because the index pulls project commits) and `jj new <id>`, at which
point the commit becomes reachable in client 2's own history; `jj undo` in client 1 does not touch
client 2. The test's comments are the clearest statement of the model:
"Because they share project_id … CommitCloudIndexStore automatically indexes commits in the shared
project CAS so client 2 can directly inspect and check out client 1's commit".

**(ii) One repo, several workspaces (the true op-log-sync case).** Both clients pass the *same*
`--repo-id`, so they read and write one op log and one view. This is the only configuration where
`jj op log` is identical on two machines and where `jj undo` on one machine can revert the other's
operation. The code supports it by construction (§3.8, §4.2) but **no test in the checkouts exercises
two `jj cc init` calls with the same `--repo-id`** (grep: every `--repo-id` in `cli/tests/` is
distinct per client). Each client should pass a distinct `--workspace-name` to avoid the silent
`wc_commit_ids` collision of §4.4. The onboarding's own data-model diagram sketches this shape:

```
repo "repo-1"
    ├── operation_log
    ├── view_v1
    ├── op_heads
    ├── workspace "default" (user: alice)
    └── workspace "cloud-build" (user: ci)
```
(`jj-commit-cloud-onboarding/02-architecture-overview.md`, "Data model: project, repo, workspace")

**(iii) Many machines as transient checkouts (the intended product story).** The onboarding's framing
(`01-what-is-commit-cloud.md`, "The problem"): "moving work between laptop, workstation, and cloud
container is clunky", "Setup time: cloning a 100k-file repo is slow", "Disk usage: every developer
stores redundant copies of the same blobs". With a remote store, "cloning" degenerates into
`jj cc init --repo-id <existing>` plus a sparse checkout (§6.1 step 3) — no object transfer. The
`workspaces` table is what lets one machine ask "where is the other checkout of this repo and does it
have unsnapshotted changes" (`WorkspaceService::ListWorkspaces`, `CheckWorkingCopyChanges`).

### 6.3 What the onboarding guide says about *using* it

`jj-commit-cloud-onboarding/06-interactive-tutorials.md` holds the hands-on exercises; the quick start
in `00-index.md` is:

```
1. Build: cargo build
2. Start server: ./target/debug/jj-cc-server --port 8080 --store-type sqlite
3. Init workspace: ./target/debug/jj cc init --server http://localhost:8080 --project-id demo --create
4. Run commands: ./target/debug/jj log, ./target/debug/jj new, etc.
```

Caveat: the onboarding repeatedly refers to `../jj-commit-cloud-poc` and to branch `srachaba-docs@origin`,
and its protocol chapter names RPCs that do not exist in this checkout (`ReadOpHeads`,
`UpdateOpHeadsAppendNewRemoveOld`, `UpdateOpHeadsCompareAndSwap`) and a config file
`.jj/commit_cloud.toml` that the code does not use (it is `.jj/repo/store/config.toml`). Treat the
onboarding as orientation, the source as truth.

---

## 7. Limits & requirements

### 7.1 Server setup

- Build the workspace (`cargo build`), run `jj-cc-server` with a `--store-type`, then `jj cc init`
  against it. SQLite needs nothing; Spanner needs a database path and the `google-cloud-spanner` crate;
  Cloud Run is the only supplied deployment artefact (a `Dockerfile`, no Terraform/Kubernetes —
  onboarding `08-current-limitations-and-next-steps.md` §6).
- SQLite default path `$HOME/.jj-cc-server/commit_cloud.db`; the parent directory is created for you
  (with explicit error strings; see `server/src/main.rs` tests).
- **A repo is bound to its server URL and to this binary's storage-name strings.** If the server URL or
  the store moves, `config.toml` must be edited or the workspace re-initialised; there is no discovery.

### 7.2 Versioning and compatibility — the single biggest practical constraint

**The checkout pins jj 0.43.0, not 0.46.0.**

- `lib/Cargo.toml`, `cli/Cargo.toml`, `server/Cargo.toml`: `jj-lib = "0.43.0"`; `cli/Cargo.toml` also
  `jj-cli = "0.43.0"`; `Cargo.lock` resolves `jj-cli 0.43.0`, `jj-lib 0.43.0`.
- The custom binary is therefore **`jj` 0.43.0 plus this extension** — it cannot be dropped into a
  0.46.0 install, and it does not read a 0.46.0 repo (different `repo` format/version stamp).
- The API pin is not cosmetic. The cloud's view conversion targets the 0.43 shape
  `git_head: RefTarget` (`common/src/conversions/op_store.rs::view_from_proto`), whereas jj 0.46.0's
  `View` has `git_heads: BTreeMap<WorkspaceNameBuf, RefTarget>` (`jj-upstream/core/src/op_store.rs`,
  `pub struct View`). Porting to 0.46 means regenerating the conversions, not just bumping a version.
- The `docs/design/` layer verifies its jj claims against **0.46.0** ("Verified against jj-lib 0.46.0 at
  `/home/bogdan/work/google-jj/jj-upstream`" — `docs/design/design-notes.md` §6), and the developer
  helper scripts point at jj 0.45.1 and 0.41.0 (`docs/design/.dev-shell-bin/jj-dev` →
  `jujutsu-0.45.1-unstable-…`, `jj-stable` → `jujutsu-0.41.0`). So three versions are in play in the
  repo: code 0.43.0, design analysis 0.46.0, dev shell 0.41/0.45. **For a 0.46.0 tutorial, say plainly
  that the extension is a 0.43.0-era reference implementation and that its traits moved.**
- Wire compatibility is unversioned: no `protocol_version` field, no capability negotiation, no
  version check on either side. Upgrading the client and the server together is assumed.
- Operation ids are 16 bytes and view ids 16 bytes *by construction in this code*
  (`common/src/lib.rs`), versus jj's own 64-byte ids — so a cloud repo's `jj op log` ids are not
  interchangeable with any local jj repo's ids.

### 7.3 Known limitations, with sources

| Limitation | Evidence |
|---|---|
| No auth, no TLS, no ACLs, no identity verification | `server/src/main.rs` (no interceptor); onboarding `04-network-protocol.md`; `07-decision-log.md` §12; `08-current-limitations-and-next-steps.md` §1 |
| No offline mode / no write queue | §3.6 above; onboarding `08…` §4 |
| Blobs inline in DB rows; `WriteFile` unary → large/binary files hit gRPC message limits | `common/proto/backend.proto` TODO ("support uploading large files (>4MB) without hitting gRPC message size limits"); `server/src/backend.rs` TODO; onboarding `08…` §2 |
| Symlinks unimplemented | `server/src/backend.rs` `read_symlink`/`write_symlink` → `unimplemented("Not implemented yet")` |
| Tags and Git refs are not synced (silent loss) | §2.4 |
| Working-copy pointer collisions are silent; needs distinct workspace names | §4.4; `docs/design/requirements.md` RQ-3-7 |
| No short op-id resolution; `jj util gc` cannot prune | `lib/src/cc_op_store.rs` (`resolve_operation_id_prefix`, `gc`) |
| Op log grows without bound, one full view per snapshot | `docs/design/op-log-scope-decision.md` §4.3 (cell F) estimates 10^3–10^4 bytes per view, "tens to a few hundred megabytes of view data per active workspace per day"; §4.4 |
| Server-side reconciliation runs on every repo load when heads diverge, via `spawn_blocking` + `pollster::block_on`, creating fresh jj-lib adapters per attempt | `server/src/reconcile_op_heads.rs` (and its own TODO: "optimize shared jj-lib adapter trait construction") |
| Read amplification: every `get_index_at_op` calls `ListProjectCommits` and walks the whole project | `lib/src/cc_index_store.rs` |
| Spanner `update_op_heads` is read-then-write across two transactions (check, then `write_only_transaction`) — no single-transaction CAS, unlike the SQLite path | `server/src/store/spannerstore.rs` `update_op_heads_append_new_remove_old` vs `sqlitestore.rs` (`TransactionBehavior::Immediate`) |
| SQLite serialises all access behind one mutex | `server/src/store/sqlitestore.rs` (`Arc<Mutex<Connection>>`) |
| No protocol versioning | §7.2 |
| Merge commits with the root commit as a parent are rejected | `server/src/backend.rs`, `lib/src/cc_backend.rs` |
| VFS/sparse story depends on an out-of-tree binary (`jjfsd`) | `docs/workflow.md` §3; onboarding `08…` §3 |
| Daemon has no cache and `--idle-timeout` is inert | §3.3 |

### 7.4 What the in-repo design docs say about this design (important framing)

`docs/design/` is a *future* design effort, not documentation of the code. It is still the best
available statement of the trade-offs the tutorial will want to name:

- `op-log-scope-decision.md` names the current behaviour **cell F** — "every operation from every
  machine, each with a complete view" — and lists its properties: "every operation id resolves
  everywhere; `jj undo` can revert an operation performed elsewhere; every snapshot's commit is
  available with its refs; `jj op log` is identical on all machines", at the cost of "proportional to
  the aggregate rate of *snapshotting*", with "concurrent operations must be merged on receipt" and
  "jj's merge path moves from recovery to the hot path". Its §4.3 marks F as "the largest, and larger
  than the transport suggests".
- `observable-change-log.md` argues the opposite direction: "Keep jj's operation log **exactly as jj
  intends it: local, and never transmitted.** Add a second, commit-cloud-specific log — a log of
  _observable change_ — and propagate only that." Status line: "**proposal for discussion.** Nothing
  here is ratified".
- `requirements.md` RQ-4-3 carries the open question directly: "**(Open (OQ-10):** whether the
  operation log belongs in the commit cloud at all. With a git backend it never leaves the machine;
  the rest of these requirements assume it is shared.)"

So the honest one-liner for the tutorial: **the PoC is the working demonstration that jj's op log *can*
be synchronised — by moving it to a server and letting jj-lib's own reconciliation run there — and the
same team's design work is currently arguing about whether that is the right thing to do.**

---

## 8. Synthesis for the capstone chapter (six claims that survive scrutiny)

1. **The operation log really is synchronised, wholesale.** Every operation of every client of a
   `repo_id` lives in one server table; `jj op log` is identical on all of them (§2.3, §2.5).
2. **It is not replicated — it is relocated.** There is no local op log on the client; the storage
   traits are RPCs. That is why there is no `push`/`pull`/`merge` command and no upload protocol (§2.6).
3. **Divergence is handled by jj's own 3-way view merge, executed server-side, producing a normal
   operation named `reconcile divergent operations` with the divergent heads as parents** (§4.2).
4. **The merge is protected by an exact-set CAS on op heads, retried 3× with jittered exponential
   backoff, and it runs on the path of every repository load** (§4.2, §3.8).
5. **The view is not fully replicated**: tags, `git_refs` and `git_head(s)` are dropped on the wire, and
   `wc_commit_ids` has no conflict representation, so working-copy pointer conflicts resolve silently by
   operation end time (§2.4, §4.4).
6. **It is a 0.43.0-era proof of concept** — no auth, no offline mode, unpruned log, unbounded view
   growth — with a design layer that now questions the whole approach (§1.3, §7).

---

## Gaps & uncertainties

1. **"jujutsu-sync" is not a name found in either checkout.** The brief's (a.k.a.) could not be
   confirmed; the project calls itself "jj Commit Cloud" / `jj-commit-cloud`. If the tutorial uses that
   name, it is inventing it.
2. **No proof that two machines can join one op log.** The code path exists (`RegisterRepository`
   returns an existing `repo_id`; `config.toml` may carry any `repo_id`) but **no test in either
   checkout performs two `jj cc init` calls with the same `--repo-id`**, and `docs/workflow.md` never
   shows it. The §6.2(ii) workflow is therefore inferred from code, not demonstrated.
3. **Which jj the extension "targets" is ambiguous.** Code pins 0.43.0; `docs/design/design-notes.md`
   says "Verified against jj-lib 0.46.0"; `docs/design/.dev-shell-bin/` points at 0.45.1 and 0.41.0.
   The repo contains no compatibility statement, and the `git` history in this checkout (a detached
   HEAD carrying mostly `docs(design)` commits) does not show when or whether a 0.46 port was attempted.
4. **Maturity cannot be dated precisely.** No releases, no tags, no CI, no CHANGELOG. `README.md` has no
   badges (so "README badges" in the brief has no answer beyond "none"), and `docs/contributing.md`
   dates the closed-to-PRs window as "June-September 2026" while commits continue into November 2026.
5. **The Google-internal relationship is inferential.** No file names an internal system. The evidence
   is sponsorship ("intern project for one intern sponsored by Google"), Apache headers, Google Cloud
   deployment, Cloud Spanner as "Google's production storage choice", two code comments about Google
   practice, and the `2026 Deliverables.md` contract framing. Whether this reimplements, mirrors, or is
   unrelated to Google's internal Commit Cloud is **not stated anywhere I could read**.
6. **`merge_wc_commit` specifics are second-hand.** The precise tie-break (earliest head's value kept,
   ordered by end time) comes from `docs/design/op-log-scope-decision.md` §5.2 and
   `docs/design/design-notes.md` §6, which cite `lib/src/repo.rs:1650-1676` and
   `lib/src/op_heads_store.rs:154` **of jj-lib 0.43/0.46 upstream, not of this checkout**. Those
   upstream files are not in either checkout, and the two design docs were verified against different
   versions (0.46 vs 0.43), so the exact line numbers may not agree with the pinned 0.43.0. I did not
   run jj or build anything to confirm runtime behaviour.
7. **Worst-case behaviour of the retry loop is unmeasured.** `MAX_RETRIES = 3` on top of a
   `spawn_blocking` + `load_at_head()` per attempt: under sustained contention the RPC can return
   `Internal` and the user's command fails. No test measures merge throughput, and
   `docs/design/design-notes.md` §8 lists "merge rate per 1k operations" as a metric still to be
   defined.
8. **Retention is undecided, not merely unimplemented.** `docs/design/op-log-scope-decision.md` §4.5
   and §6.3 (I1) leave retention open; there is no code either way, so a tutorial claim such as "the
   log is kept forever" is true *of this code today* but not a stated policy.
9. **Blob-size and large-repo limits are unquantified.** The only numbers anywhere are the 4 MB gRPC
   hint in `common/proto/backend.proto`'s TODO and the per-view size estimate in
   `docs/design/op-log-scope-decision.md` §4.3 (explicitly "Estimate from one measurement, not a
   benchmark").
10. **The onboarding repo is partly stale** relative to the code (RPC names, `commit_cloud.toml`,
    branch names, `../jj-commit-cloud-poc` paths). Where it conflicts with source I have followed
    the source and said so; a tutorial should not quote it as authoritative.
