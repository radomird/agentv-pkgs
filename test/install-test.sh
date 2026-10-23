#!/bin/bash

# Installs AgenTV's packages from the published release the way a box does:
# pacman trusts only AgenTV's key, the database and every package must be
# signed by it, the keyring package hands that trust on, and agentv's own
# agentv-pacman-conf writes a repository line that works. Runs as root in a
# fresh Arch container, after bin/publish.
#
# Usage: test/install-test.sh <channel> <expected agentv version>
# Needs: AGENTV_REPO_URL

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
channel="${1:?usage: test/install-test.sh <channel> <version>}"
version="${2:?usage: test/install-test.sh <channel> <version>}"
: "${AGENTV_REPO_URL:?}"

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

fpr=$(cut -d: -f1 "$ROOT/agentv-keyring/agentv-trusted")

# shellcheck source=bin/arch-container-setup
source "$ROOT/bin/arch-container-setup"
arch_container_setup gnupg

pacman-key --init >/dev/null 2>&1
pacman-key --add "$ROOT/agentv-keyring/agentv.gpg" >/dev/null 2>&1
pacman-key --lsign-key "$fpr" >/dev/null 2>&1

# Between agentv-pacman-conf's own markers, so the package's install script
# replaces this section rather than adding a second one. DatabaseRequired
# here makes the first sync prove the database is signed.
cp /etc/pacman.conf /etc/pacman.conf.arch
cat >>/etc/pacman.conf <<CONF

# BEGIN agentv: added by agentv-pacman-conf, kept at the end
[agentv]
SigLevel = Required DatabaseRequired
Server = $AGENTV_REPO_URL/$channel
# END agentv
CONF

pacman -Sy >/dev/null || fail "the $channel database downloads and its signature checks out"
pass "the $channel database downloads and its signature checks out"

# --nodeps twice: Omarchy's own package isn't in a plain Arch container, and
# this checks AgenTV's packages, not Omarchy's.
pacman -S --noconfirm --nodeps --nodeps agentv-keyring agentv >/dev/null ||
  fail "agentv and agentv-keyring install with their signatures checked"
pass "agentv and agentv-keyring install with their signatures checked"

pacman-key --list-keys "$fpr" >/dev/null 2>&1 || fail "agentv-keyring puts AgenTV's key in pacman's keyring"
pass "agentv-keyring puts AgenTV's key in pacman's keyring"

installed=$(pacman -Q agentv | cut -d' ' -f2)
[[ $installed == "$version-1" ]] || fail "the installed agentv is $version (got $installed)"
pass "the installed agentv is $version"

output=$(agentv version)
[[ $output == "AgenTV $version ($channel)"* ]] || fail "agentv version names the version and channel (got: $output)"
pass "agentv version names the version and channel"

[[ -f /usr/share/agentv/config/omarchy/hooks/post-update.d/agentv &&
  -f /etc/skel/.config/omarchy/hooks/post-update.d/agentv ]] || fail "the post-update hook ships for new and existing users"
pass "the post-update hook ships for new and existing users"

# From stage 1 on: the TV session ships whole, or not at all (ADR-031).
if [[ -f /usr/share/agentv/session/hypr.lua ]]; then
  for file in /usr/share/wayland-sessions/agentv.desktop /usr/bin/agentv-session \
    /usr/lib/systemd/user/agentv-tv.target /usr/lib/systemd/user/agentv-screen.service \
    /usr/lib/systemd/user/agentv-input.service /usr/lib/systemd/user/agentv-toast.service \
    /usr/lib/udev/rules.d/70-agentv-uinput.rules /usr/share/agentv/daemon/screen.ts \
    /usr/share/agentv/daemon/package.json /usr/share/agentv/daemon/input.py /usr/share/agentv/session/toast/shell.qml; do
    [[ -f $file ]] || fail "the TV session ships whole: $file is missing"
  done
  [[ ! -e /usr/lib/systemd/system/multi-user.target.wants/agentv-screen.service ]] ||
    fail "the TV session's units are the owner's, not the system's"
  pass "the TV session ships whole: its entry, its Hyprland setup, its units and its daemon"
fi

[[ ! -e /usr/bin/agentv-check ]] || fail "the developers' gate isn't on the box"
pass "the developers' gate isn't on the box"

# What Omarchy does to pacman.conf, then what AgenTV does about it.
cp /etc/pacman.conf.arch /etc/pacman.conf
agentv-pacman-conf >/dev/null
agentv-pacman-conf --check >/dev/null || fail "agentv-pacman-conf puts the repository back"
pacman -Sy >/dev/null || fail "the repository line agentv-pacman-conf writes works"
pacman -Si agentv >/dev/null || fail "the repository line agentv-pacman-conf writes works"
pass "the repository line agentv-pacman-conf writes works"
