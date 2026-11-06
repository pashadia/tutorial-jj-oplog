#!/usr/bin/env bash
# check.sh <NN> — verify the sandbox state after an op-log lesson's exercises.
# Re-runnable. Needs jj 0.46.0+ on PATH.
# It changes no commits or bookmarks, and its own queries pass
# --ignore-working-copy, so they write no snapshot ops. (Checks that
# deliberately probe working-copy state, like 'jj st' in lessons 04/05,
# are the exception: those run a normal command.)
set -u

here="$(cd "$(dirname "$0")" && pwd)"
# Require jj 0.46.0+ — the lessons depend on 0.46 behavior.
ver="$(jj --version 2>/dev/null | awk '{print $2}')" || true
base="${ver%%-*}"; major="${base%%.*}"; rest="${base#*.}"; minor="${rest%%.*}"
if [[ -z "${ver:-}" || ! "$major" =~ ^[0-9]+$ || ! "$minor" =~ ^[0-9]+$ ]] \
   || (( major == 0 && minor < 46 )); then
  echo "This tutorial needs jj 0.46.0 or newer; found '${ver:-no jj on PATH}'." >&2
  echo "See https://docs.jj-vcs.dev/latest/install-and-setup/" >&2
  exit 1
fi
sandbox="$here/sandbox"
lesson="${1:-}"

usage() {
  echo "usage: $0 <lesson-number>   e.g. $0 05"
  echo "lessons: 01..08 (see README.md)"
  exit 1
}

[[ "$lesson" =~ ^[0-9]{2}$ ]] || usage
[[ -d "$sandbox" ]] || { echo "No sandbox. Run ./reset-sandbox.sh first."; exit 1; }
cd "$sandbox" || exit 1

PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); echo "  PASS  $1"; }
no()   { FAIL=$((FAIL+1)); echo "  FAIL  $1"; [[ -n "${2:-}" ]] && echo "        → $2"; }
info() { echo "  INFO  $1"; [[ -n "${2:-}" ]] && echo "        → $2"; return 0; }
maybe() { # ok if condition true, otherwise FAIL with hint
  if eval "$2" >/dev/null 2>&1; then ok "$1"; else no "$1" "$3"; fi
}

# ── helpers ────────────────────────────────────────────────────────────────
op_descs() { jj --ignore-working-copy op log --no-graph -T 'description ++ "\n"' 2>/dev/null; }
op_attrs() { jj --ignore-working-copy op log --no-graph -T 'attributes ++ "\n"' 2>/dev/null; }
op_users() { jj --ignore-working-copy op log --no-graph -T 'user ++ "\n"' 2>/dev/null; }
hdr() { echo; echo "Lesson $lesson"; }
# read a lab repo's op log without touching it:  labops <dir-under-tutorial> <template>
labops() { jj --ignore-working-copy -R "$here/$1" op log --no-graph -T "$2" 2>/dev/null; }
lab_exists() { [ -d "$here/$1/.jj" ]; }

seeded()  { jj --ignore-working-copy log -r 'subject("Initial project")' --no-graph -T 'change_id' 2>/dev/null | grep -q . ; }

# ── per-lesson checks ──────────────────────────────────────────────────────
case "$lesson" in

01)
  hdr
  maybe "1.2  a snapshot op created by 'jj st' exists" \
    "op_attrs | grep -q '^args: jj st'" \
    "run a couple of jj st with dirty files first: jj st snapshots the working copy"
  maybe "1.3/1.5  op-log templates and the op grammar were exercised" \
    "jj op show @-- >/dev/null && jj op log -T builtin_op_log_oneline >/dev/null" \
    "run: jj op show @--, jj op show @-2 (expect an error), jj op log -T builtin_op_log_oneline"
  maybe "1.1  the sandbox was born from a git repo (import ops exist)" \
    "op_descs | grep -q 'import git refs' && op_descs | grep -q 'import git head'" \
    "reset-sandbox.sh seeds git history before jj git init --colocate"
  maybe "1.6  an op is attributed to colleague@laptop" \
    "op_users | grep -q 'colleague@laptop'" \
    "JJ_OP_USERNAME=colleague JJ_OP_HOSTNAME=laptop jj op log (with a dirty file so a snapshot op is written)"
  maybe "1    sandbox still sane (seeded history reachable)" \
    "seeded" \
    "reset-sandbox.sh if you went too far"
  ;;

