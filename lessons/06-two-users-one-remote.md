# Lesson 06 — Two users, one remote: divergence by design

## Theory

### The rule

**The op log never travels.** `git push`/`fetch` move commits and refs;
there is no code path that reads or writes a foreign op log, and no doc
that promises otherwise. Every clone grows its own history of repo
states from its own `root()`.

- `jj git clone` births a fresh log:
  `root()` → `add workspace 'default'` → `add git remote origin` →
  `fetch from git remote into empty repo` → `check out git remote's
  branch: main`.
- `jj git fetch` is **one** op — `fetch from git remote(s) origin`
  (multiple remotes: `origin,upstream`). A fetch with nothing new
  creates **no** op at all (`Nothing changed.`).
- `jj git push` writes `push bookmark ⟨name⟩ to git remote origin`
  (variants: `bookmarks a, b`, `tags …`, `remotes r1, r2`,
  `push all bookmarks/tags to …`). `--change <rev>` auto-creates a
  *tracked* bookmark named `push-<change-id>` — as of 0.46 there is
  no `--allow-new` flag (it was deprecated and removed; pushing new
  bookmarks is just allowed).

### What converges and what never does

**Change IDs travel** — inside the git commit object itself (the
`change-id` header, `git.write-change-id-header = true` by default).
So after user B fetches user A's work, both repos agree on the *same*
change ID and commit ID for it.

**Operation IDs can't travel** — an op's id is the hash of its view
*plus* its metadata (time, user, host, workspace). Two repos that lived
different histories hash differently forever. Empirically: two clones
of one remote, A pushes a bookmark, B fetches it — B's `jj log` shows
A's exact `change_id`+`commit_id`, while the two op logs share **zero**
ops and have unrelated heads. The logs merely *look* similar, because
both were built by the same sequence of commands.

This is divergence **by design**: convergence happens at the
commit/ref level, through the remote; the histories *of the repos*
stay private. Your op log is your own undo history — nobody else's
mistakes can reach into it.

### What `jj undo` after a fetch undoes

The view fields — heads, local bookmarks, tags, remote-tracking
bookmarks, working-copy pointers — **but never `git_refs`/`git_heads`**
(lesson 02: they always come from the *current* view). In a colocated
repo the undo transaction *re-exports* to `.git`, so the git side
rewinds to match; the fetched commits stay in the object store
(unreachable until `jj util gc`); and the next `jj git fetch` brings
the refs right back.

The `import; undo; import` probe makes the boundary visible:

- **colocated**: `jj git import` is a no-op (`No import needed in
  colocated workspaces.` — import/export there is automatic and
  unconditional; there is no `git.auto-import` config in 0.46), and
  after an undo it's still `Nothing changed.` — the undo's export
  already reconciled `.git`.
- **non-colocated, external git repo** (`jj git init --git-repo=…`):
  the second import **does** re-import — a fresh `import git refs` op —
  because the external repo still holds the newer refs that undo just
  rolled out of your view.

(0.46 behavior. Post-0.46 development changed the non-colocated
fetch/undo interplay — check `jj op log` if your jj is newer.)

### Colocated repos: git traffic in your log

In a colocated repo, every jj command auto-imports/exports, so *raw git
activity* appears as ops:

- `git commit` (HEAD detached, the jj-normal state) → next jj command
  prints `Reset the working copy parent to the new Git HEAD.` and the
  op log gains `import git head`.
- `git switch main && git commit` → `import git head` + `import git
  refs`, and if jj's local bookmark had moved independently, `jj log`
  shows `main*` (out of sync) or `main?` (conflicted).
- a fetch interleaved with dirty files / raw git commands produces a
  stack: `import git head` → `snapshot working copy` → `fetch …`.

Undo covers all of it — `git-compatibility.md`: "You can undo the
results of mutating `git` commands using `jj undo` and `jj op restore`.
Inside `jj op log`, changes by `git` will be represented as an
'import git refs' operation."

### Attribution across users

