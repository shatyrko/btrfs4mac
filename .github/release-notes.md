btrfs4mac is a macOS menu bar app for external drives that are **Btrfs on LUKS2**, built on [anylinuxfs](https://github.com/nohajc/anylinuxfs), with a keep-alive for drives that power themselves off when idle.

## Install

1. Install anylinuxfs: `brew tap nohajc/anylinuxfs && brew trust nohajc/anylinuxfs && brew install anylinuxfs`
2. Open the DMG and drag **btrfs4mac** onto **Applications**.
3. **macOS blocks the first launch**, because the app is not notarized (that needs a paid Apple Developer account). Open it once, then go to **System Settings ▸ Privacy & Security ▸ Security** and click **Open Anyway**. Or in a terminal: `xattr -dr com.apple.quarantine /Applications/btrfs4mac.app`

Details, the network connections the app makes, and how it works are in the [README](https://github.com/shatyrko/btrfs4mac#readme).

Apple Silicon only, macOS 13 or newer. The SHA-256 of the DMG is in the attached `.sha256` file.