02)
  hdr
  maybe "2.1  an undo op and a redo op exist" \
    "op_descs | grep -q '^undo:' && op_descs | grep -q '^redo:'" \
    "run: jj undo, then jj redo"
  maybe "2.2  a revert op exists" \
    "op_descs | grep -q '^revert operation '" \
    "run: jj op revert @-"
  maybe "2.3  the snapshot safety net: 'precious draft' survived time travel" \
    "grep -q 'precious draft' src/greet.py" \
    "re-do 2.3: snapshot the draft, op restore to an older op, op restore @- to come back"
  maybe "2.3  a restore op exists" \
    "op_descs | grep -q '^restore to operation '" \
    "run: jj op restore <older-op-id>"
  maybe "2.5  a commit described 'keep me' exists" \
    "jj log -r 'subject(\"keep me\")' --no-graph -T 'change_id' | grep -q ." \
    "run: jj new -m 'keep me' before the abandon"
  maybe "2.7  the detached experiment was integrated" \
    "op_attrs | grep -q 'detached experiment'" \
    "jj op integrate <id that --no-integrate-operation printed>"
  maybe "2.8  a partial restore was run in lab-ops (op restore --what)" \
    "labops lab-ops 'attributes ++ \"\\n\"' | grep -q 'op restore --what'" \
    "do 2.8 in ../lab-ops (./new-lab.sh lab-ops): jj op restore --what remote-tracking <op>"
  maybe "2.9  a revert op exists in lab-ops" \
    "labops lab-ops 'description ++ \"\\n\"' | grep -q '^revert operation '" \
    "do 2.9: jj op revert <op> in ../lab-ops"
  maybe "2.10 an abandoned workspace op was re-integrated in lab-ops" \
    "labops lab-ops 'attributes ++ \"\\n\"' | grep -q 'op integrate'" \
    "do 2.10: add a workspace, abandon the op the other workspace points at, jj op integrate it"
  info "2.11-2.14 are read-only experiments — your notes are the deliverable" \
    "op log --reversed, op show flags, op diff --show-changes-in, at_operation(), --at-op=@ snapshotting"
  maybe "2    sandbox still sane (seeded history reachable)" \
    "seeded" \
    "reset-sandbox.sh if you went too far (that is itself an op-log skill)"
  ;;

03)
  hdr
  maybe "3.1  the op store is a separate file store" \
    "[ \"\$(cat .jj/repo/op_store/type)\" = simple_op_store ] && [ -d .jj/repo/op_heads/heads ]" \
    "inspect .jj/repo/ layout (find .jj/repo -maxdepth 2 -type d)"
  maybe "3.2  ids are 128-hex and views dedupe" \
    "[ \"\$(jj op log -n 1 --no-graph -T 'id' | wc -c)\" -ge 128 ]" \
    "jj op log -n 1 --no-graph -T 'id ++ \"\\n\"' — full ids are 128 hex chars"
  maybe "3.5  history was trimmed (op log is short)" \
    "[ \"\$(jj op log --no-graph -T 'id ++ \"\\n\"' | wc -l)\" -le 15 ]" \
    "run: jj op abandon ..@---- ; jj util gc --expire now"
  maybe "3.6  the index was rebuilt (few op_links left)" \
    "[ \"\$(ls .jj/repo/index/op_links | wc -l)\" -le 5 ]" \
    "run: jj debug reindex"
  maybe "3.7  a lab-internals repo exists (the jj debug / gc experiments)" \
    "lab_exists lab-internals" \
    "cd .. && ./new-lab.sh lab-internals, then do 3.7-3.12 there"
  info "3.8-3.12 are read-only or lab-destructive experiments — your notes are the deliverable" \
    "jj debug object operation/view/commit, the working-copy checkout pointer, jj debug index, gc mtime guard"
  maybe "3    sandbox still sane (seeded history reachable)" \
    "seeded" \
    "reset-sandbox.sh if you went too far"
  ;;

