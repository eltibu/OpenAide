# Releasing

## Channels

- **Dev builds**: every push to the default branch and every pull request from this repo builds an APK and publishes it as a GitHub *pre-release* `v0.1.<run>` with the asset `nexus-assistant.apk`. Phones on the Dev channel install these.
- **Public releases**: run the **Build** workflow by hand on the default branch with **public_release** ticked. It publishes a normal release `v0.1.<run>` marked *latest*, with the asset `OpenAide-0.1.<run>.apk` and notes listing the changes since the previous public release. Phones on the Stable channel (the default for new installs) install these, and the README's download link points here.

Both are signed with the same key and use one version counter, so any build installs over any older one.

The update token (`NEXUS_UPDATE_TOKEN`) is only built in while the repo is private, and never into public or tester builds. Once the repo is public, no build carries it.

## Going public (once)

In this order, so no phone ever needs a reinstall:

1. Merge the work into the default branch. Let a dev build from it reach your phone **and every tester's copy that has the built-in token**: this build remembers the Dev channel and can update without a token. A copy that skips it would keep the old updater, which stops seeing updates once the token is revoked (step 5) and then needs the new APK installed by hand (over the top, no uninstall).
2. Run **Mark old builds as dev builds** (Actions tab). Every earlier release becomes a pre-release, so Stable doesn't offer an old dev build.
3. Settings → General → Danger Zone → **Change visibility** → Public.
4. Settings → Actions → General → Fork pull request workflows: choose **Require approval for all outside collaborators**. (The workflow also never builds fork pull requests on the self-hosted runner.)
5. Check in App updates on each of those phones that the installed version is the step 1 build or newer. Then revoke the `NEXUS_UPDATE_TOKEN` personal access token on GitHub and delete the repo secret. Old APKs contain it in plain text; once revoked it's useless.
6. Run **Build** with **public_release** on the default branch.
