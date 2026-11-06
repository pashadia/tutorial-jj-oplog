# R5 — Version delta for op-log-adjacent behavior, jj 0.41.0 → 0.46.0

**What this is.** A source-pinned extraction of every CHANGELOG entry in the *released*
sections 0.42.0 … 0.46.0 that touches the operation log, op commands, snapshots /
working-copy auto-update / stale working copies, workspaces, git import/export/fetch/push,
colocated repos, concurrency & locking, index-vs-op interaction, and op-log display. Each
entry carries a one-line tutorial-impact note. A second section records empirically verified
side-by-side output differences between the system `jj` 0.41.0 and the official 0.46.0 binary.

**Ask.** Use this as the "what changed between 0.41 and 0.46" appendix for the op-log
tutorial. Nothing here needs a decision; if you ignore it, the tutorial will keep 0.41-era
screenshots for `jj undo`, `jj workspace list`, `jj op log -p` and `jj git import`, all of
which changed visibly.

**Method.**
- Source of truth: `git -C jj-upstream show v0.46.0:CHANGELOG.md` (verified identical to the
  working-tree copy for the released sections). Version headers and dates from that file:
  0.46.0 `2026-10-07`, 0.45.1 `2026-09-03`, 0.45.0 `2026-09-02`, 0.44.0 `2026-08-05`,
  0.43.0 `2026-07-01`, 0.42.0 `2026-06-04`, baseline 0.41.0 `2026-05-06`.
- **The `[Unreleased]` section at the top of the working-tree CHANGELOG is post-0.46.0 and is
  excluded entirely** (it was empty except headings at the time of writing, but the unit of
  scope is the released sections only).
- 0.45.1 is included for completeness; it is a packaging/signing-only patch with no
  op-log surface (see below).
- Empirics: system `jj` 0.41.0 vs `tutorial-oplog/tools/jj` (0.46.0-7d38231), each in its own
  `mktemp`-style scratch repo under `/tmp/vdtest`, driven by the same command script, with
  user config pinned via `JJ_CONFIG`. All commit/change/op hashes are elided as `<ID>`; the
  exact snippet shapes are preserved.

---

## 0.46.0 — 2026-10-07

### Op-log core

> **Breaking changes**
> * `jj undo` and `jj redo` now refuse to undo/redo an operation that was performed in another
>   workspace. Use `--allow-cross-workspace` to undo/redo it anyway.

