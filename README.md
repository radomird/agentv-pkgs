# agentv-pkgs

The packages your AgenTV box installs and updates from. AgenTV is the world's first open-source agentic TV OS. Powered by [Omarchy](https://omarchy.org).

There's nothing to download here by hand. The ISO puts the packages on a new box, and after that your box keeps itself up to date from here.

## What's in it

Your box keeps Omarchy's own `omarchy` package exactly as Omarchy ships it. AgenTV adds three packages next to it:

- **`agentv`** is everything AgenTV adds: the `agentv` command, its migrations, and its hooks into Omarchy's updates. None of it goes into `/usr/share/omarchy/`, which is Omarchy's.
- **`agentv-keyring`** holds the public key the packages are signed with.
- **`agentv-voice`** is [Piper](https://github.com/rhasspy/piper) and its cori voice, so the TV can say its answers out loud from its first boot when your AI provider has no voice of its own (coming soon). Piper is MIT, the cori voice is public domain, and the espeak-ng library that comes with Piper is GPL-3.0.

That way one `agentv update` (it runs `omarchy update` underneath) updates Arch, Omarchy and AgenTV together, with one snapshot first.

## Stable and edge

CI builds the packages from [agentv-os](https://github.com/radomird/agentv-os), signs them, and publishes a pacman repository here as a release, one for each channel:

- **stable** has AgenTV's releases. Every box starts on it.
- **edge** has every agentv-os commit that passes its checks. It's for development.

## For developers

- `agentv/PKGBUILD`, `agentv-keyring/PKGBUILD` and `agentv-voice/PKGBUILD` are the recipes. `agentv-voice` is only rebuilt when Piper's version changes, not with every agentv-os commit.
- Every hour, `.github/workflows/build.yml` looks for a new release tag or a new green commit. It builds in an Arch container, signs, publishes, and then installs from the release with pacman, checking every signature on the way.
- The signing key is a GitHub Actions secret and never leaves CI. Its public half is `agentv-keyring/agentv.gpg`.
- Once a version is published, its file never changes, so your box never sees two different files with the same version.

## License

MIT, like Omarchy. AgenTV isn't made or endorsed by the Omarchy project.
