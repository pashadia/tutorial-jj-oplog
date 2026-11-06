<!--
DRAFT d2 — to be appended to lessons/07-shared-directory.md as 7.6 ... 7.15.
Every quoted message below comes from a real jj 0.46.0 run in throwaway dirs
(op ids / commit ids are from ONE run; yours will differ). Status tags used:
  [documented]  stated in jj's own docs (docs/technical/concurrency.md etc.)
  [source]      read from the v0.46.0 source, not exercised here
  [observed]    seen in these runs; no doc promises it
  [unsupported] nothing in the docs backs it; do not rely on it
Things NOT reproduced are listed at the very end.
Suggested housekeeping (I did not touch the files): add `rm -rf "$here/lab-sync"`
to reset-sandbox.sh's clean-slate line, because the lab below uses ../lab-sync.
-->

## Theory addendum — "Bringing two real op logs together"

Lesson 06 showed that the op log never travels *through git*. This lab asks the
other question: what if you move the files yourself — `cp -a`, `rsync`,
Dropbox? (`docs/technical/concurrency.md` calls this "let rsync … merge them".)

Three facts to hold on to:

1. **A `cp -a` copy shares history.** Two clones (lesson 06) share *zero* ops.
   Two *copies* share everything up to the moment of the copy, then fork — so
   they are two heads of one DAG, which is exactly what lesson 05's
   `reconcile divergent operations` knows how to merge.
2. **An op is only readable if everything it points at is present.** An op
   points at a view; a view points at commits; commits live in the *commit
   store* (git objects), not in `op_store/`. Missing pieces are not skipped —
   they are hard errors, and the error depends on *which* piece is missing.
3. **Order matters, because the head marker is the publish step.** Ship
   objects first, then `op_store/`, then `op_heads/heads/` last — the same
   "make it visible only after what it points to is visible" rule jj itself
   obeys (and the one the docs quote about distributed file systems).

What is safe to union (additive copy)? Tags: [documented] = concurrency.md,
[source] = read in source, [observed] = this lab.

| path under `.jj/repo/` (non-colocated) | what it is | union-safe? |
|---|---|---|
| `op_store/operations/<128 hex>`, `op_store/views/<128 hex>` | content-addressed, immutable, never rewritten | **yes** [source: file name = blake2b of content; see r2 §1.4] |
| `store/git/objects/**` (colocated: `.git/objects/**`) | git object database, content-addressed | **yes, and mandatory** [observed 7.7] |
| `op_heads/heads/<hex>` | empty marker file = "this op is a current head" | additive copy is tolerated; the *only* mutable part of the op log; copy **last** [observed 7.8, 7.11] |
| `store/extra/*` | stacked table of jj-only commit metadata; has its own `heads/` marker | **not needed** [observed: 7.7 recovery did not ship it]; jj re-imports missing entries [source: git_backend.rs "unimported Git commit found"] |
| `index/**` | derived cache | **not needed**, rebuilt [observed 7.13] |
| `store/git/refs/jj/keep/*` | "no-gc" refs that keep commits alive | not needed; jj re-created them for the imported commits [observed 7.7] |
| `workspace_store/index` | one mutable file, read-modify-write | **no** (last writer wins) [source: r3 §4.2d] |
| `.jj/working_copy/*` | per-checkout state: which op/tree this directory is at | **never** copy between machines [unsupported] |
| colocated `.git/HEAD`, `.git/refs/*`, `.git/index` | git's own mutable state | **no** |

Documented vs observed vs unsupported, up front:
- [documented] The docs say rsync/Dropbox/NFS "merge" of clone copies is
  tolerated, "no changes to the repo will be lost", conflicts appear as
  conflicts, the Git backend may corrupt (#2193), and `jj debug reindex` is the
  recovery. They give **no recipe**.
- [observed] Everything numbered below. The additive-rsync recipe works; it is
  *our* recipe, not jj's.
- [unsupported] `rsync --delete`/mirroring, copying `working_copy/`, syncing
  while a jj command runs, and anything on a colocated repo beyond the doc's
  "less resilient" sentence.

## Exercises

**7.6** Two copies of one repo that each take different commands. Use a
throwaway repo (not your sandbox), non-colocated so *everything* lives in
`.jj/`:

```console
rm -rf ../lab-sync; mkdir ../lab-sync; LAB=$(cd ../lab-sync && pwd); cd "$LAB"
jj git init --no-colocate base
(cd base; echo hello > README.md; jj describe -m "base"; jj bookmark create main -r @; jj new -m "scratch")
cp -a base machine-a; cp -a base machine-b
(cd machine-a; export JJ_OP_USERNAME=alice JJ_OP_HOSTNAME=laptop
 echo a > a.txt; jj describe -m "alice's work"; jj bookmark create alice-topic shared -r @)
(cd machine-b; export JJ_OP_USERNAME=bob JJ_OP_HOSTNAME=desk
 echo b > b.txt; jj describe -m "bob's work"; jj bookmark create bob-topic shared -r @)
T1='id.short() ++ " " ++ user ++ "  " ++ description.first_line() ++ "\n"'
jj -R machine-a op log --no-graph -T "$T1"
comm -12 <(jj -R machine-a op log --no-graph -T 'id ++ "\n"' | sort) \
         <(jj -R machine-b op log --no-graph -T 'id ++ "\n"' | sort) | grep -cv '^0*$'
```

Machine A's log (B's is the mirror image) — five old ops plus three new ones:

