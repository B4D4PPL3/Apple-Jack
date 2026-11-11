# Sparkle

Apple Jack uses [Sparkle 2.10.1](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.1) for signed in-app updates. `Scripts/fetch-sparkle.py` downloads the official distribution and verifies its pinned SHA-256 digest. The framework and tools are ignored by git; the build script fetches them when needed.

Archive SHA-256: `1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27`.

Updates use the repository's HTTPS appcast and Ed25519-signed archives. No private signing key is included. Fork maintainers must generate their own key and replace `SUPublicEDKey` before distributing their own updates. See [Sparkle's documentation](https://sparkle-project.org/documentation/).

See [LICENSE](LICENSE) for Sparkle and its third-party notices.
