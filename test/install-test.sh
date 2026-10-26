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
# Node runs agentv app validate and agentv app list. agentv installs here
# without its dependencies (below), so it comes on its own, as Omarchy's
# base brings it on a box.
arch_container_setup gnupg nodejs

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

# From stage 2 on: the app contract and its validator ship together.
if [[ -f /usr/bin/agentv-app-validate ]]; then
  for file in /usr/share/agentv/apps/package.json /usr/share/agentv/apps/contract/contract.ts \
    /usr/share/agentv/apps/contract/manifest.ts /usr/share/agentv/apps/contract/validate.ts; do
    [[ -f $file ]] || fail "the app contract ships whole: $file is missing"
  done
  status=0
  agentv app validate >/dev/null 2>&1 || status=$?
  (( status == 2 )) || fail "agentv app validate runs on the box (it exited $status, not 2 for no package)"
  pass "the app contract ships whole, and agentv app validate runs"
fi

# From stage 2 on: the app installer ships with the contract, and knows where
# the signed app index lives.
if [[ -f /usr/bin/agentv-app-install ]]; then
  for file in /usr/share/agentv/daemon/apps/index.ts /usr/share/agentv/daemon/apps/install.ts \
    /usr/share/agentv/daemon/apps/cli.ts /usr/bin/agentv-app-list /usr/bin/agentv-app-remove; do
    [[ -f $file ]] || fail "the app installer ships whole: $file is missing"
  done
  # Releases up to v0.1.2 were built before the index moved to agentv-apps
  # (ADR-036), and a published version keeps its exact file.
  index=agentv-apps
  if [[ $version != *.r* ]] && (( $(vercmp "$version" 0.1.2) <= 0 )); then
    index=agentv-index
  fi
  grep -q "^AGENTV_INDEX_URL=https://github.com/.*/$index/releases/download/index\$" /usr/share/agentv/settings ||
    fail "the package says where the app index lives ($index)"
  [[ -z $(agentv app list) ]] || fail "a new box has no apps installed"
  pass "the app installer ships whole, and knows where the app index lives"
fi