Each repo's log records only *its own* commands — but with full
identity: `operation.username`/`operation.hostname` (or
`$JJ_OP_USERNAME`/`$JJ_OP_HOSTNAME`). Give each "user" its own identity
and the log answers *who pushed, who fetched, when* — per repo.

### When two users touch the same thing

- **Same bookmark, both moved**: the second push is rejected:

  ```text
  Warning: The following references unexpectedly moved on the remote:
    refs/heads/main (reason: stale info)
  Hint: Try fetching from the remote, then make the bookmark point to
  where you want it to be, and push again.
  ```

  Fetching materializes the disagreement as a **conflicted bookmark**
  (`main (conflicted)` with `-`/`+` target lists, `??` in the log).
  Resolve with `jj bookmark set main -r ⟨rev⟩`, then push (`move
  sideways` if needed). Nobody's commits are lost — "unlike in pure
  Git, losing a bookmark pointer does not lead to losing commits."

- **Same change, both amended**: if one side amends a change and the
  other *fetches the amendment* before touching it, the import is a
  **rewrite** — `Updated 1 rewritten commits.`, old version hidden,
  no divergence. But if **both sides amend independently** before
  exchanging, the fetch lands a *second visible head for the same
  change ID*: `jj log` marks both `(divergent)` (rendered
  `change-id/0`, `change-id/1`), as long as you track both sides' bookmarks (a rejected
push never puts the second side on the wire under the same bookmark name).
  Resolve with `jj converge`, which groups revisions by change ID,
  proposes a merged revision (rebasing descendants), and prompts when
  descriptions differ; or pick a side with `jj abandon`.

- **Revset gotcha while doing any of this**: `description("b work")`
  is an *exact full-string* match — a one-line description is really
  `"b work\n"`. Use `description(substring:…)` or `subject("b work")`.

### Untracked remote bookmarks are immutable

A fetched `push-<change>@origin` bookmark is **untracked** until you
`jj bookmark track` it — and untracked remote bookmarks are part of
the default immutable set. `jj edit` on a colleague's fetched change
fails with `Error: Commit … is immutable` until you track it. Track
first, then edit.

## Exercises

The sandbox plays **user A**; a clone in `../colleague` plays **user
B**. The bare remote `../shared-remote.git` was created (with HEAD
aimed at `main`) by `reset-sandbox.sh`.

Start from a clean slate — earlier lessons leave divergent, undescribed
changes that jj refuses to push (`Won't push commit … since it has no
description`):

```console
cd .. && ./reset-sandbox.sh && cd sandbox
```

**6.1** Wire up the two users:

```console
jj git remote add origin ../shared-remote.git
jj git push --bookmark main
jj git clone ../shared-remote.git ../colleague
cd ../colleague
jj config set --repo operation.username colleague
jj config set --repo operation.hostname colleague-box
jj op log                     # a fresh log: root → add workspace → add git remote origin → fetch …
```

