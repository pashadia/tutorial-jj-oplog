#!/usr/bin/env bash
# new-lab.sh NAME — create (or recreate) a fresh seeded colocated jj+git repo
# at ./NAME, identical in shape to the sandbox right after ./reset-sandbox.sh.
# Used by the "lab" exercises that would otherwise pollute the sandbox
# (lessons 02, 03, 05). Safe to re-run: it wipes ./NAME first.
# Uses the pinned jj in tools/. Requires bash.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
export PATH="$here/tools:$PATH"
name="${1:-}"
[[ "$name" =~ ^lab-[A-Za-z0-9_-]+$ ]] || { echo "usage: $0 lab-<name>   (name must start with 'lab-')" >&2; exit 1; }
dir="$here/$name"

rm -rf "$dir"
mkdir -p "$dir"
cd "$dir"
git init -q .
git config user.name  "jj oplog tutorial"
git config user.email "tutorial@example.com"
git symbolic-ref HEAD refs/heads/main
mkdir -p src
printf '# oplog-demo\n\nA tiny project for the jj op-log tutorial sandbox.\n' > README.md
printf 'def greet(name):\n    return f"Hello, {name}!"\n' > src/greet.py
git add -A && git commit -q -m "Initial project"
printf '\ndef farewell(name):\n    return f"Bye, {name}!"\n' >> src/greet.py
git add -A && git commit -q -m "Add farewell"
jj git init --colocate . >/dev/null 2>&1
echo "Lab repo ready: $dir  (cd $dir)"