# From stage 3 on: the built-in apps ship whole and pass the app contract's
# checks as AgenTV's own, and the package names AgenTV's address for the
# User-Agent its apps' requests carry.
if [[ -d /usr/share/agentv/apps/builtin ]]; then
  for app in agentv.clock agentv.weather agentv.music; do
    for file in manifest.json app.ts icon.svg; do
      [[ -f /usr/share/agentv/apps/builtin/$app/$file ]] || fail "the built-in apps ship whole: $app/$file is missing"
    done
  done
  [[ -f /usr/share/agentv/apps/builtin/agentv.weather/met.ts && -f /usr/share/agentv/daemon/place.ts ]] ||
    fail "the weather ships whole, with what it reads MET's forecast and the box's place with"
  [[ -f /usr/share/agentv/daemon/music.ts && -f /usr/share/agentv/daemon/storage.ts && -x /usr/bin/agentv-music ]] ||
    fail "Music ships whole, with its library, its player, its storage layer and agentv music"
  [[ ! -e /usr/share/agentv/apps/builtin/agentv.weather/fixtures ]] || fail "an app's fixtures don't ship to the box"
  agentv app validate --official /usr/share/agentv/apps/builtin/* >/dev/null ||
    fail "the built-in apps pass the app contract's checks"
  grep -q '^AGENTV_HOMEPAGE=https://' /usr/share/agentv/settings || fail "the package names AgenTV's address"
  pass "the built-in apps ship whole and pass the contract's checks, and the package names AgenTV's address"
fi

# From stage 2 on: the home screen ships with its sounds, their own licence,
# and the template and hook that give it the Omarchy theme's colours.
if [[ -f /usr/share/agentv/launcher/index.html ]]; then
  for file in /usr/share/agentv/launcher/package.json /usr/share/agentv/launcher/main.ts \
    /usr/share/agentv/launcher/launcher.css /usr/share/agentv/launcher/motion.css /usr/share/agentv/launcher/pages/home.ts \
    /usr/share/agentv/config/omarchy/themed/launcher.css.tpl /usr/share/agentv/config/omarchy/hooks/theme-set.d/agentv \
    /usr/bin/agentv-theme-sync /usr/lib/systemd/user/agentv-theme.service /usr/share/licenses/agentv/sounds; do
    [[ -f $file ]] || fail "the home screen ships whole: $file is missing"
  done
  for sound in move select forward back confirm success failure; do
    [[ -f /usr/share/agentv/launcher/sounds/$sound.ogg ]] || fail "the home screen ships whole: the $sound sound is missing"
  done
  pass "the home screen ships whole, with its sounds, their licence and the theme's template"
fi

# From stage 4 on: the daemon serves the phone companion's page, so it ships
# with the daemon that pairs phones.
if [[ -f /usr/share/agentv/daemon/phones.ts ]]; then
  for file in index.html companion.css main.ts; do
    [[ -f /usr/share/agentv/companion-web/$file ]] || fail "the phone companion ships whole: companion-web/$file is missing"
  done
  pass "the phone companion's page ships with the daemon"
fi

# From stage 2 on: wake-on-LAN for every wired connection (ADR-031).
if [[ -f /usr/share/agentv/daemon/tv-power.ts ]]; then
  grep -qx 'ethernet.wake-on-lan=64' /usr/lib/NetworkManager/conf.d/90-agentv-wol.conf ||
    fail "wired connections get wake-on-LAN"
  pass "wired connections get wake-on-LAN"
fi

# From stage 2 on: the daily update check is enabled, the install from the TV
# isn't (the TV starts it), and polkit lets the TV start the two.
if [[ -f /usr/lib/systemd/system/agentv-update-check.timer ]]; then
  [[ -L /usr/lib/systemd/system/timers.target.wants/agentv-update-check.timer ]] ||
    fail "the daily update check is enabled"
  [[ ! -e /usr/lib/systemd/system/multi-user.target.wants/agentv-update-tv.service ]] ||
    fail "an update from the TV only runs when the TV starts it"
  [[ -L /usr/lib/systemd/system/multi-user.target.wants/agentv-daemon.service ]] ||
    fail "AgenTV's daemon is still enabled"
  grep -q 'agentv-update-tv.service' /usr/share/polkit-1/rules.d/50-agentv-update.rules ||
    fail "polkit lets the TV start an update"
  pass "the daily update check is enabled, and the TV may start an update"
fi

# From stage 4 on: the provider key's hand-over is enabled, and the move as
# root only runs when the daemon leaves a key (S4.6).
if [[ -f /usr/bin/agentv-key-store ]]; then
  [[ -L /usr/lib/systemd/system/paths.target.wants/agentv-key.path ]] ||
    fail "the provider key's hand-over is enabled"
  [[ -f /usr/lib/systemd/system/agentv-key.service ]] || fail "the move as root is there"
  if compgen -G "/usr/lib/systemd/system/*.wants/agentv-key.service" >/dev/null; then
    fail "the move as root only runs when the daemon leaves a key"
  fi
  pass "the provider key's hand-over is enabled, and the move as root waits for a key"
fi

# From stage 4 on: the setup hotspot opens on first boot only when it's
# needed, its hand-over to root is enabled, and the package names dnsmasq to
# hand phones their addresses. agentv went in without its dependencies, so
# this reads what it depends on from pacman's own record of it.
if [[ -f /usr/bin/agentv-hotspot ]]; then
  [[ -L /usr/lib/systemd/system/multi-user.target.wants/agentv-hotspot-boot.service ]] ||
    fail "the setup hotspot's first-boot check is enabled"
  [[ -L /usr/lib/systemd/system/paths.target.wants/agentv-hotspot.path ]] ||
    fail "the setup hotspot's hand-over is enabled"
  if compgen -G "/usr/lib/systemd/system/*.wants/agentv-hotspot.service" >/dev/null; then
    fail "the setup hotspot itself only opens when asked"
  fi
  sed -n '/^%DEPENDS%$/,/^$/p' "/var/lib/pacman/local/agentv-$version-1/desc" | grep -qx dnsmasq ||
    fail "the package depends on dnsmasq"
  [[ -f /usr/share/agentv/companion-web/setup.html && -f /usr/share/agentv/companion-web/setup.ts ]] ||
    fail "the captive page ships with the daemon"
  pass "the setup hotspot opens only when it's needed, with dnsmasq named and its captive page"
fi

# From stage 3's NAS shares on (ADR-038): the hand-over to root is enabled,
# the shares mount at boot, the drop folder lets anyone add a request and
# only root read one, and the package names cifs-utils for mount.cifs.
if [[ -f /usr/bin/agentv-share-store ]]; then
  [[ -L /usr/lib/systemd/system/paths.target.wants/agentv-share.path ]] ||
    fail "the NAS share hand-over is enabled"
  [[ -L /usr/lib/systemd/system/multi-user.target.wants/agentv-shares.service ]] ||
    fail "the NAS shares mount at boot"
  if compgen -G "/usr/lib/systemd/system/*.wants/agentv-share.service" >/dev/null; then
    fail "the mount as root only runs when Music leaves a request"
  fi
  [[ -f /usr/lib/tmpfiles.d/agentv-shares.conf ]] || fail "the drop folder's tmpfiles entry is in the package"
  systemd-tmpfiles --create /usr/lib/tmpfiles.d/agentv-shares.conf
  [[ $(stat -c '%a %U' /var/lib/agentv/share-drop) == "1733 root" ]] ||
    fail "the drop folder lets anyone add a request and only root read one"
  sed -n '/^%DEPENDS%$/,/^$/p' "/var/lib/pacman/local/agentv-$version-1/desc" | grep -qx cifs-utils ||
    fail "the package depends on cifs-utils"
  pass "a NAS share's hand-over to root is enabled, its drop folder is root's to read, and cifs-utils is named"
fi

# Every module AgenTV's TypeScript imports is in the package: the daemon and
# the home screen import each other's files, and a missing one only shows
# when the daemon starts or the TV draws the page.
while IFS= read -r file; do
  while IFS= read -r module; do
    [[ -f $(dirname "$file")/$module ]] || fail "${file#/usr/share/agentv/} imports $module, which the package doesn't have"
  done < <(grep -oE "from \"\.\.?/[^\"]+\"" "$file" | sed -E 's/^from "(.*)"$/\1/')
done < <(find /usr/share/agentv -name '*.ts' -not -path '*/node_modules/*')
pass "every module AgenTV's TypeScript imports is in the package"

# Every AgenTV file a system unit runs is in the package, so a unit never
# points at a file an older package had, as the daemon's once pointed at the
# stage 0 placeholder.
for unit in /usr/lib/systemd/system/agentv-*.service; do
  while IFS= read -r file; do
    [[ -f $file ]] || fail "${unit##*/} runs $file, which the package doesn't have"
  done < <(grep -o '/usr/share/agentv/[^ ]*' "$unit")
done
pass "every AgenTV file a system unit runs is in the package"

[[ ! -e /usr/bin/agentv-check ]] || fail "the developers' gate isn't on the box"
pass "the developers' gate isn't on the box"

# What Omarchy does to pacman.conf, then what AgenTV does about it.
cp /etc/pacman.conf.arch /etc/pacman.conf
agentv-pacman-conf >/dev/null
agentv-pacman-conf --check >/dev/null || fail "agentv-pacman-conf puts the repository back"
pacman -Sy >/dev/null || fail "the repository line agentv-pacman-conf writes works"
pacman -Si agentv >/dev/null || fail "the repository line agentv-pacman-conf writes works"
pass "the repository line agentv-pacman-conf writes works"
