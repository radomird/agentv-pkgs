#!/bin/bash

# Checks what bin/plan lets through to be built, signed and published: only
# a commit agentv-os's agentv branch has, whether a release tag, the Check
# run or a run by hand names it. And which tag is a release: agentv-v1.0.0,
# or v0.2.0 from the 0.x days, the highest version being stable's. Never a
# candidate's tag, and never one of Omarchy's own v1 to v4 tags. A stand-in
# for gh is first on PATH and answers from a folder of files, so nothing
# here asks GitHub. Also reads the build workflow, to see that every build
# comes from the plan, and that what the plan leaves out is said out loud.
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
    --paginate) shift ;;
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
one=$(printf 'f%.0s' {1..40})           # the commit 1.0.0 is on, which agentv has

answer() {
  local path=$1
  shift
  jq -cn "$@" >"$GITHUB_FAKE/${path//[\/?]/_}"
}

# Where the stand-in keeps its answer for a path.
answer_file() { echo "$GITHUB_FAKE/${1//[\/?]/_}"; }
# GitHub has no answer for that path any more.
forget() { unlink "$(answer_file "$1")"; }

# The tags agentv-os answers with for one of the two ways a release tag
# starts.
tags() {
  local start=$1
  shift
  printf '%s\n' "$@" | jq -Rn '[inputs | select(. != "") | {ref: "refs/tags/\(.)"}]' >"$(answer_file "$OS/git/matching-refs/tags/$start")"
}

# agentv-os with three 0.x release tags (the newest, v0.2.0, on a commit
# agentv has), Omarchy's own tags, no agentv-v tag yet, a green Check run
# on agentv's newest commit, and nothing published yet.
github() {
  export GITHUB_FAKE="$work/github"
  [[ ! -d $GITHUB_FAKE ]] || find "$GITHUB_FAKE" -mindepth 1 -delete
  mkdir -p "$GITHUB_FAKE"
  tags v0. v0.2.0 v0.1.4 v0.10.0-rc1 v0.1.0
  tags agentv-v
  answer "$OS/git/ref/tags/v0.2.0" --arg sha "$on_agentv" '{object: {type: "commit", sha: $sha}}'
  answer "$OS/git/ref/tags/v0.1.4" --arg sha "$tag_object" '{object: {type: "tag", sha: $sha}}'
  answer "$OS/git/tags/$tag_object" --arg sha "$on_agentv" '{object: {type: "commit", sha: $sha}}'
  # Omarchy's v4.0.6 is in agentv's history, so its commit is one agentv has.
  answer "$OS/git/ref/tags/v4.0.6" --arg sha "$on_agentv" '{object: {type: "commit", sha: $sha}}'
  answer "$OS/git/ref/tags/agentv-v1.0.0" --arg sha "$one" '{object: {type: "commit", sha: $sha}}'
  answer "$OS/git/ref/tags/agentv-v1.0.0-rc1" --arg sha "$on_agentv" '{object: {type: "commit", sha: $sha}}'
  answer "$OS/actions/workflows/check.yml/runs?branch=agentv&event=push&status=success&per_page=1" \
    --arg sha "$head" '{workflow_runs: [{head_sha: $sha}]}'
  answer "$OS/compare/$on_agentv...agentv" '{status: "ahead"}'
  answer "$OS/compare/$one...agentv" '{status: "ahead"}'
  answer "$OS/compare/$head...agentv" '{status: "identical"}'
  answer "$OS/compare/$unmerged...agentv" '{status: "diverged"}'
}

