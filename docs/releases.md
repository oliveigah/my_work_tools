# Releases

MWT's packages are built and published by GitHub Actions on
`oliveigah/my_work_tools`, and the installed app updates itself from them.

## What a release holds

Publishing a GitHub release whose tag is a version (`1.2.3` or `v1.2.3`) runs
`.github/workflows/linux-packages.yml`. It builds `MWT_<version>.deb` and
`MWT_<version>.rpm` from the tag and attaches them with:

- `SHA256SUMS`: the SHA-256 of each package;
- `SHA256SUMS.sig`: the Ed25519 signature of `SHA256SUMS`, by the release key.

The workflow refuses to publish when the `RELEASE_SIGNING_KEY` secret is
missing, or when its signature doesn't verify with the public key committed at
the tag (`priv/release_signing_key.pub`).

## How MWT updates itself

`MWTClient.Updates`, in the installed desktop app only (a `.deb` or `.rpm`
install on x86-64):

1. It asks `https://api.github.com/repos/oliveigah/my_work_tools/releases/latest`
   a minute after it starts, once a day after that, and when you choose
   **Check for updates** in the settings menu (or **Update** on the sign-in
   screen). The quiet checks say nothing unless there is a newer MWT, and not
   again for a version you dismissed.
2. A newer release is offered when it has this install's package, `SHA256SUMS`
   and `SHA256SUMS.sig`, all downloaded from that repository's releases.
3. **Install** downloads the three into a folder only you can open, and
   installs the package only when the signature verifies with the key MWT was
   built with, the package matches its line in `SHA256SUMS`, and the package
   is `mwt` at the release's version. pkexec then asks for your password.

An MWT built without `priv/release_signing_key.pub` checks no release.
**Install from a file…** (the arrow icon on the sign-in screen) still installs
a package you downloaded yourself, for that build or any other.

## The signing key

Once, on your own machine, from a checkout of the repository:

```bash
./scripts/release-signing-key.sh
```

It writes the private key to `~/.config/mwt/release-signing-key.pem` (or the
path you pass) and the public key to `priv/release_signing_key.pub`. Commit the
public key, then give the private key to the workflow:

```bash
gh secret set RELEASE_SIGNING_KEY --repo oliveigah/my_work_tools < ~/.config/mwt/release-signing-key.pem
```

Keep the private key offline after that (a password manager, an encrypted
backup); MWT never needs it.

To replace the key, run the script with a new path, commit the new public key
and set the secret again. Installs from before the change only trust the old
key: their next update has to come from a file, or be signed by the old key.

## Cutting a release

1. Make sure `master` holds what goes out and `mix precommit` passes.
2. Publish a release on GitHub with a new version tag (`v1.2.3`), newer than
   the last one: MWT installs only a version newer than the one it runs.
3. Wait for *Release Linux packages* to attach the packages, `SHA256SUMS` and
   `SHA256SUMS.sig`. Installed apps offer it at their next check.
