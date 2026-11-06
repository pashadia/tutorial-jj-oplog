# t3 test report: lessons 05, 06, 07 (jj 0.46.0, executed literally)

Method: throwaway copy of the tutorial in /tmp (deleted afterwards), pinned `tools/jj`, isolated HOME/JJ_CONFIG,
`./reset-sandbox.sh` before each lesson. Every command run as written; placeholders (`<some-commit>`) filled in by hand.
The shell does not persist between my calls, so `$BASE` etc. were recomputed; that is not a lesson issue.

## Verdicts

| Lesson | check.sh | Literal run | Verdict |
|---|---|---|---|
| 05 | PASS (7/7) | all steps behave as described; 1 wording error (5.7), 1 unreproducible theory claim | PASS with minor fixes |
| 06 | PASS (8/8) | **6.4 and 6.5 do NOT work as written** (A's push rejected for "no description"; A's `--change @` push rejected as stale, so no cross-wire divergence). check.sh is blind to this (6.4/6.5 are `true` checks) | FAIL until fixed (fixes verified below) |
| 07 | PASS (5/5) | all steps behave; 7.4 error text differs | PASS with minor fix |

## Lesson 05

| Step | Result | Notes |
|---|---|---|
| 5.1 fork via `--at-op` x2 | PASS | Two marker files; `jj st` prints `Concurrent modification detected, resolving automatically.`; `op log -n 5` shows `reconcile divergent operations` with two parents. `Warning: Failed to update Git HEAD ref` appeared on the 2nd `--at-op` publish, as the lesson says (Caused by: `Expected reference content <sha>`). |
| 5.2 three forks | PASS | One `reconcile divergent operations` op, `parents=` 3 ids. Git HEAD warning printed on forks 2 and 3. |
| 5.3 detached op | PASS | `DET` captured correctly (`tail -1 | grep -oE '[0-9a-f]{12,}'`). `jj op integrate` prints the quoted message. Log: reconcile op (`args: jj op integrate <DET>`) with detached op beside the "meanwhile" op, as described. Note: integrate does NOT print "Concurrent modification detected". |
| 5.4 look without healing | PASS | `jj op log --at-op=@` -> `Error: The "@" expression resolved to more than one operation` + `Hint: Try specifying one of the operations by ID: A, B` (exact). `--at-op <head>` shows one side. Plain `jj op log` heals. |
| 5.5 bookmark conflict | PASS | `main??` in log; `bookmark list` shows `main (conflicted): - old / + new / @git: new` and the Hint, exactly as quoted. `Warning: Failed to export some bookmarks: main@git: Deleted ref had been modified in Git` appears (at the `bookmark delete`, not at reconcile time). Op descriptions: `point bookmark main to commit …` and `delete bookmark main` (check.sh greps the latter). |
| 5.6 second-class | PASS | `jj undo`: `Error: Cannot undo a merge operation` + `Hint: Consider using `jj op restore` instead`; `jj op revert @`: `Error: Cannot revert a merge operation`; `jj op restore @-`: `resolved to more than one operation` + ids hint; `jj op restore "$BASE"` works (`Restored to operation: …`), `main` no longer conflicted. |
| 5.7 real race | DEVIATION (wording) | Race is nondeterministic but yields a divergent change as claimed (I got 4 tips). The lesson says tips look like `zzzzzzzz/N`; real output is `<change-id>/N` (e.g. `ywvwumru/1 … (divergent)`); `zzzzzzzz` is the root change id. |

Other theory claims checked and confirmed: `--ignore-working-copy` still reconciles; `jj op show @` on a merge op prints header with no diff; `jj op log -d` likewise.

Theory claim NOT reproduced ("The sibling working copy" section): after `jj --no-integrate-operation new -m X` (clean wc, dirty wc, and a snapshot variant, 4 attempts) the next `jj st`/`jj new` just worked, no `Internal error: … sibling of the working copy's operation`. In 0.46 the working copy state appears not to be advanced by a non-integrated op.