plan() {
  : >"$work/refused"
  env PATH="$work/bin:$PATH" GITHUB_REPOSITORY_OWNER=someone GITHUB_REPOSITORY=someone/agentv-pkgs \
    AGENTV_PLAN_REFUSED="$work/refused" "$ROOT/bin/plan" "$@" 2>"$work/plan.err"
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
# What the last plan left out, as the workflow reads it: a line each.
left_out() { grep -qF -- "$1" "$work/refused"; }
left_nothing_out() { [[ ! -s $work/refused ]] || { cat "$work/refused"; return 1; }; }
# Nothing GitHub was asked matches this.
never_asked() { ! grep -E -- "$1" "$GITHUB_FAKE/calls"; }

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
check "a release from 1.0 on is tagged agentv-v1.0.0, and built at its commit" \
  plans "[{\"channel\":\"stable\",\"ref\":\"commit=$one\"}]" stable tag=agentv-v1.0.0
check "a candidate's tag can be built as edge" \
  plans "[{\"channel\":\"edge\",\"ref\":\"commit=$on_agentv\"}]" edge tag=agentv-v1.0.0-rc1
check "and never as stable" \
  stops "stable is never built from one" stable tag=agentv-v1.0.0-rc1
check "one of Omarchy's own tags isn't a release of AgenTV's, though agentv has its commit" \
  stops "isn't one of AgenTV's release tags" stable tag=v4.0.6
check "nor is v1.0.0: from 1.0 on the tag says agentv" \
  stops "isn't one of AgenTV's release tags" stable tag=v1.0.0
check "nor an old-style candidate" stops "isn't one of AgenTV's release tags" edge tag=v0.10.0-rc1

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
check "nor as a tag" stops "isn't one of AgenTV's release tags" stable tag=some-branch
check "nor any other kind of ref" stops "A ref is tag=agentv-v1.0.0 or commit=<sha>" edge branch=some-branch
check "a channel is edge or stable" stops "The channel is edge or stable" rc "commit=$on_agentv"

# --- The hourly run ----------------------------------------------------------

both() { echo "[{\"channel\":\"stable\",\"ref\":\"commit=$1\"},{\"channel\":\"edge\",\"ref\":\"commit=$head\"}]"; }
edge_only="[{\"channel\":\"edge\",\"ref\":\"commit=$head\"}]"

github
check "the hourly run plans the newest release tag and the newest green commit, each as its commit" \
  plans "$(both "$on_agentv")"
check "and leaves nothing out" left_nothing_out
check "it asks about nothing but agentv-os and what's published" \
  bash -c "! grep -vE '^(api (--paginate )?repos/someone/agentv-os/|release view (edge|stable) -R someone/agentv-pkgs )' '$GITHUB_FAKE/calls'"
check "it never lists every tag, which would bring Omarchy's" \
  never_asked 'agentv-os/tags|matching-refs/tags/(v|v[1-9][^ ]*)?( |$)'

github
answer "$OS/git/ref/tags/v0.2.0" --arg sha "$unmerged" '{object: {type: "commit", sha: $sha}}'
check "a release tag on a commit agentv doesn't have is left out, and edge still builds" plans "$edge_only"
check "and the run says so" says "agentv branch doesn't have tag=v0.2.0"
check "and so does the list the workflow opens an issue from" left_out "agentv branch doesn't have tag=v0.2.0"
check "with --all as well" plans "$edge_only" --all

github
answer "$OS/compare/$head...agentv" '{status: "diverged"}'
check "a green commit agentv no longer has is left out, and stable still builds" \
  plans "[{\"channel\":\"stable\",\"ref\":\"commit=$on_agentv\"}]"
check "and that's in the list too" left_out "agentv branch doesn't have commit=$head"

github
forget "$OS/compare/$on_agentv...agentv"
check "with no answer about a commit, it's left out" plans "$edge_only"

github
forget "$OS/git/matching-refs/tags/agentv-v"
check "when the release tags can't be listed, stable is left out and edge still builds" plans "$edge_only"
check "and the list says so" left_out "Couldn't list agentv-os's release tags"

github
jq -n '{assets: [{name: "agentv-0.2.0-1-any.pkg.tar.zst"}]}' >"$GITHUB_FAKE/release-stable"
jq -n --arg sha "$head" '{assets: [{name: "agentv-0.2.0.r3.g\($sha[0:7])-1-any.pkg.tar.zst"}]}' >"$GITHUB_FAKE/release-edge"
check "what's published already isn't planned again" plans "[]"
check "but --all plans it" plans "$(both "$on_agentv")" --all
# git writes as much of a commit's name as it needs to tell commits apart,
# and agentv-os is big enough for nine.
jq -n --arg sha "$head" '{assets: [{name: "agentv-0.2.0.r532.g\($sha[0:9])-1-any.pkg.tar.zst"}]}' >"$GITHUB_FAKE/release-edge"
check "an edge package that names its commit with nine letters is published already too" plans "[]"
jq -n --arg sha "$on_agentv" '{assets: [{name: "agentv-0.2.0.r531.g\($sha[0:9])-1-any.pkg.tar.zst"}]}' >"$GITHUB_FAKE/release-edge"
check "and one from another commit isn't" plans "$edge_only"

# --- Which tag is the newest release ------------------------------------------

github
tags agentv-v agentv-v1.0.0
check "with v0.2.0 and agentv-v1.0.0 side by side, 1.0.0 is the newest release" plans "$(both "$one")"
jq -n '{assets: [{name: "agentv-1.0.0-1-any.pkg.tar.zst"}]}' >"$GITHUB_FAKE/release-stable"
check "and once 1.0.0 is published, stable isn't planned again" plans "$edge_only"
jq -n '{assets: [{name: "agentv-1.0.0.r2.gabcdef012-1-any.pkg.tar.zst"}]}' >"$GITHUB_FAKE/release-stable"
check "a package that only starts with the release's version isn't the release" plans "$(both "$one")"

github
tags agentv-v agentv-v1.0.0-rc1 agentv-v1.0.0-rc2 agentv-v1.1.0-rc1
check "a candidate's tag never moves stable: it stays on the release before" plans "$(both "$on_agentv")"
check "and nothing is left out by that" left_nothing_out
check "nobody even asks where a candidate's tag is" never_asked '-rc'

github
tags agentv-v agentv-v1.0.0 agentv-v1.0.0-rc1 agentv-v1.0.1-rc1
check "with candidates before and after it, the release is stable's" plans "$(both "$one")"

github
tags v0. v0.2.0 v0.9.0junk v0.2 v0.3.0-rc1
tags agentv-v agentv-v2 agentv-v9.9.9-beta agentv-v9.9.9.1 agentv-vnext
check "a tag that only looks like a release isn't one" plans "$(both "$on_agentv")"

github
ten=$(printf '9%.0s' {1..40})
tags agentv-v agentv-v1.0.9 agentv-v1.0.10 agentv-v1.0.0
answer "$OS/git/ref/tags/agentv-v1.0.10" --arg sha "$ten" '{object: {type: "commit", sha: $sha}}'
answer "$OS/compare/$ten...agentv" '{status: "ahead"}'
check "versions sort as numbers: 1.0.10 is newer than 1.0.9" plans "$(both "$ten")"

github
tags v0. v0.2.0 v0.3.0
tags agentv-v agentv-v0.3.0
answer "$OS/git/ref/tags/v0.3.0" --arg sha "$unmerged" '{object: {type: "commit", sha: $sha}}'
answer "$OS/git/ref/tags/agentv-v0.3.0" --arg sha "$one" '{object: {type: "commit", sha: $sha}}'
check "one version tagged both ways is one release, and the agentv-v tag stands for it" plans "$(both "$one")"

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

# What the plan leaves out is said where it's seen: the plan's job hands
# the list on, and a job that builds nothing fails the run and opens an
# issue. The channels' own jobs don't wait for it.
left=$(job left-out)
has() { grep -qF -- "$1" <<<"$2"; }
check "the plan is told where to write what it leaves out" \
  has 'AGENTV_PLAN_REFUSED: ${{ runner.temp }}/refused' "$(job plan)"
check "and hands the list on" has 'refused: ${{ steps.plan.outputs.refused }}' "$(job plan)"
check "to a job that reads it" has 'REFUSED: ${{ needs.plan.outputs.refused }}' "$left"
check "which has no more than the right to write issues" \
  bash -c '[[ $(grep -A1 "^    permissions:" <<<"$1" | tail -n 1) == "      issues: write" ]]' _ "$left"
check "and no secrets" bash -c '! grep -qE "secrets\.|environment:" <<<"$1"' _ "$left"
for name in build sign publish; do
  check "the $name job doesn't wait for it" bash -c '! grep -qE "^    needs: .*left-out" <<<"$1"' _ "$(job "$name")"
done

# The job's own script, with a stand-in gh that writes down what it's asked
# to do with issues.
awk '/^        run: \|$/ { on = 1; next } on { sub(/^          /, ""); print }' <<<"$left" >"$work/left-out.sh"
mkdir "$work/issues-bin"
cat >"$work/issues-bin/gh" <<'GH'
#!/bin/bash
echo "$1 $2" >>"$ISSUES/calls"
case "$1 $2" in
  "issue list") cat "$ISSUES/open" ;;
  "issue view") cat "$ISSUES/said" ;;