(The clone's own ops are attributed to *your real* user: the identity
config above is set after the clone. `colleague@colleague-box` shows up
from the colleague's first later op on.)

**6.2** Exchange work, then compare the two histories:

```console
echo 'colleague work' > b.txt
jj describe -m "colleague feature"
jj git push --change @            # auto-creates tracked bookmark push-<change-id>
cd ../sandbox
jj git fetch
jj log -r 'remote_bookmarks()' --no-graph -T 'change_id.short() ++ " " ++ commit_id.short() ++ " " ++ description.first_line() ++ "\n"'
jj op log -n 3
jj --repository ../colleague op log -n 3   # similar shapes, zero shared ids
```

Find the colleague's change in your log — same change ID and commit ID
on both machines, foreign op ids everywhere.

**6.3** Put a number on "never converges":

```console
comm -12 <(jj op log --no-graph -T 'id ++ "\n"' | sort) \
         <(jj --repository ../colleague op log --no-graph -T 'id ++ "\n"' | sort) | grep -cv '^0*$'
```

(Prints `0`. There is exactly one id both logs share — the all-zeros
*virtual* root op id, the only "operation" both repos synthesize
identically — and `grep -cv '^0*$'` filters it out. Zero real ops in
common.)

**6.4** A bookmark conflict, start to finish — both users move `main`
after the clone:

```console
cd ../sandbox
jj new main -m "A's competing move"  # A's main moves… (build on main, not on the
                                     # undescribed seed @ — jj won't push that)
jj bookmark move main
jj git push --bookmark main          # …and the remote now points at A's tip
cd ../colleague
jj new main -m "B's competing move"  # B moves main independently…
jj bookmark move main
jj git push --bookmark main          # rejected: refs "unexpectedly moved ... (reason: stale info)"
jj git fetch                         # now main (conflicted): - old / + B's tip / + A's tip
jj bookmark list
jj bookmark set main -r @            # pick B's side
jj git push --bookmark main          # "move sideways" — B's history wins the ref
```

After a successful push jj warns that the working-copy commit became
immutable and creates a new empty commit on top — harmless; pushed
commits are trunk-ish.

Back in `sandbox`, `jj git fetch` shows `Abandoned 1 commits that are no
longer reachable` and rebases your `@`: A's competing commit lost the
ref, so it is *hidden* — not deleted. `jj log -r <commit-id>` (the id from the
"Abandoned" line, e.g. `83698cfa`) still finds it (`hidden`; the *change* id
alone gives `doesn't exist`), the colleague still has it, and `jj undo`
brings it back.

**6.5** A divergent change across the wire — both users amend the
same change before exchanging:

```console
cd ../colleague
jj edit 'subject("colleague feature")'      # moves @ back onto that commit
echo 'b more' >> b.txt
jj st && jj describe -m "colleague take"
cd ../sandbox
jj bookmark track 'push-*' --remote origin  # untracked remote bookmarks are immutable;
                                            # track before editing (glob over names)
jj edit 'subject("colleague feature")'
echo 'a more' >> b.txt
jj st && jj describe -m "A take"
cd ../colleague
jj git push --change @                      # B publishes its take under push-<change-id>
cd ../sandbox
jj git push --named a-take=@                # A must use ANOTHER bookmark name: --change @
                                            # would re-use push-<change-id> and be rejected
                                            # (stale info) — nothing would diverge on the wire
cd ../colleague
jj git fetch                                # a-take@origin [new] untracked
jj bookmark track a-take --remote origin    # untracked = immutable; converge only touches
                                            # mutable revisions
jj log -r 'divergent()'                     # two (divergent) tips: <id>/0 and <id>/1
jj log -r 'divergent()' --no-graph -T 'change_id.short() ++ " " ++ description.first_line() ++ "\n"'
jj converge                                 # answer "y" to merge the descriptions (editor opens;
                                            # replace the conflict-marker text with a one-line
                                            # message like "converged take" and save)
```

(Plain `jj log -n 8` shows only one tip until you track `a-take`: the
other tip is an untracked remote bookmark — immutable, and outside the
default log revset. Use `jj log -r 'divergent()'`.)

`jj converge` asks **once** whether to merge the divergent descriptions
(it opens your editor); there is no "pick parents" prompt. The converged
commit comes out as a `(conflict)` here: both takes added `b.txt`
independently, so relative to their common parent it is an add/add
conflict (`b.txt    2-sided conflict`). Resolve with `jj new <id>`,
`jj resolve`, `jj squash`. `--no-interactive` refuses —
`Could not determine which description to use.` — so answer the prompt,
or resolve by hand with `jj abandon`.

**6.6** Undo across the exchange boundary:

```console
cd ../sandbox
jj git fetch                       # needs something new on the remote — after 6.5 it has
                                   # the colleague's take; otherwise "Nothing changed."
jj undo                            # undoes YOUR fetch: push-<change-id>@origin rewinds, .git rewinds
jj bookmark list
jj git fetch                       # …and the refs come straight back
                                   # (push-<id> may show "(conflicted)" in this flow: both of
                                   # you rewrote it. Expected; not part of the exercise.)
jj git import                      # No import needed in colocated workspaces.
                                   # (--ignore-working-copy would force one: "Nothing changed.")
```

## Verify

```console
./check.sh 06
```