```text
6b1326dd399e alice@laptop  create bookmark alice-topic, shared pointing to commit e2febb592133578c6dc800d18e8ca8c16236a946
0778381d192a alice@laptop  describe commit 1168d255df0754d1853c2635ff7193429ac862df
0afc0652ac94 alice@laptop  snapshot working copy
c1026a9bd76a carol@ci  new empty commit
4860018be833 carol@ci  create bookmark main pointing to commit d7cb620a6e84bfa3429d489120c5c7f1ce20aebb
1a20dfde9f6b carol@ci  describe commit dbf9733dcfd37e3e9726f85bb3aa06424a69ccf3
59612995dc29 carol@ci  snapshot working copy
83ef66435ef0 carol@ci  add workspace 'default'
000000000000 @
```

(The `carol@ci` ops are whatever identity made the base repo — yours will say
your own user@host.) The `comm` count prints **`5`** — compare lesson 06.3's
`0`. B's head is `5348fd666271`, A's is `6b1326dd399e`. Both machines
rewrote the *same* scratch change and both set the bookmark `shared`: a
guaranteed collision for the merge to chew on.

**7.7** The ops without the commits. Copy A, then ship only B's `op_store/`
and head marker — the "I synced my `.jj/repo/op_store`, why is it broken?"
mistake:

```console
cp -a machine-a try1
rsync -a --ignore-existing machine-b/.jj/repo/op_store/ try1/.jj/repo/op_store/
rsync -a --ignore-existing machine-b/.jj/repo/op_heads/heads/ try1/.jj/repo/op_heads/heads/
cd try1; jj op log -n 1; echo "exit=$?"; ls .jj/repo/op_heads/heads | cut -c1-12
```

```text
Concurrent modification detected, resolving automatically.
Internal error: Failed to load the repo
Caused by:
1: Failed to read index
2: Failed to index commits at operation 5348fd6662716570151afed106ab6c16e175ed4cdf143d7c6ff24784caccd0c002206907dd862f0b64e98431ac1f77c384f0e8c17fa5b44b6539475bc5a4f0c9
3: Object 52816734ad83a8d7919eb579853ebc530f58b5d0 of type commit not found
exit=255
5348fd666271
6b1326dd399e
```

Read it: jj saw two heads and started to heal; healing needs B's view, B's
view names B's commits, and the commit store does not have them. **Nothing
was written**: both markers are still there, A's own history is untouched
(`jj --at-op 6b1326dd399e log -r @` still works and prints `alice's work`).
Recovery is to ship the missing objects — then *any* command heals:

```console
rsync -a --ignore-existing ../machine-b/.jj/repo/store/git/objects/ .jj/repo/store/git/objects/
jj op log -n 4
jj bookmark list
jj log
```

```text
Concurrent modification detected, resolving automatically.
@    27d9e9c4c5a2 alice@laptop default@ now, lasted 5 milliseconds
├─╮  reconcile divergent operations
│ │  args: jj op log -n 4
○ │  6b1326dd399e alice@laptop default@ 10 seconds ago, lasted 1 millisecond
…
alice-topic: yvrttkvz/2 e2febb59 (divergent) alice's work
bob-topic: yvrttkvz/0 52816734 (divergent) bob's work
main: nwonnopv d7cb620a base
shared (conflicted):
  + yvrttkvz/2 e2febb59 (divergent) alice's work
  + yvrttkvz/0 52816734 (divergent) bob's work
Hint: Some bookmarks have conflicts. Use `jj bookmark set <name> -r <rev>` to resolve.
@  yvrttkvz/2 tester@example.com 2026-11-06 10:06:15 alice-topic shared?? e2febb59 (divergent)
│  alice's work
│ ○  yvrttkvz/0 tester@example.com 2026-11-06 10:06:15 bob-topic shared?? 52816734 (divergent)
├─╯  bob's work
○  nwonnopv tester@example.com 2026-11-06 10:06:15 main d7cb620a
│  base
◆  zzzzzzzz root() 00000000
```

