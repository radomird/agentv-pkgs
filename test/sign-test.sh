#!/bin/bash

# Checks how packages get signed, without building any: bin/test-key's
# throwaway key, bin/test-keyring's keyring for a test run, and bin/sign on a
# stand-in repository. It needs gpg and nothing from the network. Also reads
# the build workflow, to see that only its signing job is given the key.
#
# Usage: test/sign-test.sh

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
refuses() {
  local name=$1
  shift
  if "$@" >"$work/check.log" 2>&1; then
    sed 's/^/    /' "$work/check.log" >&2
    fail "$name"
  else pass "$name"; fi
}

release=$(cut -d: -f1 "$ROOT/agentv-keyring/agentv-trusted")

# A repository the way bin/build leaves it: packages, databases and
# release.json, none of them signed.
new_repo() {
  rm -rf "$1"
  mkdir -p "$1"
  for file in agentv-0.9.0-1-any.pkg.tar.zst agentv-keyring-20261022-1-any.pkg.tar.zst agentv-voice-1.2.0-1-x86_64.pkg.tar.zst \
    agentv.db.tar.gz agentv.files.tar.gz; do
    printf 'stand-in for %s\n' "$file" >"$1/$file"
  done
  cp "$1/agentv.db.tar.gz" "$1/agentv.db"
  cp "$1/agentv.files.tar.gz" "$1/agentv.files"
  printf '{"version": "0.9.0"}\n' >"$1/release.json"
}

# --- bin/test-key ------------------------------------------------------------

check "bin/test-key makes a key" "$ROOT/bin/test-key" "$work/key"
check "it leaves the key, its public half and its fingerprint" \
  test -s "$work/key/secret.asc" -a -s "$work/key/public.asc" -a -s "$work/key/fingerprint"
test_fpr=$(cat "$work/key/fingerprint")
check "the key isn't AgenTV's own" test "$test_fpr" != "$release"
check "only its owner can read the key" test "$(stat -c %a "$work/key/secret.asc")" = 600
expires=$(gpg --batch --with-colons --show-keys "$work/key/public.asc" | awk -F: '$1 == "pub" { print $7 }')
now=$(date +%s)
check "the key stops working within a day" test -n "$expires" -a "${expires:-0}" -gt "$now" -a "${expires:-0}" -le $(( now + 86400 + 60 ))
"$ROOT/bin/test-key" "$work/other" >/dev/null
check "every run gets a key of its own" test "$(cat "$work/other/fingerprint")" != "$test_fpr"

# --- bin/test-keyring --------------------------------------------------------

cp -r "$ROOT/agentv-keyring" "$work/keyring"
check "bin/test-keyring adds the run's key to a copy of the keyring" "$ROOT/bin/test-keyring" "$work/keyring" "$work/key/public.asc"
listed=$(gpg --batch --with-colons --show-keys "$work/keyring/agentv.gpg" | awk -F: '$1 == "pub" { want = 1 } want && $1 == "fpr" { print $10; want = 0 }' | sort | paste -sd' ')
check "the copy's agentv.gpg holds AgenTV's key and the run's, and no other" \
  test "$listed" = "$(printf '%s\n' "$release" "$test_fpr" | sort | paste -sd' ')"
check "the copy's agentv-trusted names both" \
  test "$(paste -sd' ' "$work/keyring/agentv-trusted")" = "$release:4: $test_fpr:4:"
# The check the Check workflow runs on the real folder.
check "the copy's PKGBUILD has the new files' checksums" \
  bash -c "cd '$work/keyring' && sha256sum -c <(sed -n \"s/^  '\\([0-9a-f]\\{64\\}\\)'  # \\(.*\\)\$/\\1  \\2/p\" PKGBUILD)"
check "the keyring in the repo is still AgenTV's key alone" \
  test "$(cat "$ROOT/agentv-keyring/agentv-trusted")" = "$release:4:"
refuses "the same key isn't added twice" "$ROOT/bin/test-keyring" "$work/keyring" "$work/key/public.asc"
cat "$work/key/public.asc" "$work/other/public.asc" >"$work/two.asc"
cp -r "$ROOT/agentv-keyring" "$work/keyring-two"
refuses "a file with two keys isn't a throwaway key" "$ROOT/bin/test-keyring" "$work/keyring-two" "$work/two.asc"

# --- bin/sign ----------------------------------------------------------------

# gpgv, but it writes down whether the key was still in its environment.
mkdir "$work/bin"
real_gpgv=$(type -P gpgv)
cat >"$work/bin/gpgv" <<STANDIN
#!/bin/bash
echo "\${AGENTV_SIGNING_KEY:+leaked}" >>"$work/gpgv-env"
exec "$real_gpgv" "\$@"
STANDIN
chmod +x "$work/bin/gpgv"

gpg --batch --quiet --yes --dearmor --output "$work/test.gpg" "$work/key/public.asc"
signed_by_test_key() {
  gpgv --quiet --keyring "$work/test.gpg" "$1.sig" "$1" 2>/dev/null
}

new_repo "$work/repo"
: >"$work/gpgv-env"
check "bin/sign signs a test run's repository with the run's key" \
  env PATH="$work/bin:$PATH" AGENTV_SIGNING_KEY="$(cat "$work/key/secret.asc")" AGENTV_TEST_KEY="$work/key/public.asc" "$ROOT/bin/sign" "$work/repo"
