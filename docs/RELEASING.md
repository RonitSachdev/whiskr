# Releasing Whiskr

Whiskr has not been released yet. This page describes how a release is made when the time comes, what an
unsigned build means for the people who download it, and what to add if the project ever has an Apple
Developer ID.

## What a release contains

- `Whiskr-<version>-macOS-universal-unsigned.zip`: `Whiskr.app` (Apple silicon and Intel), zipped with
  `ditto` so the bundle's links, permissions and attributes survive.
- `Whiskr-<version>-macOS-universal-unsigned.zip.sha256`: its SHA-256 checksum.
- Release notes taken from the version's section of [CHANGELOG.md](../CHANGELOG.md).

The app is **not signed with a Developer ID and not notarised.** Code signing is turned off in the project
(`CODE_SIGNING_ALLOWED: NO`). Each executable inside carries only the ad-hoc signature the linker adds,
which Apple silicon needs to run it. The bundle itself has no signature.

## Making a release

1. Make sure `main` is green: `make test` and `make build` locally, or run the **CI** workflow by hand.
2. Choose the version (Semantic Versioning) and set `MARKETING_VERSION` (and bump
   `CURRENT_PROJECT_VERSION`) in `native/App/project.yml`. Run `make project`.
3. In `CHANGELOG.md`, rename **Unreleased** to `## [x.y.z] - YYYY-MM-DD`, start a new empty
   **Unreleased** section above it, and add the comparison links at the bottom.
4. Commit (`chore: release x.y.z`), then tag and push the tag:

   ```sh
   git tag -a vx.y.z -m "Whiskr x.y.z"
   git push origin vx.y.z
   ```

5. The **Release** workflow (`.github/workflows/release.yml`) runs for the tag. It checks that the tag
   matches `MARKETING_VERSION`, runs the tests, builds the Release configuration, packages it
   (`make dist`) and creates a **draft** GitHub release with the zip, the checksum and the changelog
   section as notes.
6. Open the draft on GitHub, read the notes, download the zip, check the checksum, and try the app on a
   Mac that has not built it. Then publish the draft. Nothing is published automatically.

The workflow can also be started by hand (Actions › Release › Run workflow) with a tag name. It then
drafts a release for the chosen branch's latest commit; the tag is created only when the draft is
published.

The same archive can be made locally:

```sh
cd native/App
make dist                      # into ~/Library/Developer/Whiskr/dist
make dist DIST=/some/folder    # or anywhere outside the source tree
```

## Opening an unsigned app (for people who download it)

macOS keeps apps from unidentified developers from opening on the first try. To open Whiskr:

1. Check the download: `shasum -a 256 -c Whiskr-<version>-macOS-universal-unsigned.zip.sha256` in the
   folder holding both files must print `OK`.
2. Unzip it and move `Whiskr.app` to `/Applications`.
3. Open it. macOS refuses the first time, saying it cannot verify the developer.
4. Open **System Settings › Privacy & Security**, scroll to the message about Whiskr, and click **Open
   Anyway**. Confirm with your password. From then on it opens normally.

If macOS instead says the app "is damaged and can't be opened", that is how some macOS versions describe
a download without a signature. Remove the download's quarantine flag and open it again:

```sh
xattr -dr com.apple.quarantine /Applications/Whiskr.app
```

Only do this for a download whose checksum you have checked against the one on the release page. Building
from source avoids the question altogether: a build you made yourself is not quarantined.

These steps have not yet been tried on a clean Mac with a downloaded build. Check them, and correct this
section, before the first release.

## If a Developer ID becomes available

The project is set up so signing can be added without restructuring it. The app already uses the hardened
runtime and has an entitlements file (`native/App/Whiskr/Whiskr.entitlements`). The work would be:

1. Set `CODE_SIGNING_ALLOWED: YES`, `CODE_SIGN_STYLE`, `CODE_SIGN_IDENTITY: "Developer ID Application"` and
   `DEVELOPMENT_TEAM` for the app, `whiskr-host` and `paw` in `project.yml`. Sign the embedded executables
   (`codeSign: true` on their embed dependencies) and enable the secure timestamp
   (`OTHER_CODE_SIGN_FLAGS: --timestamp`).
2. In the release workflow, import the certificate from repository secrets into a temporary keychain,
   build, then notarise the zip with `xcrun notarytool submit --wait` (an App Store Connect API key in
   secrets), staple the ticket with `xcrun stapler staple Whiskr.app`, and zip again.
3. Optionally ship a signed, notarised `.dmg` and add update checks (Sparkle). Both are separate
   decisions.
4. Rename the archive without `-unsigned`, and remove the "Opening an unsigned app" section above.

None of this is in place today, and the workflows use no secrets.
