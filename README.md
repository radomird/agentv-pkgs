# agentv-pkgs

The packages your [AgenTV](https://github.com/radomird/agentv-os) box installs and updates from. AgenTV is the world's first open-source agentic TV OS. Powered by [Omarchy](https://omarchy.org).

There's nothing to download here by hand. The USB stick puts the packages on a new box, and after that your box keeps itself up to date from here.

## What's in it

Your box keeps Omarchy's own `omarchy` package exactly as Omarchy ships it. AgenTV adds two packages next to it:

- **`agentv`** is everything AgenTV adds on top of Omarchy: the TV's home, setup, the phone remote and the `agentv` command. None of it goes into `/usr/share/omarchy/`, which is Omarchy's.
- **`agentv-keyring`** holds the public key the packages are signed with.

That way one update brings Arch, Omarchy and AgenTV along together, and your box takes a snapshot first so you can go back. On the TV it's _Settings > System > Updates_. In a terminal it's `agentv update`, which runs `omarchy update` underneath.

## Stable and edge

CI builds the packages from [agentv-os](https://github.com/radomird/agentv-os), signs them, and publishes a pacman repository here as a release, one for each channel:

- **stable** has AgenTV's releases. A box installed from a release's ISO starts on it.
- **edge** has every agentv-os commit that passes its checks. It's for trying what's next. A box installed from a release candidate's ISO, or from edge's, starts on it.

A release candidate has no packages of its own. Its ISO carries edge's, from the commit it was cut on.

To try edge, run `agentv channel edge` and then `agentv update`. `agentv channel stable` takes you back, and your box picks up releases again from the next one.

## Something went wrong?

If an update didn't go right, [tell me what happened](https://github.com/radomird/agentv-pkgs/issues/new/choose). For a security problem, such as a package that isn't what it says it is, please [tell me privately](https://github.com/radomird/agentv-pkgs/security/advisories/new) first.

## For developers

- `agentv/PKGBUILD` and `agentv-keyring/PKGBUILD` are the recipes.
- Every hour, `.github/workflows/build.yml` looks for a new release tag or a new green commit. It builds in an Arch container, signs, publishes, and then installs from the release with pacman, checking every signature on the way.
- The signing key is a GitHub Actions secret and never leaves CI. Only the job that signs gets it, and that job builds nothing: it takes the built files, checks them and runs `bin/sign`. Its public half is `agentv-keyring/agentv.gpg`.
- A pull request's test run never gets that key. It signs its packages with a throwaway key made for the run (`bin/test-key`), which only the run's own test box trusts.
- Once a version is published, its file never changes, so your box never sees two different files with the same version.

## License

MIT, like Omarchy. The `agentv` package also carries AgenTV's menu sounds and setup music, which are all rights reserved, and fonts under the SIL Open Font License. Each keeps its licence file in the package. AgenTV isn't made or endorsed by the Omarchy project.
