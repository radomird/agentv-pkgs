# agentv-pkgs

The packages your AgenTV box installs and updates from. AgenTV is the world's first open-source agentic TV OS. Powered by [Omarchy](https://omarchy.org).

There's nothing to download here by hand. The ISO puts the packages on a new box, and after that your box keeps itself up to date from here.

## What's in it

Your box keeps Omarchy's own `omarchy` package exactly as Omarchy ships it. AgenTV adds two packages next to it:

- **`agentv`** is everything AgenTV adds: the `agentv` command, its migrations, and its hooks into Omarchy's updates. None of it goes into `/usr/share/omarchy/`, which is Omarchy's.
- **`agentv-keyring`** holds the public key the packages are signed with.

That way one `agentv update` (it runs `omarchy update` underneath) updates Arch, Omarchy and AgenTV together, with one snapshot first.

## Stable and edge

CI builds the packages from [agentv-os](https://github.com/radomird/agentv-os), signs them, and publishes a pacman repository here as a release, one for each channel:

- **stable** has AgenTV's releases. Every box starts on it.
- **edge** has every agentv-os commit that passes its checks. It's for development.

## For developers

- `agentv/PKGBUILD` and `agentv-keyring/PKGBUILD` are the recipes.
- Every hour, `.github/workflows/build.yml` looks for a new release tag or a new green commit. It builds in an Arch container, signs, publishes, and then installs from the release with pacman, checking every signature on the way.
- The signing key is a GitHub Actions secret and never leaves CI. Only the job that signs gets it, and that job builds nothing: it takes the built files, checks them and runs `bin/sign`. Its public half is `agentv-keyring/agentv.gpg`.
- A pull request's test run never gets that key. It signs its packages with a throwaway key made for the run (`bin/test-key`), which only the run's own test box trusts.
- Once a version is published, its file never changes, so your box never sees two different files with the same version.

## License

MIT, like Omarchy. AgenTV isn't made or endorsed by the Omarchy project.