> **Fixed bugs**
> * `jj undo` of `jj workspace forget` now correctly preserves the workspace's recorded path.
>   Previously the path metadata was lost, leaving the workspace in a broken state after undo.
>   [#9991](https://github.com/jj-vcs/jj/issues/9991)

> **Fixed bugs**
> * `at_operation()` can now be used with operations that are not ancestors of the current
>   operation (e.g. sibling operations created by concurrent commands). Previously, evaluating
>   such expressions failed if they resolved to commits missing from the current operation's
>   index.

**Tutorial impact.**
- **Cross-workspace undo guard is the single biggest scripting change.** Any lesson that says
  "`jj undo` always undoes the last operation" is now wrong in multi-workspace repos: 0.41
  silently undid an operation made in another workspace; 0.46 errors with a `Hint:` and exits
  without doing anything. Show `--allow-cross-workspace` and the `jj op revert` alternative
  (that is what the hint recommends).
- The undo-of-`workspace forget` fix is a *positive* delta: on 0.41 the workspace's root path
  is unrecoverable after undo (`<Error: Workspace has no recorded path>`, see E7), so a lesson
  demonstrating "undo restores the workspace" must use 0.46 to look correct.
- `at_operation()` sibling-op support matters for any lesson that inspects *concurrent* op
  heads, e.g. `jj log -r 'at_operation(<sibling-op>, @)'`. On 0.41 this can fail with a
  missing-commits/index error; on 0.46 it evaluates.

### Workspaces / colocation (all of which write ops)

> **Release highlights**
> * Jujutsu can now colocate workspaces besides the default one by creating Git worktrees.
>   Use `jj workspace add --[no-]colocate` and the setting `git.colocate` to control this.

> **Breaking changes**
> * The minimum supported `git` command version is now 2.42.0, up from 2.41.0.
>   `jj workspace add` uses `git worktree add --orphan`, which was added in 2.42.0.

> **Breaking changes**
> * `jj workspace list`/`root` no longer omit unreachable paths. All recorded paths are now
>   shown, with warnings displayed in `jj workspace root`.

> **New features**
> * `jj workspace add` supports `--colocate`/`--no-colocate` flags to control whether a Git
>   worktree is created alongside the workspace. The default colocates when the current
>   workspace is colocated and the `git.colocate` config is `true`. `jj workspace forget`
>   removes the corresponding Git worktree when one exists.

> **New features**
> * `jj git colocation status`/`enable`/`disable` now work on child workspaces. `status`
>   correctly reports colocation state and includes the workspace name. `enable` creates a Git
>   worktree and `disable` removes it, allowing colocation to be toggled after workspace
>   creation.

> **New features**
> * `jj workspace remove` removes a workspace and its directory from disk. The working-copy
>   state is snapshotted into a commit before removal.

> **Fixed bugs**
> * `jj workspace list` templates are now labeled with `workspace name`, `workspace root`, etc.

**Tutorial impact.**
- `jj workspace add` now *creates a Git worktree by default when the current workspace is
  colocated* (the default for `jj git init` repos). A lesson that adds a workspace to show
  "one op, two workspaces" will, on 0.46, also mutate `.git/worktrees/` and print an extra
  status line (`Created Git worktree for the new workspace.`, see E9). Use
  `--no-colocate` if the lesson wants the old, pure-jj shape.
- `jj workspace forget` is no longer side-effect-free on disk in colocated repos: it removes
  the Git worktree (`Removed Git worktree for "<path>".`) — the op log still shows only
  `forget workspace <name>`, so the filesystem effect is invisible from the op log.
- `jj workspace remove` is a **new op-producing command in 0.46** and is the command the
  tutorial should prefer over `forget` when it wants "op + filesystem change". It snapshots
  the workspace's working copy first, so `jj workspace remove` can yield *two* ops
  (a `snapshot working copy` from that workspace, then `remove workspace <name>`).
- Template label rename (`workspace_list name` → `workspace_list workspace name`, plus a new
  `workspace root relative` label) breaks any lesson showing `colors.workspace_list …` or
  `--color=debug` output for workspaces (see E5).
- Unreachable workspace paths: `jj workspace root` on a deleted directory is a hard error on
  0.41 and a warning-plus-path on 0.46 (E6).

### Other 0.46 entries that touch op-visible state

> **New features**
> * `jj git push` now supports pushing to multiple remotes at the same time. This can be
>   configured via `git.push` set to a string pattern or array of string patterns, or with the
>   repeatable `--remote` flag, which also accepts string patterns.

> **New features**
> * The default target revisions for `jj git push` can now be configured via
>   `revsets.git-push`.

> **Breaking changes**
> * The `List.get()`, `.first()`, and `.last()` template functions now return `Option<T>`
>   instead of throwing an error on out-of-bounds access.

> **New features**
> * The `json()` template function now supports map literals: `json({'key' => value})`
> * `fill` template function now supports an additional named parameter `break_words` […]
> * Added the `TreeEntry.normal_value()` template method and the `TreeValue` type […]
> * `jj run` now uses the sparse patterns from the workspace it's run from. […]

**Tutorial impact.**
- `--remote` repeatable + `revsets.git-push`: `jj op show <push op>` ref-diff output can now
  contain several remotes at once; lessons should not assume one bookmark/remote per push op.
- The `List` → `Option` change is directly relevant to op-log templates that do
  `self.parents().first()` / `.last()`: on 0.46 they yield `Option` (render/compare as such)
  rather than erroring out-of-bounds. Op-log recipes copied from 0.41 that relied on an
  error for the root op now get `none`-ish behaviour instead.
- `json()` map literals and `normal_value()` are what a "machine-readable op log" lesson
  would use (`jj op log -T 'json({...})'`). They do not exist on 0.41.

---

## 0.45.1 — 2026-09-03

> This release fixes an error that prevented the new jj-core crate from being published.
> * Building without `Cargo.lock` (e.g. `cargo install jj-cli`) works again […]
> * Signatures on commits in SHA-256 Git repositories are now stored under the
>   `gpgsig-sha256` header, as Git does, so Git recognizes them as signed and jj can read them
>   back.

**Tutorial impact.** No op-log surface. Only relevant if a lesson shows signed commits in a
SHA-256 repo (signature header name changed). Safe to omit.

---

## 0.45.0 — 2026-09-02

### Op log / divergence

> **Release highlights**
> * A new `jj converge` command was added to help automatically resolve divergent commits by
>   combining them appropriately.

> **New features**
> * The new `jj converge` command attempts to automatically resolve divergence by creating a
>   new commit that replaces the divergent commits. It applies heuristics to try to
>   automatically come up with a good solution, and falls back to prompting the user if the
>   heuristics are inconclusive. It can also run in non-interactive mode, which aborts if
>   prompting would be needed.

> **New features**
> * Git HEAD state is now tracked per worktree internally. This prepares colocated repositories
>   for support of multiple Git worktrees, where each jj workspace can have its own Git HEAD.
>   Existing repositories are migrated automatically.

> **Fixed bugs**
> * In colocated workspaces, `jj workspace update-stale` now correctly resets the Git HEAD to
>   the parent of the fresh working-copy commit. [#9936](https://github.com/jj-vcs/jj/issues/9936)

**Tutorial impact.**
- `jj converge` **does not exist on 0.41** (confirmed: absent from `jj --help`). It is
  *commit* divergence, not *operation* divergence — the tutorial must not conflate the two.
  There is no corresponding new op command; a converge run appears in the op log as ordinary
  rewrite/abandon-ish ops plus a `converge`-description op.
- Per-worktree Git HEAD: repositories created by 0.41 are migrated **silently** — empirically
  no new operation appears in the op log after opening a 0.41 repo with 0.46 (E11). So a
  lesson that says "opening an old repo adds an op" would be wrong.
- `jj workspace update-stale` in colocated workspaces now also moves Git HEAD; the op is still
  a normal `snapshot working copy`-style op, but the observable side effect (`.git/HEAD`
  pointing at the parent of the new WC commit) differs from 0.41. Only matters if a lesson
  runs `git rev-parse HEAD` next to `jj workspace update-stale`.

### Git import/export (op-log effects, auto-import defaults)

> **Breaking changes**
> * `jj git import` in non-colocated repositories no longer imports commits from a detached
>   Git HEAD branch.

> **Fixed bugs**
> * In colocated repos, an external `git add` after a `jj` command no longer produces a tree
>   with duplicate entries (`git fsck: duplicateEntries`). `jj` was leaving a stale cache-tree
>   behind in `.git/index`. Repositories already corrupted this way are not repaired by the
>   fix.
>   [#9711](https://github.com/jj-vcs/jj/issues/9711)
>   [#8884](https://github.com/jj-vcs/jj/issues/8884)

> **Fixed bugs**
> * [The default `immutable_heads()` set](docs/config.md#set-of-immutable-commits) now includes
>   `untracked_remote_tags()`.

**Tutorial impact.**
- "Detached `git HEAD` commits show up as jj commits" is no longer true in non-colocated
  repos: a lesson that creates a commit with `git commit` in a detached state and then shows
  it in `jj log`/`jj op log` will show nothing on 0.45+.
- The cache-tree fix is the classic "index-vs-op" gotcha: on 0.41–0.44 a colocated
  `jj <cmd> && git add .` could corrupt the Git index/cache-tree. Any lesson that interleaves
  `jj` and `git add` in a colocated repo must be re-recorded on 0.46; corrupted repos are not
  repaired.
- `immutable_heads()` including `untracked_remote_tags()` changes *which* commits jj refuses
  to rewrite — i.e. it changes whether an op is rejected, not the op format.

---

## 0.44.0 — 2026-08-05

### Snapshots / working-copy auto-update / stale working copy

> **Fixed bugs**
> * `jj` now creates a new working-copy revision as soon as the one of the current workspace
>   becomes immutable, as well as during snapshotting. This brings the behavior closer to `jj`
>   0.42 and earlier.

> **Fixed bugs**
> * Fixed Git HEAD mismatch after the working copy became immutable.
>   [#9827](https://github.com/jj-vcs/jj/issues/9827)

> **Fixed bugs**
> * Snapshotting no longer fails if the working copy contains a path whose name isn't valid
>   UTF-8. Such paths can't be tracked, so they are now skipped and reported as a warning
>   instead.
>   [#9774](https://github.com/jj-vcs/jj/issues/9774)

**Tutorial impact.**
- Pair this with the 0.43 entry below: **0.43 alone** created the new WC commit *only* at
  snapshot time, so `jj describe` on an immutable WC left you without a fresh `@` until the
  next command. 0.41, 0.42, and 0.44+ all create it immediately *and* at snapshot time. Net
  0.41 → 0.46 behaviour is unchanged; only a lesson recorded against 0.43 would be off. Say
  this explicitly so readers are not confused by the two contradictory-looking entries.
- Non-UTF-8 paths in the WC now produce a `Warning:` line during snapshot instead of aborting
  the command. A snapshot op is still created; the warning appears before the op is reported.

### Git import/export defaults in colocated repos

> **Fixed bugs**
> * `jj git import` and `export` in colocated workspaces are now disabled by default. These
>   commands usually do nothing, but they had a race condition.

> **Fixed bugs**
> * Git temporary files are now cleaned up more reliably in the presence of signals (e.g.
>   `Ctrl-C`). This should reduce the rate of "Could not acquire lock for index file" errors.
>   ([#7530](https://github.com/jj-vcs/jj/issues/7530))

**Tutorial impact.**
- **Directly tutorial-visible.** `jj git import` in a colocated workspace prints
  `Nothing changed.` on 0.41 and `No import needed in colocated workspaces.` on 0.46; export
  likewise. The escape hatch is `--ignore-working-copy` (documented in 0.46 help only), which
  does not exist as a documented workaround on 0.41. See E2.
- The lock-file fix means any lesson screenshotting "Could not acquire lock for index file"
  during concurrent jj/git use should be labelled as pre-0.44 noise.

### Op-log templates / workspace display

> **Breaking changes**
> * The `WorkspaceRef.root()` and `RepoPath.absolute()` template functions now return
>   `Option<FsPath>` and `FsPath` respectively, instead of `String`. The `path` keyword in
>   `jj config list` templates now returns `Option<FsPath>`.

> **New features**
> * `jj workspace list` now shows workspace roots by default. The output can be customized
>   with `templates.workspace_list` or `-T`, and `WorkspaceRef.root()` returns an optional
>   `FsPath` value.
>   [#9713](https://github.com/jj-vcs/jj/pull/9713),
>   [#9826](https://github.com/jj-vcs/jj/pull/9826)

> **New features**
> * New `try(expr, fallback...)` template function to suppress runtime errors.

> **New features**
> * Added `builtin_log()` revset alias for the built-in default `jj log` revset.
>   `revsets.log` now defaults to `builtin_log()`, so custom log revsets can reuse the
>   built-in default instead of copying its full expression.

**Tutorial impact.**
- `jj workspace list` output gains a root column (`default: . <change> <commit> <desc>`), so
  every pre-0.44 screenshot of that command is stale (E5).
- A `-T` template using `root` stays valid but its type changed: `root ++ ""`-style
  concatenation and `root.absolute()` differ; on 0.46 an unrecorded path yields an unset
  `Option` rather than an error. Same for `RepoPath.absolute()` returning `FsPath`.
- `try(expr, fallback)` is the only way to make an op-log template robust across the root op
  or missing fields on 0.44+; it does not exist on 0.41.

### Broader 0.44 changes worth a footnote

> **Breaking changes**
> * `jj git fetch` now fetches tags the same way it fetches bookmarks. Tags are fetched as
>   `<name>@<remote>`, and these remote tags are automatically tracked by local tags of the
>   same name. Running `jj git fetch` in an existing repository will re-fetch all tags to
>   initialize the tracking state.
>   Git's `tagOpt` is no longer respected. To disable tag fetching, set
>   `remotes.<name>.fetch-tags = '~*'` in the jj configuration.
> * `jj git clone --fetch-tags=all|none|included` is removed in favor of `--tag=PATTERN`.
> * `jj git push --all` now pushes all tags in addition to bookmarks.
> * Passing an argument more than once is no longer an error. The last occurrence wins […]
> * `jj file search` now prints every matched line prefixed by the file path […] Use
>   `--name-only` for the previous behavior. [#9399](https://github.com/jj-vcs/jj/issues/9399)

**Tutorial impact.**
- Fetching tags by default means `jj op show <fetch op>` now shows tag ref changes
  (`<name>@<remote>`), and pushing pushes tracked tags. Op-log lessons about "refs changed by
  this op" must be regenerated — 0.41 fetch ops had no tag refs.
- "Last occurrence wins" for repeated options changed the rendered help: `[aliases: --at-op]`
  became `[alias: --at-op]` (E14). Purely cosmetic, but it appears in every copied help dump.

---

## 0.43.0 — 2026-07-01

### Revset/template removals that hit op-log lessons

> **Breaking changes**
> * The deprecated `git_head()` and `git_refs()` functions have been removed from revsets and
>   templates.
> * Git-like symbols (e.g. `refs/heads/main`) are no longer resolved to revisions. Use the
>   bookmark/tag `<name>` or `<name>@<remote>` syntax instead.
> * The deprecated `ui.revsets-use-glob-by-default` option has been removed.
> * `jj bookmark track`/`untrack` no longer supports `<kind>:<bookmark>@<remote>` patterns.
>   However, the `<bookmark>@<remote>` symbol syntax is still supported.
>   [#9226](https://github.com/jj-vcs/jj/issues/9226)

**Tutorial impact.**
- `git_refs()`/`git_head()` **still work on 0.41 and are gone on 0.46**. Any op-log or
  `--at-op` lesson using them to show "refs as of an operation" must be rewritten to
  `bookmarks()` / `tags()` / `remote_bookmarks()`. This is the most likely hidden breakage in
  material written against 0.41.
- `refs/heads/main` as a revset argument no longer resolves; lessons that pass raw Git ref
  names to `jj op diff --from/--to`-style commands must use `main@origin` etc.

### Working-copy revision timing (see 0.44 for the revert)

> **Fixed bugs**
> * `jj` now creates a new working-copy revision during snapshotting if the working copy was
>   immutable. Previously, the new revision was created immediately after the working copy
>   became immutable.
>   [#7751](https://github.com/jj-vcs/jj/issues/7751)
>   [#9338](https://github.com/jj-vcs/jj/issues/9338)

**Tutorial impact.** This is the 0.43-only regression that 0.44 reverted. Documented here so
the two entries are read as a pair; do **not** describe 0.46 as differing from 0.41 on this.

### Fetch/rewrite and op-log evolution

> **New features**
> * `jj git fetch` now rebases the descendants of revisions that were rewritten based on their
>   change IDs. Previously, when multiple bookmarked revisions existed in a stack, those
>   rewritten revisions and their descendants wouldn't always be rebased. Note that immutable
>   descendants will not be rebased.

> **New features**
> * `jj config gc` will delete configuration of deleted/moved repos from
>   `~/.config/jj/repos` folder.
>   [#9362](https://github.com/jj-vcs/jj/issues/9362)

> **New features**
> * `jj show` now supports `--reversed` flag.
> * Add a `forks()` revset function that yields all commits with more than 1 child.
> * `colors` config now supports crossed-out text styling with `{ crossed-out = true }`.

**Tutorial impact.**
- A fetch op can now rewrite (and rebase descendants of) more commits than on 0.41, so
  `jj op show <fetch>` diff hunks differ. Any lesson counting "how many commits this fetch
  rewrote" is version-sensitive.
- `jj config gc` cleans the per-repo config directory keyed by repo path — worth mentioning
  next to workspace deletion, since forgotten workspaces leave entries behind.

---

## 0.42.0 — 2026-06-04

### Op log / evolution history

> **Deprecations**
> * `jj evolog` no longer supports legacy commit predecessors recorded in `jj` < 0.30.

> **New features**
> * `jj git fetch` now generates evolution history based on change IDs. If change IDs are
>   preserved by the remote, local descendant revisions will be rebased onto the rewritten
>   parents.

> **Fixed bugs**
> * The `builtin_log_redacted` template now also redacts workspace names.

**Tutorial impact.**
- `jj evolog` on 0.46 refuses/does-not-show predecessors recorded by pre-0.30 jj. Only
  relevant if the tutorial teaches reading `evolog` output from very old repos; note it as a
  data-compatibility floor.
- Change-ID-based fetch evolution means the *evolution* (evolog) of commits across a fetch
  looks like a rewrite rather than "abandoned here, new there" — a lesson that inspects
  `jj evolog` for a fetched commit's history must be recorded on 0.42+.
- `builtin_log_redacted` (used when `ui.log-synthetic-elided-nodes`/redaction lessons come up)
  now hides workspace names too, so op-log screenshots with redaction differ.

### Piped/redirected diff rendering — the big display change

> **Fixed bugs**
> * Color-words diffs are now shown as separate before and after lines when color output is
>   disabled, making piped or redirected diffs readable.
>   [#5894](https://github.com/jj-vcs/jj/issues/5894)

**Tutorial impact.**
- **This changes every captured `jj op log -p` / `jj op show` / `jj evolog -p` snippet in
  documentation**, because those commands default to color-words diffs and docs capture
  non-TTY output. 0.41 renders one interleaved line; 0.46 renders a before line and an after
  line (see E3 for the exact shapes). If a lesson explains "the `-p` output of an op shows a
  mixed line", that explanation is 0.41-only and now looks like a typo.

### Removed options/config relevant to op-adjacent workflows

> **Breaking changes**
> * The following deprecated command options have been removed:
>   - `jj commit --reset-author`/`--author`
>   - `jj describe --no-edit`/`--edit`/`--reset-author`/`--author`
>   - `jj git push --allow-new`
>   - `jj metaedit --update-committer-timestamp`
> * The following deprecated config options have been removed:
>   - `git.auto-local-bookmark`
>   - `git.push-new-bookmarks`

> **New features**
> * `jj show` now accepts multiple revisions, showing all of them one after the other,
>   behaving closer to `git show`.
> * Added `jj util backend name` command that prints the commit backend being used in the
>   current repo.
> * Added `edit-invocation-mode` config option for diff editors […]
> * Shell completions now surface descriptions for custom aliases […]
> * `jj git remote add` now reports an error instead of panicking when the remote name is
>   empty or contains whitespace. [#9099](https://github.com/jj-vcs/jj/issues/9099)
> * `jj bookmark forget` no longer prints `Forgot N local bookmarks.` when no local bookmarks
>   were actually forgotten (e.g. when only an untracked remote bookmark matched).
>   [#9181](https://github.com/jj-vcs/jj/issues/9181)

**Tutorial impact.**
- `git.auto-local-bookmark` / `git.push-new-bookmarks` removal is the op-log-adjacent one:
  lessons that explain *why* a fetch produced a tracking bookmark via those settings must be
  rewritten (`git.auto-local-bookmark`'s successor behaviour is now the only behaviour).
- `jj describe --no-edit`/`--edit` no longer exist, but `jj describe` still writes
  `describe commit <full-hex-commit-id>` ops — the flag removal does not change op text.
- `jj show` accepting multiple revs does *not* extend to `jj op show` (its revision list is a
  number/`--limit`), so do not generalise that entry to op commands.

---

## Did NOT change (0.41 → 0.46) — verified, and useful to state in the tutorial

These are load-bearing for the tutorial's screenshots, so the negative result matters:

| Surface | Status | Evidence |
|---|---|---|
| `templates.op_log` default | `builtin_op_log_compact` in both | E12 |
| `templates.op_log_node` default | byte-identical in both | E12 |
| op-log graph glyphs (`@`, `○`, `│`) and field order | identical | E4 |
| op-log color labels (`--color=debug`) | identical | E10 |
| snapshot op description wording | `snapshot working copy` in both | E4 |
| `add workspace '<name>'` / `create initial working-copy commit in workspace <name>` op text | identical | E4 |
| `describe commit <40-hex>` op text | identical (full commit hex in both) | E4 |
| op-log message wording: `Undid operation:`, `Restored to operation:`, `Reverted operation:`, `Abandoned N operations and reparented M descendant operations.` | identical | E8 |
| `--at-op` / `--at-operation` / `--no-integrate-operation` semantics & help body | identical (only `[alias…]` singular) | E14 |
| `jj op log -p` `-p`/`-d`/`--op-diff` flags | present and identically described in both | E14 |
| `jj op` subcommand set | identical (`abandon diff integrate log restore revert show`) | E15 |
| op-store migration on opening a 0.41 repo with 0.46 | silent, **no new op** | E11 |

Caveat: the *help-text* of `-T` and `--no-graph` did change (0.46 documents
`templates.op_log` and says "Show a flat list of operations instead of a graph"); the
behaviour did not.

---

## Empirical comparison (0.41.0 system jj vs 0.46.0 bundled binary)

Setup used for every case: fresh `jj git init` repo per binary, identical command script,
`JJ_CONFIG` pinned to a minimal file, all ids elided as `<ID>`.

### E1 — `jj undo` across workspaces (0.46.0, breaking)

Two workspaces; an op is created in `extra`; `jj undo` is run from `default`.

```
# 0.41
$ jj undo
Undid operation: <ID> (2026-11-05 14:08:05) describe commit <ID>
Restored to operation: <ID> (2026-11-05 14:08:05) snapshot working copy

# 0.46
$ jj undo
Error: Refusing to undo operation <ID> because it was performed in workspace extra
Hint: Use `--allow-cross-workspace` to undo it anyway, or use `jj op revert` to revert a specific operation

# 0.46 with the new flag
$ jj undo --allow-cross-workspace
Undid operation: <ID> (2026-11-05 14:08:06) describe commit <ID>
Restored to operation: <ID> (2026-11-05 14:08:06) snapshot working copy
```

`jj redo --help` on 0.46 adds the mirrored paragraph ("…refuses to redo an undo-operation
that was performed in another workspace…") plus `--allow-cross-workspace`.

### E2 — `jj git import` / `export` in a colocated workspace (0.44.0)

```
# 0.41
$ jj git import
Nothing changed.

# 0.46
$ jj git import
No import needed in colocated workspaces.

$ jj git export
No export needed in colocated workspaces.
```

0.46 help adds: "By default, this command does nothing in colocated workspaces because the
import happens automatically. Use `--ignore-working-copy` to forcibly import changes."
(0.41 help instead said "There is no need to run this command if you're in colocated
workspace because the import happens automatically there.")

### E3 — `jj op log -p` piped output: color-words layout (0.42.0) — biggest display delta

Repo with one modified line (`hello world foo` → `hello there foo`), `--color=never`:

```
# 0.41
│     Modified regular file a.txt:
│        1    1: hello worldthere foo

# 0.46
│     Modified regular file a.txt:
│        1     : hello world foo
│             1: hello there foo
```

Same command, same repo shape. Anyone who captured op-log patches into a tutorial on 0.41 has
to re-capture.

### E4 — op-log default template, op descriptions, tree glyphs (no change) + description-diff header (changed)

```
# 0.41 ($ jj op log)
@  <ID> user@host default@ now, lasted 2 milliseconds
│  snapshot working copy
│  args: jj status
○  <ID> user@host default@ now, lasted 3 milliseconds
│  new empty commit
│  args: jj new
○  <ID> user@host default@ now, lasted 3 milliseconds
│  snapshot working copy
│  args: jj new
○  <ID> user@host default@ now, lasted 1 millisecond
│  describe commit <40-hex>
│  args: jj describe -m base
○  <ID> user@host now, lasted 2 milliseconds
│  add workspace 'default'
○  000000000000 root()

# 0.46 — identical structure, wording, glyphs and field order
```

But the *description hunk header* inside `-p` output changed (the description is now diffed as
a synthetic file):

```
# 0.41
│     Modified commit description:
│             1: second

# 0.46
│     Modified JJ-COMMIT-DESCRIPTION:
│             1: second
```

Confirmed in both `jj op log -p` and `jj evolog -p` (`Modified commit description:` →
`Modified JJ-COMMIT-DESCRIPTION:`). Not in the CHANGELOG; found by diffing output.

### E5 — `jj workspace list` default output and template labels (0.44.0 / 0.46.0)

```
# 0.41
default: <change> <commit> base
extra: <change> <commit> (empty) (no description set)

# 0.46
default: . <change> <commit> base
extra: ../extra <change> <commit> (empty) (no description set)
```

Template labels (`--color=debug`), 0.41 → 0.46:

```
workspace_list name::default
workspace_list working_copy target change_id …        # 0.41 labels

workspace_list workspace name::default
workspace_list workspace root relative::.             # 0.46 labels
workspace_list workspace working_copy target change_id …
```

Default config value also changed: `templates.workspace_list` is an inline `concat(name, ": ",
…)` template on 0.41 and the alias `'builtin_workspace_list'` on 0.46.

### E6 — unreachable workspace path (0.46.0)

Workspace added, then its directory deleted:

```
# 0.41
$ jj workspace root --name a
Error: Cannot resolve absolute workspace path: /tmp/.../x41a
Caused by: No such file or directory (os error 2)

$ jj workspace list
a: <change> <commit> (empty) (no description set)      # path silently omitted

# 0.46
$ jj workspace root --name a
Warning: Cannot access workspace path: /tmp/.../x46a
/tmp/.../x46a

$ jj workspace list
a: ../x46a <change> <commit> (empty) (no description set)   # path shown anyway
```

### E7 — `jj undo` after `jj workspace forget` (0.46.0 fix, #9991)

After forget-then-undo, rendering `root` for the restored workspace:

```
# 0.41
$ jj workspace list -T 'name ++ " | " ++ root ++ "\n"'
default | /tmp/.../u41
extra | <Error: Workspace has no recorded path: extra>

# 0.46
$ jj workspace list -T 'name ++ " | " ++ root ++ "\n"'
default | /tmp/.../u46
extra | /tmp/.../u46e        # path metadata survived undo
```

Also, on 0.46 `jj workspace forget` in a colocated repo prints
`Removed Git worktree for "<path>".` before the undo line.

### E8 — unchanged op-command messages

```
# both versions
$ jj op restore @-
Restored to operation: <ID> (…) new empty commit
Working copy  (@) now at: <change> <commit> (empty) (no description set)
Parent commit (@-)      : <change> <commit> base
Added 0 files, modified 0 files, removed 1 files

$ jj op revert @-
Reverted operation: <ID> (…) snapshot working copy

$ jj op abandon @-
Abandoned 1 operations and reparented 1 descendant operations.

$ jj op show
<ID> user@host default@ now, lasted 2 milliseconds
snapshot working copy
args: jj status

Changed commits:
○  + <change> <commit> (no description set)
   - <change>/1 <commit> (hidden) (empty) (no description set)

Changed working copy default@:
+ <change> <commit> (no description set)
- <change>/1 <commit> (hidden) (empty) (no description set)
```

Reuse 0.41 captures for these; nothing to re-record.

### E9 — `jj workspace add` in a colocated repo (0.46.0)

```
# 0.41
Created workspace in "../x41a"
Working copy  (@) now at: <change> <commit> (empty) (no description set)

# 0.46
Created Git worktree for the new workspace.
Created workspace in "../x46a"
Working copy  (@) now at: <change> <commit> (empty) (no description set)
```

Op log entries are identical (`add workspace 'a'`, then
`create initial working-copy commit in workspace a`, `args: jj workspace add ../x46a --name a`).
With `--no-colocate` the extra line disappears.

### E10 — op-log color labels (no change)

`jj --color=debug op log --limit 2` diff, after normalising ids/dates:
**no differences**. Label names for op log (including `op_log …`, node labels) are stable
across 0.41 → 0.46.

### E11 — silent per-worktree Git HEAD migration (0.45.0)

Created a repo entirely with 0.41, then opened it with 0.46:

```
# 0.41 op log head
@  <ID> … snapshot working copy   args: jj status

# 0.46, same repo: identical head op id, no migration op, no message
@  <ID> … snapshot working copy   args: jj status
```

### E12 — template defaults

```
$ jj config list --include-defaults | grep '^templates\.'
# both:
templates.op_log = 'builtin_op_log_compact'
templates.op_show = 'builtin_op_log_compact'
# 0.41:
templates.workspace_list = '''
concat(name, ": ", format_commit_summary_with_refs(…), "\n")
'''
# 0.46:
templates.workspace_list = 'builtin_workspace_list'
```

`templates.op_log_node` renders byte-identically on both. `templates.op_log` is *honoured* on
0.41 too (tested with a custom template) — only the help text started documenting it on 0.46.

### E13 — divergent-op integration message (0.46.0)

`cli_util::merge_operations` was factored out and reused by `op integrate`, `op log`,
`op diff`. Message gained a trailing period; confirmed in the vendored tests:

```
# 0.41 (cli/tests/test_concurrent_operations.rs, test_op_integrate_command.rs)
Rebased 1 descendant commits onto commits rewritten by other operation
# 0.46 (same files; cli/src/cli_util.rs:875)
Rebased 1 descendant commits onto commits rewritten by other operation.
```

Same wording otherwise; the message is now also emitted from `op log`/`op diff` paths that
previously merged heads without reporting.

### E14 — help-text deltas (all op commands)

```
- [aliases: --at-op]                                    + [alias: --at-op]
- Don't show the graph, show a flat list of operations  + Show a flat list of operations instead of a graph
- You can specify arbitrary template expressions using  + All 0-argument methods of the [`Operation` type][Operation]
  the [built-in keywords]. …                              are available as keywords in the template expression. …
                                                       + If not specified, this defaults to the `templates.op_log` setting.
```

`--at-op`/`--at-operation`/`--no-integrate-operation` bodies are unchanged.

### E15 — `--no-integrate-operation` reporting (new in 0.46)

```
# 0.41 — one line per invocation
$ jj --no-integrate-operation describe -m one
Operation left uncommitted because --no-integrate-operation was requested: <op-id>

# 0.46 — two lines: the snapshot transaction is reported separately
$ jj --no-integrate-operation describe -m one
Snapshot operation left uncommitted because --no-integrate-operation was requested: <snap-op-id>
Operation left uncommitted because --no-integrate-operation was requested: <op-id>
```

Source: 0.46 has an extra snapshot-transaction report site
(`cli/src/cli_util.rs:2234` "Snapshot operation left uncommitted…") in addition to the
command-transaction one. Any lesson that counts/pastes this output must be updated; it also
makes the "snapshot is its own operation" point much easier to demonstrate on 0.46.

### E16 — `jj git colocation status` (0.46.0)

```
# 0.41
Workspace is currently colocated with Git.
Last imported/exported Git HEAD: <hex>

# 0.46
Workspace 'default' is currently colocated with Git.
Last imported/exported Git HEAD: <hex>
Hint: To disable colocation, run: `jj git colocation disable`
```

This is a nice op-log teaching hook: the "Last imported/exported Git HEAD" line changes when a
`track git HEAD`-ish op is written.

### E17 — misc command-surface deltas seen while comparing

- `converge` is absent from 0.41 `jj --help` (added in 0.45); `run` is likewise absent from 0.41 (added in 0.43).
- `jj show` summary text: "Show commit description and changes in a revision" (0.41) →
  "Show revision metadata and diff" (0.46).
- `jj git fetch --help`: 0.44+ adds `--tag`, and `--tracked` now covers "bookmarks and tags";
  0.46 adds the "commits no longer reachable… will be abandoned" paragraph.
- `jj git push --help`: 0.46 says the default target is configurable via `revsets.git-push`,
  `--all` pushes "all bookmarks and tags" (0.44+), and `--remote` is repeatable.

---

## Gaps & uncertainties

1. **No divergence-healing repro.** I could not create genuinely divergent op heads by
   scripting (`--no-integrate-operation` twice just replaces the single head; restoring
   `.jj/repo` to fake concurrency corrupts the op store and yields
   "Operation log has no heads"). E13 therefore relies on source + vendored test strings, and
   the `op log`/`op diff` side of the new shared `merge_operations` path is *read from code*,
   not observed. If the tutorial shows a divergence-healing transcript, record it live on
   0.46 rather than trusting E13 beyond the period.
2. **0.44 `WorkspaceRef.root()` → `Option<FsPath>`** is verified only via docs/help type
   signatures; I could not construct a workspace with no recorded path (that requires a repo
   written by jj < 0.38), so the "unset Option renders as nothing" behaviour is unverified.
3. **0.43 vs 0.44 immutability timing** is documented from the changelog only. My attempt to
   force it with `revsets.immutable_heads="all()"` did not produce a new WC commit on either
   binary, so the "0.41 == 0.46" conclusion rests on the 0.44 changelog's own words
   ("brings the behavior closer to jj 0.42 and earlier"), which is strong but not observed.
4. **`jj evolog` legacy predecessors (0.42)** — no pre-0.30 repo available to test whether it
   errors or silently omits.
5. **`git.abandon-unreachable-commits`** paragraphs appear in 0.46 `jj git fetch`/`import`
   help but the option predates 0.41 (present in 0.20-era changelog); the help text is a
   documentation addition, not a behaviour change. Flagged so it is not presented as new.
6. **Colors/themes**: I compared `--color=debug` label names, not actual ANSI palette output
   (default color choices can change without label changes). If the tutorial shows colored
   screenshots (`asciinema`), re-record on 0.46.
7. **Windows-specific entries** (colocation pack-file fix, `CREATE_NO_WINDOW` prompt fix,
   file-identity/symlink fix) are quoted nowhere above because the tutorial is presumably
   Unix-oriented; they are in the 0.43/0.45/0.46 sections if needed.
8. I did **not** audit `docs/` prose beyond the two files that changed in the workspace area
   (`docs/working-copy.md`, `docs/tutorial.md`); the 0.46 doc text for `workspace forget` vs
   `workspace remove` (quoted in spirit above) is worth lifting into the tutorial verbatim:
   "`jj workspace remove` … Tracked changes are snapshotted before the directory is removed,
   but ignored files in that directory are deleted. The main workspace cannot be removed."
