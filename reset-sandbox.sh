#!/usr/bin/env bash
# Recreate the op-log tutorial sandbox from scratch.
#
# Creates:
#   sandbox/           colocated jj+git repo with a tiny seeded history
#                      (seeded VIA GIT first, so the op log is born with the
#                      two `import git …` operations lesson 01 talks about)
#   shared-remote.git/ empty bare repo — the "team remote" for lesson 06
#
# Removes (so every run starts clean, even mid-tutorial):
#   sandbox/, side-task/ + scratch/ scratch-2/ spare/ review/ (lesson 04),
#   colleague/ (lesson 06)
#
# Requires jj 0.46.0+ on PATH and bash (see README.md).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
sandbox="$here/sandbox"
remote="$here/shared-remote.git"

# Require jj 0.46.0+ — the lessons depend on 0.46 behavior.
ver="$(jj --version 2>/dev/null | awk '{print $2}')" || true
base="${ver%%-*}"; major="${base%%.*}"; rest="${base#*.}"; minor="${rest%%.*}"
if [[ -z "${ver:-}" || ! "$major" =~ ^[0-9]+$ || ! "$minor" =~ ^[0-9]+$ ]] \
   || (( major == 0 && minor < 46 )); then
  echo "This tutorial needs jj 0.46.0 or newer; found '${ver:-no jj on PATH}'." >&2
  echo "See https://docs.jj-vcs.dev/latest/install-and-setup/" >&2
  exit 1
fi
echo "Using jj $ver ($(command -v jj))"

# ── Clean slate ────────────────────────────────────────────────────────────
rm -rf "$sandbox" "$here/side-task" "$here/colleague"
rm -rf "$here/scratch" "$here/scratch-2" "$here/spare" "$here/review"   # lesson 04 (4.8+)
rm -rf "$here"/lab-*                                                     # lessons 02/03/05/07 labs (new-lab.sh, 7.6+)
rm -rf "$here/copy1" "$here/copy2" "$here/side" "$here/remote.git"      # 5.11, 2.10/5.15, 2.8
rm -rf "$remote"
mkdir -p "$sandbox"
cd "$sandbox"

# ── Seed a tiny project with plain git first ────────────────────────────────
# (so that `jj git init --colocate` below has history to import — you'll see
# the resulting `import git refs` / `import git head` operations in lesson 01)
git init -q .
git config user.name  "jj oplog tutorial"
git config user.email "tutorial@example.com"
git symbolic-ref HEAD refs/heads/main

mkdir -p src
cat > README.md <<'EOF'
# oplog-demo

A tiny project for the jj op-log tutorial sandbox.
EOF
cat > src/greet.py <<'EOF'
def greet(name):
    return f"Hello, {name}!"
EOF
git add -A
git commit -q -m "Initial project"

cat >> src/greet.py <<'EOF'

def farewell(name):
    return f"Bye, {name}!"
EOF
git add -A
git commit -q -m "Add farewell"

# ── Colocate jj on top: the birth of the op log you'll study in lesson 01 ──
# root() → add workspace 'default' → import git refs → import git head
jj git init --colocate . >/dev/null 2>&1

# ── The team remote (empty bare repo, HEAD aimed at main) ──────────────────
git init -q --bare "$remote"
# A bare repo's HEAD defaults to 'master'; aim it at main so clones track
# the right default bookmark and get trunk() set automatically.
git --git-dir="$remote" symbolic-ref HEAD refs/heads/main

echo "Sandbox created at $sandbox"
echo
echo "History:"
jj log --no-graph -T 'commit_id.short() ++ " " ++ description.first_line() ++ "\n"'
echo
echo "The op log starts fresh — that is lesson 01's subject:"
jj op log --no-graph -T 'id.short(8) ++ "  " ++ description ++ "\n"' | sed -n '1,6p'