### Corrections, lesson 05
- 5.7 prose: replace "(several `zzzzzzzz/N` tips)" with "(several `<change-id>/N` tips, e.g. `ywvwumru/0`, `/1`, `/2`)".
- Theory "The sibling working copy": either drop it, or soften to "can occur (e.g. when the working copy's recorded operation was abandoned or forked off, see lesson 04's table); I could not trigger it with `--no-integrate-operation new` on 0.46", and move the example error to lesson 04 context.

## Lesson 06

Fresh sandbox, steps run in order.

| Step | Result | Notes |
|---|---|---|
| 6.1 wire up | PASS | `push --bookmark main` prints `bookmark: main [add to <sha>]`. Clone auto-tracks `main@origin` and sets `trunk()`. Colleague op log: root, `add workspace 'default'`, `add git remote origin`, `fetch from git remote into empty repo`, `check out git remote's branch: main`: matches. These clone ops are attributed `bogdan@nixos` (identity config is set after the clone), so `colleague@colleague-box` only appears after the colleague's first later op (check.sh's identity check passes only after 6.2). |
| 6.2 exchange work | PASS | `b.txt` + `describe` + `push --change @` -> `Creating bookmark push-<change-id>` and `bookmark: push-<id> [add to <sha>]`. Fetch: `push-<id>@origin [new] untracked`. `remote_bookmarks()` prints the colleague's change (same change+commit id) plus `Add farewell`. Op shapes similar, ids disjoint. Colleague log shows `colleague@colleague-box`. |
| 6.3 count | PASS (clarify) | Prints `0` (the single shared all-zeros root line is excluded by `grep -cv '^0*$'`). The lesson's parenthetical "One shared line" is confusing next to a printed 0. |
| 6.4 bookmark conflict | **DEVIATION (breaks)** | See below. |
| 6.5 divergent across wire | **DEVIATION (breaks)** | See below. |
| 6.6 undo across boundary | PASS (minor) | `jj git fetch` -> `push-<id>@origin [updated] tracked`; `jj undo` -> `Undid operation … fetch from git remote(s) origin`; `bookmark list` shows the remote bookmark rewound; I verified separately with `git for-each-ref` that `.git/refs/remotes/origin/<new>` disappears on undo and `jj git fetch` brings it back. `jj git import` -> `No import needed in colocated workspaces.` and `jj git import --ignore-working-copy` -> `Nothing changed.` (both exact, the remark is correct). |

### 6.4 failures (literal run)
1. A side, `jj new -m "A's competing move"` builds on the sandbox's current `@`, which is the empty, undescribed commit from the seed. `jj bookmark move main` works, then
   `jj git push --bookmark main` -> `Error: Won't push commit <sha> since it has no description` / `Hint: Rejected commit: … (empty) (no description set)`. A never pushes.
2. Consequently B's push succeeds (`[move forward from … to …]`), and there is no `stale info` rejection, no conflict. Nothing in the rest of 6.4 matches the text.

