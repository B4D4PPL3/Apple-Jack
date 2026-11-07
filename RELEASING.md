# Public releases

Publish only when the maintainer has signed off on a stable version and separately requested its public release. A private beta build, stable promotion, source commit, or tag does not publish this edition.

## Unnotarized preview

For the approved 0.51 preview, use the verified public-edition disk image from `dist/local/`. Copy it as `Apple-Jack-0.51-preview-macOS.dmg`. From the directory containing the copy, run:

```sh
shasum -a 256 Apple-Jack-0.51-preview-macOS.dmg > Apple-Jack-0.51-preview-macOS.dmg.sha256
shasum -a 256 -c Apple-Jack-0.51-preview-macOS.dmg.sha256
```

Create a GitHub Release for tag `v0.51-preview.1` from the public source commit and select **Set as a pre-release**. Attach the DMG and checksum. Include the first-launch instructions from the README and explain that preview updates are manual. Verify the checksum against a fresh download after publishing.

## Notarized release

1. Apply the approved stable changes to the public source tree. Preserve the public bundle identifier, storage locations, URL scheme, and GitHub updater. Review the code and asset licenses. Keep the public marketing version aligned with the approved stable version and set a build number greater than the previous public build in `Resources/Info.plist`.
2. Use a Developer ID Application identity and a notarytool Keychain profile belonging to the maintainer. Build and package from the repository root with the actual GitHub repository and identity. The following variables represent your own values.

   ```sh
   python3 Scripts/build.py --repository "$GITHUB_REPOSITORY" --identity "$SIGNING_IDENTITY"
   python3 Scripts/package.py --identity "$SIGNING_IDENTITY" --notary-profile "$NOTARY_PROFILE" --notes "$RELEASE_NOTES"
   ```

3. The packager notarizes the app and disk image, staples both tickets, mounts the final image, and checks Gatekeeper and both processor architectures. Smoke-test the packaged app on supported Macs. On subsequent releases, exercise **Install & Restart** from a previously distributed build. The updater verifies the SHA-256 digest and the signing team of the replacement.
4. Create a **draft** GitHub Release tagged `v<version>` from the reviewed public commit. Attach the versioned DMG, its checksum, and `latest.json` from `dist/release/`. After the maintainer's public-release instruction, publish it as the latest regular release. The app reads `releases/latest/download/latest.json` and downloads the versioned DMG from that release.
5. Download the published DMG and manifest and compare their digest. Test the update from the preceding public release. For the first release, check that Jack reports its installed version is current.

The local DMG under `dist/local/` is for development. Configuring a repository for a build takes no GitHub credentials. Signing keys and notarization credentials stay in the maintainer’s Keychain.