04)
  hdr
  maybe "0    sandbox is not stale (checks below need a working jj)" \
    "jj st >/dev/null 2>&1" \
    "your working copy is stale — run: jj workspace update-stale"
  maybe "4.1  a second workspace 'side-task' exists" \
    "jj workspace list | grep -q side-task" \
    "run: jj workspace add ../side-task"
  maybe "4.1  its .jj/repo is a pointer file to the shared repo" \
    "[ -f ../side-task/.jj/repo ] && [ -d .jj/repo ]" \
    "cat ../side-task/.jj/repo — a text file with a relative path"
  maybe "4.3  the shared-view rewind reached your workspace (a restore op exists)" \
    "jj --repository ../side-task op log --no-graph -T 'description' | grep -q 'restore to operation'" \
    "from ../side-task: jj op restore \"\$OLD\" (an op captured before an interference snapshot), then jj st in sandbox"
  maybe "4.5  the dirty-path recovery forked and healed (a reconcile op exists)" \
    "op_descs | grep -q 'reconcile divergent operations'" \
    "re-do 4.5: edit files, op restore \"\$SNAP\" from side-task, then jj workspace update-stale"
  maybe "4.6  a cross-workspace undo happened (--allow-cross-workspace)" \
    "op_attrs | grep -q -- '--allow-cross-workspace'" \
    "run: jj undo --allow-cross-workspace (after a side-task op)"
  maybe "4.8  a multi-workspace forget was made (one op for two names)" \
    "op_descs | grep -q '^forget workspaces .*, .*\$'" \
    "run: jj workspace forget scratch spare (from sandbox)"
  maybe "4.9  a forget was undone" \
    "op_descs | grep -q '^undo: restore to operation'" \
    "run: jj undo right after a jj workspace forget"
  maybe "4.10 a workspace forgot itself (op tagged with its own name)" \
    "jj --ignore-working-copy op log --no-graph -T 'workspace_name ++ \"|\" ++ description ++ \"\\n\"' | grep -q '^scratch@|forget workspace scratch\$'" \
    "from ../scratch run: jj workspace forget (no argument)"
  maybe "4.12 a workspace name was re-used (add after forget)" \
    "op_descs | grep -c \"^add workspace 'scratch'\" | grep -q '^[2-9]'" \
    "jj workspace forget scratch; jj workspace add ../scratch-2 --name scratch"
  maybe "4.13 a workspace was renamed" \
    "op_descs | grep -q \"^Renamed workspace 'review' to 'inspect'\"" \
    "from ../review run: jj workspace rename inspect"
  maybe "4.14 the rename was undone across workspaces" \
    "op_attrs | grep -q -- 'args: jj undo --allow-cross-workspace' && op_descs | grep -q 'redo: restore to operation'" \
    "jj undo --allow-cross-workspace, then jj redo, in the renamed workspace"
  maybe "4.15 a workspace was removed" \
    "op_descs | grep -q '^remove workspace inspect\$'" \
    "run: jj workspace remove inspect (from sandbox)"
  maybe "4.16 a sibling working-copy op was integrated" \
    "op_attrs | grep -q -- 'args: jj op integrate'" \
    "abandon the op spare sits at, then jj op integrate ⟨op⟩ from ../spare"
  maybe "4.17 a recovery commit exists" \
    "jj --ignore-working-copy log -r 'description(substring:\"RECOVERY COMMIT\")' --no-graph -T change_id | grep -q ." \
    "abandon spare's op, jj util gc --expire now, then jj workspace update-stale in ../spare"
  maybe "4.17 ...and its op is named 'recovery commit'" \
    "op_descs | grep -q '^recovery commit\$'" \
    "same as above"
  maybe "4    sandbox still sane (seeded history reachable)" \
    "seeded" \
    "reset-sandbox.sh if you went too far"
  ;;

