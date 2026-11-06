#!/usr/bin/env bash
# new-lab.sh NAME — create (or recreate) a fresh seeded colocated jj+git repo
# at ./NAME, identical in shape to the sandbox right after ./reset-sandbox.sh.
# Used by the "lab" exercises that would otherwise pollute the sandbox
# (lessons 02, 03, 05). Safe to re-run: it wipes ./NAME first.
# Requires jj 0.46.0+ on PATH and bash.
set -euo pipefail

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
