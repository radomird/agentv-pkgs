#!/bin/bash

# Checks what bin/plan lets through to be built, signed and published: only
# a commit agentv-os's agentv branch has, whether a release tag, the Check
# run or a run by hand names it. A stand-in for gh is first on PATH and
# answers from a folder of files, so nothing here asks GitHub. Also reads
# the build workflow, to see that every build comes from the plan.
#
# Usage: test/plan-test.sh

# The workflow's and jq's own $ are meant as they're written.
# shellcheck disable=SC2016

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
check() {
  local name=$1
  shift
  if "$@" >"$work/check.log" 2>&1; then pass "$name"; else
    sed 's/^/    /' "$work/check.log" >&2
    fail "$name"
  fi
}

# --- A stand-in GitHub -------------------------------------------------------

# "gh api <path> [--jq <filter>]" prints $GITHUB_FAKE/<path, with _ for />,
# and "gh release view <channel> ..." prints $GITHUB_FAKE/release-<channel>.
# No file is GitHub's "not found". Every call is written down.
mkdir "$work/bin"
cat >"$work/bin/gh" <<'GH'
#!/bin/bash
set -euo pipefail
echo "$*" >>"$GITHUB_FAKE/calls"
filter=.
args=()
while (( $# )); do
  case $1 in
    --jq) filter=$2; shift 2 ;;
    -R | --json) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
case "${args[0]} ${args[1]}" in
  "api "*) file="$GITHUB_FAKE/${args[1]//[\/?]/_}" ;;
  "release view") file="$GITHUB_FAKE/release-${args[2]}" ;;
  *) echo "the stand-in doesn't know: ${args[*]}" >&2; exit 2 ;;
esac
[[ -f $file ]] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
jq -r "$filter" "$file"
GH
chmod +x "$work/bin/gh"

OS=repos/someone/agentv-os
on_agentv=$(printf 'a%.0s' {1..40})     # a commit agentv has
head=$(printf 'b%.0s' {1..40})          # agentv's newest commit
unmerged=$(printf 'c%.0s' {1..40})      # a commit on a branch that isn't merged
tag_object=$(printf 'd%.0s' {1..40})    # a tag with a message of its own

answer() {
  local path=$1
  shift
  jq -cn "$@" >"$GITHUB_FAKE/${path//[\/?]/_}"
}

# agentv-os with three release tags (the newest, v0.2.0, on a commit agentv
# has), Omarchy's own tags, a green Check run on agentv's newest commit, and
# nothing published yet.
github() {
  export GITHUB_FAKE="$work/github"
  rm -rf "$GITHUB_FAKE"
  mkdir "$GITHUB_FAKE"
  answer "$OS/tags?per_page=100" '[{name: "v4.5.0"}, {name: "v0.2.0"}, {name: "v0.1.4"}, {name: "v0.10.0-rc1"}, {name: "v0.1.0"}]'
  answer "$OS/git/ref/tags/v0.2.0" --arg sha "$on_agentv" '{object: {type: "commit", sha: $sha}}'
  answer "$OS/git/ref/tags/v0.1.4" --arg sha "$tag_object" '{object: {type: "tag", sha: $sha}}'
  answer "$OS/git/tags/$tag_object" --arg sha "$on_agentv" '{object: {type: "commit", sha: $sha}}'
  answer "$OS/actions/workflows/check.yml/runs?branch=agentv&event=push&status=success&per_page=1" \
    --arg sha "$head" '{workflow_runs: [{head_sha: $sha}]}'
  answer "$OS/compare/$on_agentv...agentv" '{status: "ahead"}'
  answer "$OS/compare/$head...agentv" '{status: "identical"}'
  answer "$OS/compare/$unmerged...agentv" '{status: "diverged"}'
}

plan() {
  env PATH="$work/bin:$PATH" GITHUB_REPOSITORY_OWNER=someone GITHUB_REPOSITORY=someone/agentv-pkgs \
    "$ROOT/bin/plan" "$@" 2>"$work/plan.err"
}
# The plan is exactly this.
plans() {
  local want=$1 got
  shift
  got=$(plan "$@") || { cat "$work/plan.err"; echo "bin/plan $* failed"; return 1; }
  [[ $got == "$want" ]] || { cat "$work/plan.err"; echo "bin/plan $* gave $got, not $want"; return 1; }
}
# It fails, prints no plan, and says why.
stops() {
  local why=$1 got
  shift
  if got=$(plan "$@"); then echo "bin/plan $* gave $got"; return 1; fi
  [[ -z $got ]] || { echo "bin/plan $* printed $got as it failed"; return 1; }
  grep -qF -- "$why" "$work/plan.err" || { cat "$work/plan.err"; echo "it didn't say: $why"; return 1; }
}
says() { grep -qF -- "$1" "$work/plan.err"; }

# --- A run by hand -----------------------------------------------------------

github
check "by hand, a commit agentv has is built" \
  plans "[{\"channel\":\"edge\",\"ref\":\"commit=$on_agentv\"}]" edge "commit=$on_agentv"
check "and agentv's newest commit" \
  plans "[{\"channel\":\"edge\",\"ref\":\"commit=$head\"}]" edge "commit=$head"