05)
  hdr
  maybe "0    sandbox is not stale (checks below need a working jj)" \
    "jj st >/dev/null 2>&1" \
    "your working copy is stale — run: jj workspace update-stale"
  maybe "5.1  divergent ops were healed (a reconcile op exists)" \
    "op_descs | grep -q 'reconcile divergent operations'" \
    "fork via --at-op twice, then run any command"
  maybe "5.2  the 3-fork merge op has 3 parents" \
    "jj op log --no-graph -T 'parents.len() ++ \"\\n\"' | grep -q '^3$'" \
    "re-do 5.2: three --at-op forks from one base, then jj log"
  maybe "5.5  the bookmark conflict was forked and healed" \
    "op_descs | grep -q 'delete bookmark main'" \
    "fork a bookmark move and a bookmark delete from one base op"
  maybe "5.6  restore worked through the merge op (a restore op exists)" \
    "op_descs | grep -q '^restore to operation'" \
    "run: jj op restore \"\$BASE\" (a specific op id — @- won't resolve through a merge)"
  info "5.7  the race is nondeterministic — look for 'divergent()' changes yourself" \
    "jj log -r 'divergent()'  (zero hits just means the race didn't bite; rerun it)"
  maybe "5.8  lab-forks healed a fork with a reconcile op (deterministic clocks)" \
    "labops lab-forks 'description ++ \"\\n\"' | grep -q 'reconcile divergent operations'" \
    "do 5.8 in ../lab-forks (./new-lab.sh lab-forks; define the at/opshape helpers)"
  maybe "5.11 two copies of one fork healed to the identical reconcile op" \
    "lab_exists copy1 && lab_exists copy2 && [ \"\$(labops copy1 'id.short(12) ++ \"\\n\"' | head -1)\" = \"\$(labops copy2 'id.short(12) ++ \"\\n\"' | head -1)\" ]" \
    "do 5.11: cp -a the forked lab to ../copy1 and ../copy2, heal both with the same pinned clock"
  maybe "5.15 the sibling working copy was reproduced and re-integrated" \
    "labops lab-forks 'attributes ++ \"\\n\"' | grep -q 'op integrate'" \
    "do 5.15 in ../lab-forks: workspace add, abandon the lagging op, jj op integrate it"
  info "5.12-5.14 are read-only or need strace — your notes are the deliverable"
  maybe "5    sandbox still sane (seeded history reachable)" \
    "seeded" \
    "reset-sandbox.sh if you went too far"
  ;;

06)
  hdr
  maybe "6.1  remote 'origin' points at the shared bare repo" \
    "jj git remote list | grep -q origin" \
    "jj git remote add origin ../shared-remote.git"
  maybe "6.1  the colleague clone exists and is a jj repo" \
    "[ -d ../colleague/.jj ]" \
    "jj git clone ../shared-remote.git ../colleague"
  maybe "6.1  the colleague has its own identity" \
    "jj --repository ../colleague op log --no-graph -T 'user' | grep -q 'colleague@colleague-box'" \
    "in ../colleague: jj config set --repo operation.username colleague && jj config set --repo operation.hostname colleague-box"
  maybe "6.2  a fetch op exists in your log" \
    "op_descs | grep -q '^fetch from git remote'" \
    "jj git fetch"
  maybe "6.2  the colleague's change arrived with the same change id" \
    "jj log -r 'remote_bookmarks()' --no-graph -T 'change_id' | grep -q ." \
    "fetch, then look at remote_bookmarks()"
  maybe "6.2  the remote carries the pushed bookmark" \
    "git --git-dir=../shared-remote.git branch 2>/dev/null | grep -q 'push-'" \
    "from ../colleague: jj git push --change @"
  maybe "6.4  you pushed main twice (6.1 and 6.4)" \
    "[ \"\$(op_descs | grep -c '^push bookmark main')\" -ge 2 ]" \
    "do 6.4: A moves main with 'jj new main', then 'jj bookmark move main' and 'jj git push --bookmark main'"
  maybe "6.4  the colleague resolved the conflict (a 'bookmark set main' op, then a successful 'push bookmark main')" \
    "c=\$(jj --ignore-working-copy --repository ../colleague op log --no-graph -T 'description ++ \"\\n\" ++ attributes ++ \"\\n\"'); grep -q '^push bookmark main' <<<\"\$c\" && grep -q 'jj bookmark set main' <<<\"\$c\"" \
    "in ../colleague: fetch, 'jj bookmark set main -r @', 'jj git push --bookmark main' (the rejected first push leaves no op)"
  maybe "6.5  A published its take under a separate bookmark (a-take on the remote)" \
    "git --git-dir=../shared-remote.git branch 2>/dev/null | grep -q a-take" \
    "from sandbox: jj git push --named a-take=@  (not --change @ — that re-uses push-<id>)"
  maybe "6.5  the colleague converged the divergent change" \
    "jj --ignore-working-copy --repository ../colleague op log --no-graph -T 'description ++ attributes ++ \"\\n\"' | grep -qi converge" \
    "in ../colleague: jj git fetch; jj bookmark track a-take --remote origin; jj converge"
  maybe "6    sandbox still sane (seeded history reachable)" \
    "seeded" \
    "reset-sandbox.sh if you went too far"
  ;;