That is lesson 05's 3-way view merge, verbatim: the disjoint bookmarks
(`alice-topic`, `bob-topic`) union; the bookmark both sides set becomes
`shared (conflicted)`; the change both sides rewrote becomes `(divergent)`
(`/2` and `/0`). What you *didn't* have to ship: `store/extra/` and `index/`
(both rebuilt on demand), and git's `refs/jj/keep/*` (jj re-created the ones
for B's two commits: `git --git-dir=.jj/repo/store/git for-each-ref` lists
`…/52816734…` and `…/2f8076be…`).

Colocated variant [observed, separate run on the tutorial's colocated
sandbox layout]: same recipe with `.git/objects/` instead of
`store/git/objects/`; same error shape (`Object 34419c5b5b69ad028340cb6bdc3a33b13edb49b7 of type commit not found`
in that run); `.git/HEAD` and `.git/refs` need not be shipped.

**7.8** Partial syncs — what each missing piece looks like. Three more
throwaway copies of A:

```console
cd "$LAB"
# (a) objects + op_store, but NO head marker
cp -a machine-a try2
rsync -a --ignore-existing machine-b/.jj/repo/store/git/objects/ try2/.jj/repo/store/git/objects/
rsync -a --ignore-existing machine-b/.jj/repo/op_store/ try2/.jj/repo/op_store/
ls try2/.jj/repo/op_store/operations | wc -l
jj -R try2 op log --no-graph -T 'user ++ "\n"' | sort | uniq -c
# (b) head marker only
cp -a machine-a try3
rsync -a --ignore-existing machine-b/.jj/repo/op_heads/heads/ try3/.jj/repo/op_heads/heads/
jj -R try3 op log -n 1
```

(a) prints `11` files (5 + 3 + 3), but the log still shows only
`1 @`, `3 alice@laptop`, `5 carol@ci`: the foreign ops are **on disk and
invisible** — no error, no merge. No marker, no head. (This is also what a
Dropbox client looks like halfway through its upload.)

(b) is the nasty one — a marker whose operation file has not arrived:

```text
Internal error: Failed to load an operation
Caused by:
1: Object 5348fd6662716570151afed106ab6c16e175ed4cdf143d7c6ff24784caccd0c002206907dd862f0b64e98431ac1f77c384f0e8c17fa5b44b6539475bc5a4f0c9 of type operation not found
2: Cannot access …/try3/.jj/repo/op_store/operations/5348fd66…
3: No such file or directory (os error 2)
```

**Every** jj command fails on that repo (even `jj st`) until you either
ship the missing file or delete the stray marker:

```console
rm try3/.jj/repo/op_heads/heads/5348fd666271*
jj -R try3 op log -n 1 --no-graph -T 'id.short() ++ " " ++ description.first_line() ++ "\n"'
```

