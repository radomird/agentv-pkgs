# agentv-pkgs

The pacman packages for AgenTV, the world's first open-source agentic TV OS. Powered by [Omarchy](https://omarchy.org).

A box keeps Omarchy's `omarchy` package exactly as Omarchy ships it. AgenTV comes as three packages of its own beside it:

- **`agentv`** has everything AgenTV adds: the `agentv` command, its migrations and its hooks into Omarchy's update. Nothing of it goes into `/usr/share/omarchy/`, which belongs to Omarchy.
- **`agentv-keyring`** has the public key the packages are signed with.
- **`agentv-voice`** has [Piper](https://github.com/rhasspy/piper) and its cori voice, so the TV can say its answers aloud from its first boot when your AI provider has no voice of its own (coming soon). Piper is MIT, the cori voice is public domain, and the espeak-ng library that comes with Piper is GPL-3.0.

That way `agentv update`, which runs `omarchy update` underneath, moves Arch, Omarchy and AgenTV in one go, with one snapshot first.

## Channels

CI builds the packages from [agentv-os](https://github.com/radomird/agentv-os), signs them and publishes a pacman repository as a release here, one per channel:

- **stable** has AgenTV's releases. Every box is on it.
- **edge** has every commit of agentv-os that passes its checks. It's for development.

There's nothing to download by hand. The ISO will put the packages on a new box (coming soon). After that, pacman fetches updates from here.

## How it's built

- `agentv/PKGBUILD`, `agentv-keyring/PKGBUILD` and `agentv-voice/PKGBUILD` are the recipes. `agentv-voice` is built once per version of Piper, not with every commit of agentv-os.
- `.github/workflows/build.yml` looks for a new release tag or a new green commit every hour. It builds in an Arch container, signs, publishes, then installs from the release with pacman, checking every signature on the way.
- The signing key is a GitHub Actions secret, and it never leaves CI. Its public half is `agentv-keyring/agentv.gpg`.
- A version that's published keeps its exact file, so a box never sees two different files for one version.

## License

MIT, like Omarchy. AgenTV isn't made or endorsed by the Omarchy project.