07)
  hdr
  maybe "7.1  the simulated two-machine race ran (alice@laptop is in your log)" \
    "op_users | grep -q 'alice@laptop'" \
    "run the parallel describe loop from 7.1"
  maybe "7.1  and so is bob" \
    "op_users | grep -q 'bob@desk'" \
    "both subshells of the 7.1 loop must run"
  maybe "7.1  the race healed (a reconcile op exists)" \
    "op_descs | grep -q 'reconcile divergent operations'" \
    "any command after a fork prints 'Concurrent modification detected'"
  info "7.3  the crash-window protocol is observational — your notes are the deliverable" \
    "you should have seen >= 2 head-marker files, then one after any jj command"
  LAB="$here/lab-sync"
  lab_users() { jj --ignore-working-copy -R "$LAB/$1" op log --no-graph -T 'user ++ "\n"' 2>/dev/null; }
  lab_ids()   { jj --ignore-working-copy -R "$LAB/$1" op log --no-graph -T 'id ++ "\n"' 2>/dev/null | sort; }
  lab_descs() { jj --ignore-working-copy -R "$LAB/$1" op log --no-graph -T 'description ++ "\n"' 2>/dev/null; }
  maybe "7.6  two diverging copies exist (alice in machine-a, bob in machine-b)" \
    "lab_users machine-a | grep -q 'alice@laptop' && lab_users machine-b | grep -q 'bob@desk'" \
    "do 7.6 in ../lab-sync (copies, not clones)"
  maybe "7.6  the copies share real ops (unlike 6.3's clones)" \
    "[ \"\$(comm -12 <(lab_ids machine-a) <(lab_ids machine-b) | grep -cv '^0*\$')\" -ge 1 ]" \
    "run the comm pipeline at the end of 7.6"
  maybe "7.7  the objects-then-ops sync healed: reconcile op + shared (conflicted)" \
    "lab_descs try1 | grep -q 'reconcile divergent operations' && jj --ignore-working-copy -R \"\$LAB/try1\" bookmark list shared 2>/dev/null | grep -q conflicted" \
    "do 7.7 in full: the second rsync of the git objects is what lets the merge succeed"
  maybe "7.9  one-way-then-back converged: ma2 and mb2 have identical op ids and one head" \
    "[ \"\$(ls \"\$LAB/ma2/.jj/repo/op_heads/heads\" | wc -l)\" -eq 1 ] && diff <(lab_ids ma2) <(lab_ids mb2) >/dev/null" \
    "do 7.9: sync B into A, run one command, sync A back into B, run one command"
  maybe "7.11 a hand-deleted head marker was restored with op integrate (bob-topic is back)" \
    "jj --ignore-working-copy -R \"\$LAB/hd\" bookmark list 2>/dev/null | grep -q bob-topic" \
    "do the hd experiment in 7.11 through 'jj op integrate'"
  maybe "7.12 the --delete mirror erased alice from the destination" \
    "[ -d \"\$LAB/del\" ] && ! lab_users del | grep -q 'alice@laptop'" \
    "do 7.12 (rsync --delete) in a throwaway copy"
  maybe "7.14 the two-process race kept all 30 bookmarks" \
    "[ \"\$(jj --ignore-working-copy -R \"\$LAB/race\" bookmark list 2>/dev/null | grep -c -E '^(alice|bob)-')\" -eq 30 ]" \
    "run the 7.14 loops in ../lab-sync/race (15 creates each)"
  maybe "7.15 undoing a push left the remote untouched (then fetch + push recovered)" \
    "[ \"\$(git --git-dir=\"\$LAB/remote.git\" rev-parse refs/heads/main 2>/dev/null)\" = \"\$(jj --ignore-working-copy -R \"\$LAB/u3\" log -r main --no-graph -T commit_id 2>/dev/null)\" ]" \
    "finish the u3 experiment: undo, new commit, push (rejected), fetch, push"
  info "7.14/7.15 the Dropbox loop and the fetch race are timing-dependent — your outputs may differ" \
    "that is the lesson: nothing is lost, but transient errors are possible"
  maybe "7    sandbox still sane (seeded history reachable)" \
    "seeded" \
    "reset-sandbox.sh if you went too far"
  ;;

08)
  hdr
  info "8    reading lab — your notes are the deliverable" \
    "see lessons/08-commit-cloud.md; paths assume ../jj-commit-cloud"
  ;;

*)
  usage
  ;;
esac

echo
echo "Result: $PASS passed, $FAIL failed."
(( FAIL == 0 )) && echo "Lesson $lesson complete ✔ — proceed to the next lesson."
exit $(( FAIL > 0 ))