→ `6b1326dd399e create bookmark alice-topic, shared pointing to commit e2feb…`
(the repo is back, minus B's ops; they can be re-added later). A *view* file
missing while its operation is present gives the sibling error — in
my run `…of type view not found` after `Concurrent modification detected,
resolving automatically.` / `Internal error: Failed to load the repo`.
That is why the order is **objects → op_store → heads**: a marker must never
arrive before what it points to.

**7.9** One-way, then back — the sequence that converges. Define the
recipe once (this is *our* recipe [observed], not a jj command):

```console
sync_repo() {   # sync_repo SRC DST — additive; never --delete; heads LAST
  rsync -a --ignore-existing "$1/.jj/repo/store/git/objects/" "$2/.jj/repo/store/git/objects/"
  rsync -a --ignore-existing "$1/.jj/repo/op_store/"          "$2/.jj/repo/op_store/"
  rsync -a --ignore-existing --exclude lock "$1/.jj/repo/op_heads/heads/" "$2/.jj/repo/op_heads/heads/"
}
cp -a machine-a ma2; cp -a machine-b mb2
sync_repo mb2 ma2                              # A pulls B
JJ_OP_USERNAME=alice JJ_OP_HOSTNAME=laptop jj -R ma2 op log -n 2 --no-graph -T "$T1"
sync_repo ma2 mb2                              # A pushes its (now merged) log back
ls mb2/.jj/repo/op_heads/heads | cut -c1-12
JJ_OP_USERNAME=bob JJ_OP_HOSTNAME=desk jj -R mb2 op log -n 2 --no-graph -T "$T1"
ls mb2/.jj/repo/op_heads/heads | cut -c1-12
```

```text
Concurrent modification detected, resolving automatically.
4a8e5be8634a alice@laptop  reconcile divergent operations
6b1326dd399e alice@laptop  create bookmark alice-topic, shared pointing to commit e2febb592133578c6dc800d18e8ca8c16236a946
4a8e5be8634a            <- A's heads after reconcile: one
4a8e5be8634a            <- B's heads after pulling A: two markers...
5348fd666271
Error: The working copy is stale (not updated since operation 5348fd666271).
Hint: Run `jj workspace update-stale` to update it.
See https://docs.jj-vcs.dev/latest/working-copy/#stale-working-copy for more information.
4a8e5be8634a            <- ...healed to one, with NO new operation and no message
```

(The `<-` annotations are mine.) Three things to notice:

- B received A's reconcile op, whose parents include B's own head, so B's old
  marker is a mere *ancestor* — the "interrupted update" case from lesson 03:
  silently pruned, **no new op** [source: r2 §4.2 step 6; observed].
- After that, `comm` between `ma2` and `mb2` finds **12 of 12** real ops in
  common: the two logs are *identical*, ids and all. This is the reverse of 6.3.
- B's checkout is **stale**: the merged view keeps one working-copy commit
  per workspace and, when both sides moved it, keeps the *self* side — the
  head with the earliest end time, here A's [source: `merge_wc_commit`
  comment "we keep the self side", heads sorted by end timestamp; observed
  twice, in 7.9 and in 7.13 where it was B's]. B's files are unharmed on
  disk until you act. Recover (B's `b.txt` leaves the disk; its commit
  `52816734…` "bob's work" is still in the repo — `jj edit` it to get it back):

```console
cd mb2; JJ_OP_USERNAME=bob JJ_OP_HOSTNAME=desk jj workspace update-stale
```

```text
Working copy  (@) now at: yvrttkvz/0 e2febb59 alice-topic shared?? | (divergent) alice's work
Parent commit (@-)      : nwonnopv d7cb620a main | base
Added 1 files, modified 0 files, removed 1 files
Updated working copy to fresh commit e2febb592133
```

**7.10** The wrong way to go both ways at once. Mirror both directions
*before* either machine runs a command, then let each machine touch the repo:

```console
cd "$LAB"; cp -a machine-a pa; cp -a machine-b pb
sync_repo pb pa; sync_repo pa pb
for r in 1 2; do
  JJ_OP_USERNAME=alice JJ_OP_HOSTNAME=laptop jj -R pa --ignore-working-copy op log -n 1 --no-graph -T "$T1"
  JJ_OP_USERNAME=bob   JJ_OP_HOSTNAME=desk   jj -R pb --ignore-working-copy op log -n 1 --no-graph -T "$T1"
  sync_repo pb pa; sync_repo pa pb
  echo "heads: A=$(ls pa/.jj/repo/op_heads/heads | wc -l) B=$(ls pb/.jj/repo/op_heads/heads | wc -l)"
done
```

```text
Concurrent modification detected, resolving automatically.
4934f5bfa73b alice@laptop  reconcile divergent operations
Concurrent modification detected, resolving automatically.
6a03fcd396ce bob@desk  reconcile divergent operations
heads: A=2 B=2
Concurrent modification detected, resolving automatically.
6c5a4d25f7c7 alice@laptop  reconcile divergent operations
Concurrent modification detected, resolving automatically.
51db72cca436 bob@desk  reconcile divergent operations
heads: A=2 B=2
```

Both machines healed the *same* fork, but a reconcile op's id includes its
time and user, so they wrote **two different** merge ops. Syncing them
re-creates a two-head fork — a ping-pong that never ends as long as both
sides act between syncs. It ends the moment one side acts alone:

```console
JJ_OP_USERNAME=alice JJ_OP_HOSTNAME=laptop jj -R pa --ignore-working-copy op log -n 1 --no-graph -T "$T1"
sync_repo pa pb
JJ_OP_USERNAME=bob JJ_OP_HOSTNAME=desk jj -R pb --ignore-working-copy op log -n 1 --no-graph -T "$T1"
```

(`954b185cff31 alice@laptop  reconcile divergent operations` twice, the second
time with no "Concurrent modification" line: B just adopts A's merge op.)
Rule: **pull, run a command, push back** — one writer at a time per sync
round. Nothing is ever lost in the loop (every reconcile has both old heads
as parents); it is only noisy.

**7.11** Stale head markers — leave them or remove them? Re-sync from B
into an already-merged copy of A:

```console
cp -a pa st; ls st/.jj/repo/op_heads/heads | cut -c1-12
sync_repo machine-b st; ls st/.jj/repo/op_heads/heads | cut -c1-12
JJ_OP_USERNAME=alice JJ_OP_HOSTNAME=laptop jj -R st --ignore-working-copy op log -n 2 --no-graph -T "$T1"
ls st/.jj/repo/op_heads/heads | cut -c1-12
```

```text
954b185cff31
5348fd666271
954b185cff31
954b185cff31 alice@laptop  reconcile divergent operations
6c5a4d25f7c7 alice@laptop  reconcile divergent operations
954b185cff31
```

`--ignore-existing` re-adds B's old head marker every sync (A had already
deleted it). Because `5348fd66…` is an ancestor of `954b185c…`, jj
prunes it on the next load — **no new op, no message, top op unchanged**. So:

- *Not removing* stale markers is harmless **as long as their ops are still
  ancestors of your head** [observed]. Cost: one lock-and-prune per sync.
- *Removing* them by hand is also harmless when they are ancestors — but
  removing a **real** head (one that is not yet merged) silently hides that
  branch. Watch:

```console
cp -a machine-a hd; sync_repo machine-b hd; ls hd/.jj/repo/op_heads/heads | cut -c1-12
rm hd/.jj/repo/op_heads/heads/5348fd666271*
jj -R hd --ignore-working-copy bookmark list
jj -R hd op integrate 5348fd666271
jj -R hd --ignore-working-copy bookmark list
```

```text
5348fd666271
6b1326dd399e
alice-topic: yvrttkvz e2febb59 alice's work
main: nwonnopv d7cb620a base
shared: yvrttkvz e2febb59 alice's work
The specified operation has been integrated with other existing operations.
alice-topic: yvrttkvz/2 e2febb59 (divergent) alice's work
bob-topic: yvrttkvz/0 52816734 (divergent) bob's work
main: nwonnopv d7cb620a base
```

B's work vanished from view (no error!), and `jj op integrate <id>`
brought it back — the op objects were never deleted, only un-headed. Policy:
**never hand-delete markers; run one jj command after each sync and let jj
prune.** Hand-deleting is only for the 7.8(b) emergency.

**7.12** The unsafe way, so you recognise it: mirroring with `--delete`.

```console
cp -a machine-a del
for p in store/git/objects op_store op_heads/heads; do rsync -a --delete machine-b/.jj/repo/$p/ del/.jj/repo/$p/; done
JJ_OP_USERNAME=alice JJ_OP_HOSTNAME=laptop jj -R del --ignore-working-copy op log -n 3 --no-graph -T "$T1"
jj -R del --ignore-working-copy bookmark list
cd del; jj st; jj workspace update-stale; jj st; ls; jj log -r 'description(substring:"alice")'
```

```text
5348fd666271 bob@desk  create bookmark bob-topic, shared pointing to commit 52816734ad83a8d7919eb579853ebc530f58b5d0
da6f32a832e4 bob@desk  describe commit 2f8076be565faa67bbe723af4c1912b82194bf1a
11f8dc1f3162 bob@desk  snapshot working copy
bob-topic: yvrttkvz 52816734 bob's work
main: nwonnopv d7cb620a base
shared: yvrttkvz 52816734 bob's work
Error: Could not read working copy's operation.
Hint: Run `jj workspace update-stale` to recover.
See https://docs.jj-vcs.dev/latest/working-copy/#stale-working-copy for more information.

Failed to read working copy's current operation; attempting recovery. Error message from read attempt: Object 6b1326dd399e… of type operation not found
Created and checked out recovery commit 19c7f95aea59
Working copy changes:
A a.txt
D b.txt
Working copy  (@) : xzxusqus b3b3cb1f RECOVERY COMMIT FROM `jj workspace update-stale`
Parent commit (@-): yvrttkvz 52816734 bob-topic shared | bob's work
a.txt
README.md
```

(The last `jj log` prints nothing.) A is now a byte-for-byte clone of B: no
`reconcile`, no conflict, **no trace of alice's ops or commits** — the
objects went too. Only the file `a.txt` (uncommitted on disk) survived,
because jj snapshotted it into a *recovery commit*. No error message warned
about any of this. This is the "lose" in rsync-as-merge; the doc's "no
changes to the repo will be lost" assumes additive copying.

**7.13** Derived state: `index/`, `jj debug reindex`, `jj util gc`.

```console
cp -a ma2 idx; cd idx
ls .jj/repo/index/op_links | wc -l                                   # 11
rm -rf .jj/repo/index/{op_links,segments,changed_paths}; mkdir .jj/repo/index/{op_links,segments,changed_paths}
jj --ignore-working-copy log --no-graph -T 'commit_id.short() ++ "\n"' | wc -l      # 4 (visible commits)
ls .jj/repo/index/op_links | wc -l                                    # 1 (silently rebuilt for the head op)
jj debug reindex
```

→ `Finished indexing 9 commits.` (9 = every commit any op mentions,
including hidden ones; the log showed 4.) So index loss costs time only
[observed]; `index/` never has to travel. `jj util gc` does *not* touch
`index/` (r2 §8.3) nor `op_heads/`.

The gc/abandon interaction is the real trap: additive syncing **undoes
pruning**. A has merged B, resolved the conflict, then pruned history:

```console
cd "$LAB"; cp -a ma2 ab; cd ab
export JJ_OP_USERNAME=alice JJ_OP_HOSTNAME=laptop
jj bookmark set shared -r 'description(substring:"alice")'     # resolve the conflict
ls .jj/repo/op_store/operations | wc -l                         # 13
jj op abandon ..@-
jj util gc --expire now
ls .jj/repo/op_store/operations | wc -l                         # 1
cd ..; sync_repo machine-b ab
ls ab/.jj/repo/op_store/operations | wc -l                      # 9
jj -R ab --ignore-working-copy bookmark list shared
```

```text
Abandoned 12 operations and reparented 1 descendant operations.
shared (conflicted):
  + yvrttkvz/1 52816734 (divergent) bob's work
  + yvrttkvz/0 e2febb59 (divergent) alice's work
Hint: Some bookmarks have conflicts. Use `jj bookmark set <name> -r <rev>` to resolve.
```

B's old head marker is no longer an ancestor of anything in A's trimmed log
(its ancestors were abandoned, and ops are hashed with their parents), so it
is a *real* second head: jj reconciled against a base of `root()`, and the
conflict you already resolved came back, plus a working copy that is stale
again. Rule: **prune only after every machine has caught up, then prune on
all of them, then stop syncing old markers** (or sync only after `rm`-ing
markers your peer no longer has — but see 7.11).

**7.14** Contention in one directory — two real processes [observed], the
laptop-and-desk race of 7.1 with disjoint work so you can count survivors:

```console
cd "$LAB"; cp -a base race; cd race
for who in alice bob; do
  ( export JJ_OP_USERNAME=$who JJ_OP_HOSTNAME=host-$who
    for i in $(seq 1 15); do jj bookmark create $who-$i -r 'root()' >/dev/null 2>>../race-$who.err || echo "FAIL $who $i"; done ) &
done; wait
jj bookmark list | grep -c -E '^(alice|bob)-'                      # 30
ls .jj/repo/op_heads/heads | wc -l                                  # 1
jj op log --no-graph -T 'description.first_line() ++ "\n"' | grep -c reconcile
cat ../race-*.err | grep -c 'Concurrent modification'
```

Result in my run: **no `FAIL`**, `30` bookmarks, `1` head, 14 processes saw
`Concurrent modification detected, resolving automatically.` on stderr
(15 reconcile ops in the log after my final `jj bookmark list` healed one
more). 15 creates each, 30 survivors: the lock-free protocol working as
documented. The number of reconcile ops varies run to run (10 + 4 here, split
by identity).

The one place a process *waits* is the advisory `flock` on
`op_heads/heads/lock`, held only while publishing:

```console
cd "$LAB"; cp -a base lk; cd lk
( flock -x 9; sleep 3 ) 9>.jj/repo/op_heads/heads/lock &
sleep 0.5
t() { local s=$(date +%s%N); "$@" >/dev/null 2>&1; echo "$(( ($(date +%s%N)-s)/1000000 )) ms"; }
t jj log -r @          # 15 ms   — reads take no lock
t jj new -m held       # 2488 ms — waits out the holder, prints nothing
```

No message, no error — contention is invisible unless you run with
`--debug` (look for `Attempting to lock` from `jj_lib::lock::unix`)
[observed; r2 §3.1 is the source].
That lock is *per file-system semantics*: on a share where `flock` is not
honoured across hosts, the 7.14 race still works (that is the whole point of
the add-then-remove head protocol) — it just can't be *simulated* with two
processes on one host, which would always see the lock. I could not
reproduce a genuine cross-host NFS lock failure; [documented] only.

**A "Dropbox" simulation — a sync loop running while two machines work**
[observed, timing-dependent]:

```console
cd "$LAB"; cp -a base s1; cp -a base s2
( while [ ! -e stop ]; do sync_repo s1 s2; sync_repo s2 s1; done ) &
for m in "s1 alice laptop a" "s2 bob desk b"; do set -- $m
  ( cd $1; export JJ_OP_USERNAME=$2 JJ_OP_HOSTNAME=$3
    for i in $(seq 1 12); do jj bookmark create $4$i -r 'root()' >/dev/null 2>>../err-$2.txt || echo "FAIL $2 $i"; done ) &
done
```

Two runs, two outcomes: in one, 10 of bob's 12 commands failed; in the
other, 2 of 24 failed (`FAIL bob 11`, `FAIL bob 12`). The failing message in
both:

```text
Internal error: Failed to load an operation
Caused by:
1: Object 6bf4f4a8…c595abb of type operation not found
2: Cannot access …/s2/.jj/repo/op_store/operations/6bf4f4a8…
3: No such file or directory (os error 2)
```

It is 7.8(b), happening live: the sync loop copied a head marker in the
window between its `op_store/` pass and its `heads/` pass, so a marker
briefly pointed at an op that had not arrived. After a final quiet
`sync_repo s1 s2; sync_repo s2 s1` both machines had identical state (22
bookmarks = 24 requested − the 2 failed commands; every command that
*succeeded* was preserved; 1 head after the next command). So a continuous
sync daemon turns "silent merge" into "transient hard errors" — jj's own
protocol writes the op before the marker, but an external copier cannot see
that ordering. Retry the command, or wait for the next sync pass. [observed;
a real Dropbox client has different timing — **not reproduced**].

**7.15** Two git-remote probes that belong to this lesson: a fetch racing
local commands, and `jj undo` of a push.

*Fetch racing local ops.* A bare remote, a `pusher` clone that keeps
pushing, and your clone `me`. Real fetches over a local path finish in
milliseconds, so first make the remote's pack-building slow (a
git-side `uploadpack.packObjectsHook`, honoured from the *global* config):