check "a release tag is built at the commit it's on" \
  plans "[{\"channel\":\"stable\",\"ref\":\"commit=$on_agentv\"}]" stable tag=v0.2.0
check "a tag with a message of its own too" \
  plans "[{\"channel\":\"stable\",\"ref\":\"commit=$on_agentv\"}]" stable tag=v0.1.4

check "a commit agentv doesn't have stops the run" \
  stops "agentv branch doesn't have commit=$unmerged" edge "commit=$unmerged"
check "on stable too" \
  stops "agentv branch doesn't have commit=$unmerged" stable "commit=$unmerged"
check "a commit GitHub doesn't know stops the run" \
  stops "agentv branch doesn't have" edge "commit=$(printf 'e%.0s' {1..40})"
answer "$OS/git/ref/tags/v0.3.0" --arg sha "$unmerged" '{object: {type: "commit", sha: $sha}}'
check "a release tag on a commit agentv doesn't have stops the run" \
  stops "agentv branch doesn't have tag=v0.3.0" stable tag=v0.3.0
check "a tag that isn't there stops the run" \
  stops "Couldn't find the commit" stable tag=v0.9.9
check "a short commit isn't taken" stops "isn't a whole commit" edge commit=aaaaaaa
check "a branch isn't taken as a commit" stops "isn't a whole commit" edge commit=some-branch
check "nor as a tag" stops "isn't a release tag" stable tag=some-branch
check "nor any other kind of ref" stops "A ref is tag=v0.1.0 or commit=<sha>" edge branch=some-branch
check "a channel is edge or stable" stops "The channel is edge or stable" rc "commit=$on_agentv"

# --- The hourly run ----------------------------------------------------------

github
check "the hourly run plans the newest release tag and the newest green commit, each as its commit" \
  plans "[{\"channel\":\"stable\",\"ref\":\"commit=$on_agentv\"},{\"channel\":\"edge\",\"ref\":\"commit=$head\"}]"
check "it asks about nothing but agentv-os and what's published" \
  bash -c "! grep -vE '^(api repos/someone/agentv-os/|release view (edge|stable) -R someone/agentv-pkgs )' '$GITHUB_FAKE/calls'"

github
answer "$OS/git/ref/tags/v0.2.0" --arg sha "$unmerged" '{object: {type: "commit", sha: $sha}}'
check "a release tag on a commit agentv doesn't have is left out, and edge still builds" \
  plans "[{\"channel\":\"edge\",\"ref\":\"commit=$head\"}]"
check "and the run says so" says "agentv branch doesn't have tag=v0.2.0"
check "with --all as well" plans "[{\"channel\":\"edge\",\"ref\":\"commit=$head\"}]" --all

github
answer "$OS/compare/$head...agentv" '{status: "diverged"}'
check "a green commit agentv no longer has is left out, and stable still builds" \
  plans "[{\"channel\":\"stable\",\"ref\":\"commit=$on_agentv\"}]"

github
rm "$GITHUB_FAKE/${OS//\//_}_compare_$on_agentv...agentv"
check "with no answer about a commit, it's left out" plans "[{\"channel\":\"edge\",\"ref\":\"commit=$head\"}]"

github
jq -n '{assets: [{name: "agentv-0.2.0-1-any.pkg.tar.zst"}]}' >"$GITHUB_FAKE/release-stable"
jq -n --arg sha "$head" '{assets: [{name: "agentv-0.2.0.r3.g\($sha[0:7])-1-any.pkg.tar.zst"}]}' >"$GITHUB_FAKE/release-edge"
check "what's published already isn't planned again" plans "[]"
check "but --all plans it" \
  plans "[{\"channel\":\"stable\",\"ref\":\"commit=$on_agentv\"},{\"channel\":\"edge\",\"ref\":\"commit=$head\"}]" --all

# --- The build workflow ------------------------------------------------------

workflow="$ROOT/.github/workflows/build.yml"
job() { awk -v job="$1" '$0 == "  " job ":" { on = 1; next } on && /^  [a-z][a-z0-9-]*:$/ { on = 0 } on' "$workflow"; }
# A job builds only what the plan lists, and not at all without a plan.
from_the_plan() {
  local text
  text=$(job "$1")
  grep -qF 'include: ${{ fromJSON(needs.plan.outputs.builds) }}' <<<"$text" &&
    grep -qE "^    needs: (plan|\[plan, [a-z]+\])$" <<<"$text" &&
    grep -qF "needs.plan.outputs.builds != '[]'" <<<"$text"
}
for name in build sign publish; do
  check "the $name job builds only what the plan lists" from_the_plan "$name"
done
check "the ref a build fetches is the plan's" grep -qF 'AGENTV_REF: ${{ matrix.ref }}' "$workflow"
check "and nothing else in the workflow reads the ref typed by hand" \
  bash -c '[[ $(grep -c "inputs\.ref" "$1") == 1 ]] && grep -q "REF: \${{ inputs.ref }}" "$1"' _ "$workflow"
check "which goes through bin/plan" grep -qF 'builds=$(bin/plan "$CHANNEL" "$REF")' "$workflow"

(( failures == 0 )) || { echo "$failures failed" >&2; exit 1; }
echo "all passed"