for file in agentv-0.9.0-1-any.pkg.tar.zst agentv-keyring-20261022-1-any.pkg.tar.zst agentv-voice-1.2.0-1-x86_64.pkg.tar.zst \
  agentv.db.tar.gz agentv.files.tar.gz agentv.db agentv.files release.json; do
  check "$file has a good signature" signed_by_test_key "$work/repo/$file"
done
check "the key was out of the environment before anything else ran" \
  bash -c "test -s '$work/gpgv-env' && ! grep -q leaked '$work/gpgv-env'"
check "it leaves no keyring behind" bash -c "! compgen -G '$work/repo/*gnupg*' && ! compgen -G '$work/repo/*.asc'"

# A package that's published already keeps its exact signature.
cp "$work/repo/agentv-voice-1.2.0-1-x86_64.pkg.tar.zst.sig" "$work/kept.sig"
rm "$work/repo/agentv-0.9.0-1-any.pkg.tar.zst.sig"
AGENTV_SIGNING_KEY="$(cat "$work/key/secret.asc")" AGENTV_TEST_KEY="$work/key/public.asc" "$ROOT/bin/sign" "$work/repo" >/dev/null
check "a package that has its signature keeps it, byte for byte" cmp "$work/kept.sig" "$work/repo/agentv-voice-1.2.0-1-x86_64.pkg.tar.zst.sig"
check "and one without gets one" signed_by_test_key "$work/repo/agentv-0.9.0-1-any.pkg.tar.zst"

# A kept signature that isn't the signing key's stops the run.
new_repo "$work/repo"
gpg --batch --quiet --homedir "$(mkdir -m 700 "$work/other-home" && echo "$work/other-home")" --import "$work/other/secret.asc"
gpg --batch --quiet --homedir "$work/other-home" --detach-sign --output "$work/repo/agentv-0.9.0-1-any.pkg.tar.zst.sig" "$work/repo/agentv-0.9.0-1-any.pkg.tar.zst"
refuses "a kept package signed by another key stops it" \
  env AGENTV_SIGNING_KEY="$(cat "$work/key/secret.asc")" AGENTV_TEST_KEY="$work/key/public.asc" "$ROOT/bin/sign" "$work/repo"

nothing_signed() {
  ! compgen -G "$1/*.sig" >/dev/null
}

new_repo "$work/repo"
refuses "without the key it stops" env -u AGENTV_SIGNING_KEY "$ROOT/bin/sign" "$work/repo"
check "and signs nothing" nothing_signed "$work/repo"

# A release run doesn't set AGENTV_TEST_KEY, so only AgenTV's own key signs.
refuses "a throwaway key can't sign a release" env AGENTV_SIGNING_KEY="$(cat "$work/key/secret.asc")" "$ROOT/bin/sign" "$work/repo"
check "and signs nothing" nothing_signed "$work/repo"

refuses "a test run signs only with the key its keyring was built with" \
  env AGENTV_SIGNING_KEY="$(cat "$work/other/secret.asc")" AGENTV_TEST_KEY="$work/key/public.asc" "$ROOT/bin/sign" "$work/repo"
check "and signs nothing" nothing_signed "$work/repo"

refuses "two keys in the secret stop it" \
  env AGENTV_SIGNING_KEY="$(cat "$work/key/secret.asc" "$work/other/secret.asc")" AGENTV_TEST_KEY="$work/key/public.asc" "$ROOT/bin/sign" "$work/repo"

rm "$work/repo/release.json"
refuses "a repository bin/build didn't finish isn't signed" \
  env AGENTV_SIGNING_KEY="$(cat "$work/key/secret.asc")" AGENTV_TEST_KEY="$work/key/public.asc" "$ROOT/bin/sign" "$work/repo"

# --- The build workflow ------------------------------------------------------

workflow="$ROOT/.github/workflows/build.yml"
# Each job's name, and whether it reads the key or names an environment.
jobs_with() {
  awk -v want="$1" '
    /^jobs:/ { jobs = 1; next }
    jobs && /^  [a-z][a-z0-9-]*:$/ { job = $1; sub(":", "", job) }
    jobs && index($0, want) && $0 !~ /^ *#/ { print job }
  ' "$workflow" | sort -u | paste -sd' '
}
check "only the signing job is given the key" test "$(jobs_with 'secrets.AGENTV_SIGNING_KEY')" = "sign"
check "and it takes it from the release environment" test "$(jobs_with 'environment: release')" = "sign"
check "the build never gets it" bash -c "! grep -n 'AGENTV_SIGNING_KEY' '$ROOT/bin/arch-container-setup' '$ROOT/test/install-test.sh'"
# The job that signs runs bin/sign and nothing that builds or fetches.
sign_job=$(awk '/^  sign:$/ { on = 1; next } on && /^  [a-z][a-z0-9-]*:$/ { on = 0 } on' "$workflow")
check "the workflow has a signing job" test -n "$sign_job"
refuses "the signing job runs no container, package manager or download" \
  grep -nE 'docker |pacman|makepkg|curl |git (fetch|clone)|gh release|apt-get' <<<"$sign_job"

(( failures == 0 )) || { echo "$failures failed" >&2; exit 1; }
echo "all passed"