esac
GH
chmod +x "$work/issues-bin/gh"
export ISSUES="$work/issues"
mkdir "$ISSUES"
# issues [<open issues, as JSON>] [<what the open issue says already>]
issues() {
  echo "${1:-[]}" >"$ISSUES/open"
  echo "${2:-}" >"$ISSUES/said"
  : >"$ISSUES/calls"
}
left_out_job() {
  (cd "$ISSUES" && env PATH="$work/issues-bin:$PATH" GITHUB_REPOSITORY=someone/agentv-pkgs GITHUB_STEP_SUMMARY=/dev/null \
    RUN=https://example.invalid/run REFUSED="$1" bash -e "$work/left-out.sh")
}
fails_having() {
  local refused=$1 call
  shift
  if left_out_job "$refused"; then echo "the job passed"; return 1; fi
  for call in "$@"; do
    case $call in
      no:*) ! grep -qxF "issue ${call#no:}" "$ISSUES/calls" || { echo "it did: issue ${call#no:}"; return 1; } ;;
      *) grep -qxF "issue $call" "$ISSUES/calls" || { echo "it didn't: issue $call"; return 1; } ;;
    esac
  done
}
passes_having() {
  local call
  left_out_job '[]' || return 1
  for call in "$@"; do
    case $call in
      no:*) ! grep -qxF "issue ${call#no:}" "$ISSUES/calls" || { echo "it did: issue ${call#no:}"; return 1; } ;;
      *) grep -qxF "issue $call" "$ISSUES/calls" || { echo "it didn't: issue $call"; return 1; } ;;
    esac
  done
}
why="agentv-os's agentv branch doesn't have tag=agentv-v1.0.0 (cccc), so it isn't built, signed or published."
refused=$(jq -cn --arg why "$why" '[$why]')
open='[{"number": 8, "title": "The build left something out, and more"}, {"number": 7, "title": "The build left something out"}]'

issues
check "with nothing left out the job passes, and opens no issue" passes_having no:create no:close
issues "$open"
check "with nothing left out, an issue from before is closed" passes_having close no:create
issues
check "with something left out the job fails, and opens an issue" fails_having "$refused" create no:comment
check "which says what was left out and why" grep -qxF -- "- $why" "$ISSUES/body.md"
issues "$open"
check "with an issue open already, it adds to that one" fails_having "$refused" comment no:create
issues "$open" "- $why"
check "and says each thing once, not again every hour" fails_having "$refused" no:comment no:create

(( failures == 0 )) || { echo "$failures failed" >&2; exit 1; }
echo "all passed"