```console
printf '#!/bin/sh\nsleep 1.5\nexec "$@"\n' > "$LAB/slowpack.sh"; chmod +x "$LAB/slowpack.sh"
printf '[uploadpack]\n\tpackObjectsHook = %s\n' "$LAB/slowpack.sh" > "$LAB/slow.gitconfig"
git init -q --bare "$LAB/remote.git"; git --git-dir="$LAB/remote.git" symbolic-ref HEAD refs/heads/main
jj git clone "$LAB/remote.git" "$LAB/seed"; (cd "$LAB/seed"; echo s > s.txt; jj describe -m seed; jj bookmark create main -r @; jj git push --bookmark main)
jj git clone "$LAB/remote.git" "$LAB/pusher"; jj git clone "$LAB/remote.git" "$LAB/me"
(cd "$LAB/pusher"; jj new main -m "slow push 3"; jj bookmark create -r @ slow3; jj git push --bookmark slow3)
cd "$LAB/me"
( GIT_CONFIG_GLOBAL="$LAB/slow.gitconfig" jj git fetch ) &   # takes ~1.5 s
sleep 0.4
for i in 1 2; do jj describe -m "during fetch c$i"; done
wait
jj op log -n 6 -T 'id.short() ++ " " ++ description.first_line() ++ "\n"'
```

