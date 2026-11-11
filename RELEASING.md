# Public releases

Publish only after the maintainer approves private stable and separately requests a public release. Private beta installation, stable promotion, and source commits do not authorize publication.

## Artwork for each public update

Capture new and visibly changed features from the public build using sample content. Keep accurate existing gallery images. Match the established curved backgrounds, typography, clean crops, and soft shadows. Include the pointed bubble tail whenever a companion appears beneath it. Review exports at normal reading size. Embed detailed, captioned screenshots in Release notes using tag-pinned image URLs, and add relevant examples to the README gallery and offline Setup Guide.

## Build and verify

1. Port the approved stable changes while preserving the public identifier, storage, URL scheme, and GitHub updater. Increment `CFBundleVersion`; keep the marketing version aligned with approved stable.
2. Build both architectures with `python3 Scripts/build.py --repository B4D4PPL3/Apple-Jack`. This fetches the pinned Sparkle framework and verifies its archive digest and signature. Run `Tests/PublicUpdates.swift` as described in README, verify the app signature, and smoke-test both architectures. A Rosetta run is not a physical Intel Mac test.
3. Package with `python3 Scripts/package.py`. For the unnotarized 0.56 preview, copy the verified local DMG to `dist/preview/Apple-Jack-0.56-preview-macOS.dmg`. Generate its SHA-256 file after the final copy. Do not modify an archive after signing it.
4. Sign the final DMG with Sparkle's `sign_update` and the maintainer's existing update-key account in Keychain. Never export or commit the private key. Confirm the key matches `SUPublicEDKey` in the app. Use `Scripts/make-appcast.py` with the archive, `--signature`, `--tag v0.56-preview.1`, and `--notes-file`. It verifies the signature with CryptoKit and writes `Updates/latest.json` and `Updates/appcast.xml`.
5. Review source, licenses, screenshots, metadata, and asset names. Prepare a draft GitHub Release with the final DMG and checksum. Commit the public code, docs, and update feeds; tag that commit. Publish only under the explicit public-release authorization. Mark an unnotarized preview as a pre-release.
6. Download the published archive afresh, verify its digest and Ed25519 signature, inspect the mounted app, and verify the live manifest/appcast. Exercise Install & Restart using a disposable installed copy with a lower build number; verify the replacement and successful relaunch. Keep the user's private app untouched.

## Public update routing

The app checks `https://raw.githubusercontent.com/<owner>/<repo>/main/Updates/latest.json`. Sparkle reads the adjacent `appcast.xml`; the enclosure points to an immutable versioned GitHub Release asset. This explicit feed supports approved preview releases, which GitHub's `releases/latest` endpoint excludes. The preflight and appcast must agree on version, build, and asset URL. Sparkle verifies the archive against the embedded Ed25519 public key before extraction.

**0.54 and earlier require one manual installation of 0.55 or later.** From 0.55, Menu → Updates and the `update` input command offer the native update window. Optional startup checks remain silent when there is no newer compatible release. Automatic downloads/installation and profiling are disabled. Keep previously published assets immutable; a replacement build needs a higher build number and a new tag/asset.

Forks must configure their own repository and generate their own update key before distributing builds; see [Sparkle notes](ThirdParty/Sparkle/README.md). Repository configuration contains no credentials. Never direct a fork to another publisher's signing key/feed.

## Developer ID and notarization

Once configured, build with `--identity "$SIGNING_IDENTITY" --repository "$GITHUB_REPOSITORY"`. Package with `--identity "$SIGNING_IDENTITY" --notary-profile "$NOTARY_PROFILE" --notes "$RELEASE_NOTES"`. The packager notarizes and staples the app and DMG, checks Gatekeeper, and verifies the architecture slices. Then sign the final stapled archive with Sparkle, generate both public feed files, and follow the publication and fresh-download checks above. Notarization and Sparkle archive signing serve different purposes; neither replaces the other.