Verified fix: A uses `jj new main -m …` (symmetry with B). Then A's push succeeds, B's push is rejected with exactly the quoted
`Warning: The following references unexpectedly moved on the remote: refs/heads/main (reason: stale info)` + Hint (plus a final `Error: Failed to push some bookmarks`),
`jj git fetch` -> `bookmark: main@origin [updated] tracked`, and `bookmark list` shows `main (conflicted): - old / + B's tip / + A's tip` plus `@git (behind by 1 commits)` and `@origin (behind by 1 commits)` lines, and the Hint.
`jj bookmark set main -r @` works (the rejected push left B's `@` on its own tip), and the push says `[move sideways from <A> to <B>]`.

Additional deviations in 6.4:
- After A's successful push, jj warns `Warning: The working-copy commit became immutable; a new commit has been created on top of it.` (A's `@` now is a new empty commit on top of A's tip). Same for B's final push. Harmless but unmentioned; it also means B's `@` after the final push is a new empty commit above `main`.
- The closing parenthetical "(Back in sandbox, `jj git fetch` shows the update; your local commits didn't go anywhere.)" is wrong. Real output: `Abandoned 1 commits that are no longer reachable: <A's tip> main@git | (empty) A's competing move`, `Rebased 1 descendant commits.`, and A's `@` is rebased onto `Add farewell`. A's competing commit is hidden (still addressable by id: `jj log -r <id>` shows `(hidden)`; `jj undo` brings it back; the colleague still sees it).

### 6.5 failures (literal run, after 6.4)
1. `jj edit 'subject("colleague feature")'  # your @ already is that commit` is false after 6.4 (the colleague's `@` is a fresh empty commit). jj prints `Working copy (@) now at: … push-<id> | colleague feature` (it moves). On both sides `jj edit` works because `jj bookmark track 'push-*' --remote origin` printed `Started tracking 1 remote bookmarks.` as the lesson says.
2. `jj st && jj describe` fine.
3. B's `jj git push --change @` succeeds (`[move sideways from … to …]`: the colleague's bookmark `push-<id>` is tracked).
4. **A's `jj git push --change @` is rejected**: A's `push-<id>` points at A's amended commit but the remote's moved: `Warning: … refs/heads/push-<id> (reason: stale info)` + `Error: Failed to push some bookmarks`. So the premise "A publishes its take" fails, no divergence reaches the colleague.
5. Even if it had gone through, `jj log -n 8` on the colleague only shows one tip: the other one is an untracked remote bookmark, hence immutable and outside the default log revset.
6. `jj converge` (no args) then says `No revisions were found to be divergent with each other in revsets.converge: mutable() & divergent()` (immutable side), exit 0.
7. `jj converge`'s prompts: the only prompt is `There are divergent descriptions. … Do you want to merge them now? (Yn)` followed by the editor; there is no "pick parents" prompt. `--no-interactive` text `Could not determine which description to use.` + `Error: Could not converge change` confirmed. The result is a `(conflict)` commit: `b.txt    2-sided conflict` (converge merges relative to the common parent, which has no `b.txt`, so two different `b.txt` versions are an add/add conflict even if A edits another file). Needs one sentence.

Verified working replacement for 6.5 (tested end to end):

```console
cd ../colleague
jj edit 'subject("colleague feature")'     # moves @ back onto that commit
echo 'b more' >> b.txt
jj st && jj describe -m "colleague take"
cd ../sandbox
jj bookmark track 'push-*' --remote origin  # untracked remote bookmarks are immutable; track before editing
jj edit 'subject("colleague feature")'
echo 'a more' >> b.txt
jj st && jj describe -m "A take"
cd ../colleague
jj git push --change @                      # B publishes its take under push-<change-id>
cd ../sandbox
jj git push --named a-take=@                # A must use ANOTHER bookmark name: --change @ would re-use
                                            # push-<change-id> and be rejected (stale info)
cd ../colleague
jj git fetch                                # a-take@origin [new] untracked
jj bookmark track a-take --remote origin    # untracked = immutable; converge only touches mutable revisions
jj log -r 'divergent()'                     # two (divergent) tips: wrowyksl/0 (a-take) and /1 (push-...)
jj log -r 'divergent()' --no-graph -T 'change_id.short() ++ " " ++ description.first_line() ++ "\n"'
jj converge                                 # answer "y" to merge the descriptions, edit in $EDITOR
```
Then replace the converge note with: "`jj converge` asks once whether to merge the divergent descriptions (it opens your editor); the converged commit is a `(conflict)` here because both takes added `b.txt` independently: resolve with `jj new <id>`, `jj resolve`, `jj squash`. `--no-interactive` refuses (`Could not determine which description to use.`)." Also in the Theory bullet "bookmark goes conflicted too" only holds if both sides use the same bookmark name, which cannot happen through a rejected push; say "if you track both sides' bookmarks".
(Note: if converge is run with `JJ_EDITOR` unset in a non-tty it fails with the editor error; irrelevant for a learner.)

### Other lesson 06 wording fixes
- 6.3: "(Prints `0`: the one shared line, the all-zeros virtual root op id, is what `grep -cv '^0*$'` filters out.)"
- 6.6 comment `# undoes YOUR fetch: main@origin rewinds` -> `push-<change-id>@origin rewinds` (that is what the fetch changed at that point; `main@origin` was already current).
- 6.6 needs the fetch to have something new; it does after 6.5 (colleague's pushed take). If a learner skips 6.5, `jj git fetch` prints `Nothing changed.` and `jj undo` undoes an earlier op. Add: "(needs something new on the remote; after 6.5 it has the colleague's take)".
- 6.1: note op log clone entries are attributed to your real user because `config set` happens after the clone.
- check.sh: 6.4/6.5 are `true`; consider real checks, e.g. `git --git-dir=../shared-remote.git branch | grep -q a-take` and a divergent/`jj --repository ../colleague log -r 'divergent()'` check, so a broken 6.4/6.5 is caught.

## Lesson 07

| Step | Result | Notes |
|---|---|---|
| 7.1 loop + `op log -n 8` | PASS | `Concurrent modification detected…` printed by the following command, alice@laptop and bob@desk ops forked and reconciled. Reconcile ops attributed to whoever loaded next (alice, or my own user for `jj op log`). |
| 7.2 forensics template | PASS | Works as written (`time.end().ago()` renders "now"). |
| 7.3 crash window | PASS | 2 marker files; `jj st` heals, `survivor` and `ghost` both visible. Extra check: adding an ancestor op id as a head marker is healed by the next load without creating any op (marker count back to 1, same head). Git HEAD warning printed once on the `--at-op` publish (not mentioned in 7.3; same cosmetic as lesson 05). |
| 7.4 working-copy race | DEVIATION (minor) | Ran the two commands concurrently 3 times. Observed: `Error: The working copy is stale (not updated since operation …)` + `jj workspace update-stale` hint, and interleaved checkouts; `Error: Concurrent working copy operation. Try again.` never appeared. `jj workspace update-stale` recovers (`Updated working copy to fresh commit …`). Repo untouched. |
| 7.5 policy | n/a | writing exercise |

Correction 7.4: "Worst case: `Error: The working copy is stale (not updated since operation …)` (or `Concurrent working copy operation. Try again.`) — or interleaved checkouts. … Recover with `jj workspace update-stale`." Also note that `<some-commit>` must be mutable: with a remote/trunk configured (after lesson 06) `jj edit` of `main` fails as immutable.

## Summary of deviations
1. 05: 5.7 `zzzzzzzz/N` is wrong (use `<change-id>/N`).
2. 05 theory: sibling working copy error not reproducible with `--no-integrate-operation` on 0.46.
3. 06 6.4: A's `jj new -m` builds on undescribed `@` -> push refused ("no description"); fix `jj new main -m`.
4. 06 6.4: closing parenthetical false: A's commit is abandoned/hidden on fetch, `@` rebased.
5. 06 6.4: undocumented "working-copy commit became immutable" warning after successful pushes.
6. 06 6.5: "your @ already is that commit" false; A's `push --change @` rejected (stale info); use `--named a-take=@`, track `a-take`, use `jj log -r 'divergent()'`; converge prompt is one "merge descriptions?" question and yields a conflict commit.
7. 06 6.3: output is `0`, parenthetical unclear. 6.6: `main@origin` should be `push-<id>@origin`; needs new remote content.
8. 07 7.4: observed error is "working copy is stale", not "Concurrent working copy operation".