(`GIT_CONFIG_GLOBAL` goes on the fetch only. Setting the same hook via
`GIT_CONFIG_COUNT/KEY/VALUE` environment variables did **not** slow the fetch
in my test, so I don't use it.) Observed:

```text
FETCH: bookmark: slow3@origin [new] untracked
FETCH took 1538 ms
Concurrent modification detected, resolving automatically.
@    7ee790eed3e1 reconcile divergent operations
├─╮
○ │  2fa35bcf5e8b describe commit 776099c833796d0163b89b103494d72e266976b6
○ │  75ce4e989d23 describe commit 47a574c8e5121ccf57af4c43ffec27bafa8a5a35
│ ○  0972182d56f6 fetch from git remote(s) origin
├─╯
○  6426b1214ddb describe commit d8feb54847ffdbf4afd88f6b003ba4ca573b0976
```

The fetch started from the op before the describes, so it published as a
*sibling*, and the next command merged it. Both describes and the fetched
`slow3@origin` survive; neither command errored, and the fetch itself printed
no warning (the fork is only announced by the *next* command). A first,
un-slowed attempt (25 describes in a loop vs 6 fetches against a pusher
making 8 pushes) produced **no fork at all** — the windows simply didn't
overlap — and all 8 pushed bookmarks arrived: the race exists but is narrow
for fast fetches.

*`jj undo` of a push.* The op log rewinds; the remote does not.

```console
cd "$LAB"; jj git clone remote.git u3; cd u3
jj new main -m "A"; jj bookmark move main --to @; jj git push --bookmark main
git --git-dir=../remote.git rev-parse --short=8 refs/heads/main        # d30ba1fe
jj undo
git --git-dir=../remote.git rev-parse --short=8 refs/heads/main        # still d30ba1fe
jj new main -m "B on top of A"; jj bookmark move main --to @
jj bookmark list -a main
jj git push --bookmark main
```

```text
Warning: Undoing a push operation often leads to conflicted bookmarks.
Hint: To avoid this, run `jj redo` now.
Undid operation: c32ef570d823 (2026-11-06 10:09:14) push bookmark main to git remote origin
…
main: knkoorzy 990f2f0d (empty) B on top of A
  @git: knkoorzy 990f2f0d (empty) B on top of A
  @origin (behind by 2 commits): nxkourqu db73ffb1 (empty) B on top of A
Changes to push to origin:
  bookmark: main [move forward from db73ffb18611 to 990f2f0d1359]
Warning: The following references unexpectedly moved on the remote:
  refs/heads/main (reason: stale info)
Hint: Try fetching from the remote, then make the bookmark point to where you want it to be, and push again.
Error: Failed to push some bookmarks
```

The undo rolled back `main@origin` to what it was *before* the push; the
real remote kept the push (`d30ba1fe`). jj now believes the remote is behind
and tells git "I expect `db73ffb1`" — the remote disagrees, so the push is
rejected as stale (the same rejection as lesson 06.4). Recovery, verified:

```console
jj git fetch      # bookmark: main@origin [updated] tracked
jj git push --bookmark main   # bookmark: main [move forward from d30ba1febf33 to 990f2f0d1359]
```

`git rev-parse` of the remote then shows `990f2f0d`. Two more outcomes seen:
- If you push the **same** commit again right after the undo, the push
  succeeds as a no-op (`bookmark: main [move forward from 5c44e6bd1b51 to
  0cfd22069f14]` while the remote was already at `0cfd2206`).
- The hint's remedy works: `jj undo; jj redo` printed `Restored to operation:
  96ee5c08b243 … push bookmark main to git remote origin` and `main@origin`
  matched `main` again. (Real-world, not shown: if someone *else* moves the
  remote between your undo and your next push, expect the same stale-info
  rejection and, after fetch, a conflicted `main` — as in 6.4.)

## Checkable assertions (for check.sh, lesson 07; all read-only, use `LAB=../lab-sync`)

Hard (deterministic):
1. `$LAB/machine-a` and `$LAB/machine-b` exist; `jj -R $LAB/machine-a op log --no-graph -T 'user ++ "\n"'` contains `alice@laptop`, machine-b's contains `bob@desk`.
2. Shared real ops between the two logs (the `comm … | grep -cv '^0*$'` pipeline) equals 5 *on the fresh pair* — not once try dirs have been healed; check it before 7.7, or compute it as "> 0" for later.
3. `$LAB/try1` has a `reconcile divergent operations` op and `jj -R $LAB/try1 bookmark list` contains `shared (conflicted)`.
4. `$LAB/ma2` and `$LAB/mb2`: `ls .jj/repo/op_heads/heads | wc -l` is 1 in `ma2`; `jj -R … --ignore-working-copy op log -T 'id'` sets are equal (diff empty).
5. `$LAB/del` op log contains no `alice@laptop` user (`--ignore-working-copy op log`).
6. `$LAB/race`: 30 bookmarks matching `^(alice|bob)-`, 1 head marker, `>= 1` reconcile op.
7. `$LAB/hd`: `bookmark list` contains `bob-topic` (after `op integrate`).
8. `$LAB/u3`: `git --git-dir=$LAB/remote.git rev-parse refs/heads/main` equals the commit id of local `main` after the final push; op log contains `undo: restore to operation`.
9. `$LAB/me` (fetch race, only if the student did the slow-hook variant): op log has a `fetch from git remote(s) origin` and `reconcile divergent operations`.

Informational (timing-dependent; use `info` not `maybe`):
10. 7.14 failures / reconcile counts vary; the Dropbox loop may or may not produce `of type operation not found`.
11. 7.15 un-slowed fetch race may or may not fork.

## Not reproduced / caveats

- A genuine cross-host NFS/Dropbox lock failure; real Dropbox/Syncthing timing.
- Hand-written protobuf corruption cases; `jj debug reindex` as a *fix for a corrupted git backend* (#2193) — I only showed it rebuilding a deleted index.
- Whether the earliest-end-time rule for the working-copy pointer holds in every case: confirmed by source comment and two runs (A won when A's op ended first in 7.9; B won in 7.13's resurrection, where B's old op ended earliest), not tested exhaustively.
- Colocated sync was run once (separate earlier run, same error shape, `.git/objects` as the shipped path); the full 7.7–7.13 sequence was run on non-colocated repos only.
- `rsync` is assumed installed; `flock` (util-linux) is Linux-specific — on macOS use the 7.14 race only.
