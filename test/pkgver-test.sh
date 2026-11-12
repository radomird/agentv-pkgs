#!/bin/bash

# Checks the version the agentv package gets, with the PKGBUILD's own
# pkgver() run against a small stand-in for agentv-os: a release tag is its
# version (agentv-v1.0.0, and v0.2.0 from the 0.x days), commits after it
# count from it, Omarchy's own v1 to v4 tags and a candidate's tag never
# count, and edge's package always says its commit. Needs git and nothing
# else: no makepkg, no network.
#
# Usage: test/pkgver-test.sh

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
pass() { printf 'ok - %s\n' "$1"; }
fail() {
  printf 'not ok - %s\n' "$1" >&2
  failures=$(( failures + 1 ))
}

# makepkg runs pkgver() from the folder the source was cloned into, which
# has the clone as agentv-os.
repo="$work/src/agentv-os"
mkdir -p "$repo"
git -C "$repo" init --quiet --initial-branch agentv
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.invalid
commit() { git -C "$repo" commit --quiet --allow-empty -m "$1"; }
tag() { git -C "$repo" tag "$@"; }
short() { git -C "$repo" rev-parse --short "${1:-HEAD}"; }

# What pkgver() prints for the stand-in as it is now, on a channel.
version() {
  (
    cd "$work/src"
    AGENTV_SOURCE=https://example.invalid/agentv-os.git AGENTV_REF=commit=0 AGENTV_CHANNEL=$1
    export AGENTV_SOURCE AGENTV_REF AGENTV_CHANNEL
    # shellcheck source=/dev/null
    source "$ROOT/agentv/PKGBUILD"
    pkgver
  )
}
is() {
  local name=$1 channel=$2 want=$3 got
  got=$(version "$channel" 2>"$work/err") || { cat "$work/err" >&2; fail "$name (pkgver failed)"; return; }
  if [[ $got == "$want" ]]; then pass "$name"; else fail "$name: got $got, not $want"; fi
}

# Omarchy's history comes first, with its own tags.
commit "omarchy 1"
tag v1.1.0
commit "omarchy 4"
tag v4.0.6
commit "agentv starts"
is "before any AgenTV release, Omarchy's tags don't count" stable "0.0.0.r3.g$(git -C "$repo" rev-parse --short=7 HEAD)"

commit "0.2.0"
tag v0.2.0
is "a 0.x release is its tag's version on stable" stable 0.2.0
is "and on edge it says its commit too" edge "0.2.0.r0.g$(short)"
commit "after 0.2.0"
commit "omarchy 4.5 merged"
tag v4.5.0
is "commits after a 0.x release count from it, on edge" edge "0.2.0.r2.g$(short)"
is "and on stable, when it's built off a tag" stable "0.2.0.r2.g$(short)"

# A candidate is a tag on the way to a release. A tag with a message of
# its own, as a release's can be.
commit "the candidate"
tag -a -m "1.0.0-rc1" agentv-v1.0.0-rc1
is "a candidate's tag changes nothing: edge still counts from 0.2.0" edge "0.2.0.r3.g$(short)"
is "and so does stable" stable "0.2.0.r3.g$(short)"
commit "after the candidate"
is "after a candidate too" edge "0.2.0.r4.g$(short)"

commit "1.0.0"
tag -a -m "1.0.0" agentv-v1.0.0
is "agentv-v1.0.0 is 1.0.0 on stable" stable 1.0.0
is "and 1.0.0.r0 with its commit on edge" edge "1.0.0.r0.g$(short)"
commit "after 1.0.0"
is "edge reads 1.0.0.rN.g<sha> after agentv-v1.0.0" edge "1.0.0.r1.g$(short)"

# Both ways of writing a tag, side by side: the highest version is the
# last release, not the tag that happens to be nearest.
commit "a late 0.x fix"
tag v0.2.1
is "an old-style tag put on later doesn't take over from 1.0.0" edge "1.0.0.r2.g$(short)"
tag v1.0.1
tag agentv-1.0.1
tag agentv-v1.0.1-beta
tag agentv-v01.0.1
tag agentv-v1.00.1
tag v0.02.9
is "a tag that only looks like a release isn't one" stable "1.0.0.r2.g$(short)"
commit "1.0.10"
tag agentv-v1.0.9 HEAD~1
tag agentv-v1.0.10
is "versions sort as numbers: 1.0.10 is after 1.0.9" stable 1.0.10
git -C "$repo" checkout --quiet -b side HEAD~2
commit "a branch off before 1.0.9 and the late fix"
is "a release this commit doesn't have behind it doesn't count" edge "1.0.0.r2.g$(short)"

(( failures == 0 )) || { echo "$failures failed" >&2; exit 1; }
echo "all passed"
