# btrfs4mac

<img src="docs/icon.png" width="96" align="right" alt="btrfs4mac icon">

A macOS menu bar app with two jobs.

1. **Btrfs and LUKS encryption on external drives.** macOS reads neither. btrfs4mac drives [anylinuxfs](https://github.com/nohajc/anylinuxfs), a small Linux VM, so a **Btrfs-on-LUKS2** drive mounts read-write in Finder: plug the drive in, start the app, type the passphrase. On top of that it adds what Btrfs is good for: snapshots, subvolumes with their sizes, a data scrub and health counters.
2. **Keeping a drive that powers itself off alive.** Some enclosures cut their own power after about a minute without traffic, and the mounted volume dies with them. This was written for a SanDisk Professional G-DRIVE 22 TB that behaves exactly like that. While the volume is mounted the app writes and syncs a few bytes every 20 seconds, so the drive never idles.

It works with **any external drive**, whatever the make: the drive is found automatically (see "Choosing the drive"). The keep-alive helps any drive that spins down or powers off when idle.

## What it does

- **One-click unlock and mount.** Finds the drive, asks for the LUKS passphrase (optionally remembers it in the Keychain), mounts the volume, opens Finder.
- **One-click eject.** "Eject Drive and Quit" unmounts, stops the VM, ejects the drive and quits, leaving no `anylinuxfs`, `vmnet-helper` or `gvproxy` process behind.
- **Keep the drive awake.** Many USB drives power themselves off after a minute or so of idle, which kills a mounted volume. While mounted, the app writes and syncs a few bytes every 20 seconds so the drive never idles.
- **Live dashboard** at the top of the menu: the mount point, the drive's vendor, model, capacity, USB link speed and serial number, a used/free space bar, a 60-second read/write throughput graph with the current rates, a health badge (`btrfs device stats`, see "What \"No errors\" means"), and the bytes written and read.
- **Btrfs card** in the main menu: every subvolume with its size (open, create, snapshot one) and snapshots (open, delete, snapshot everything) as rows with buttons, plus a scrub (full checksum check of all data) with an estimated progress bar and the result of the last run.
- **LUKS header backup and verify.** Saves the LUKS header to a file you choose and compares a saved file with the drive later.
- **Recovers from a dropped drive.** If the drive comes back under a new disk name, the dead mount is cleared and the app asks again.
- **About** shows the app and anylinuxfs versions and tells you when a newer anylinuxfs release exists.

<p>
  <img src="docs/dashboard-dark.png" width="330" alt="Dashboard, dark">
  <img src="docs/dashboard-light.png" width="330" alt="Dashboard, light">
  <img src="docs/btrfs-dark.png" width="330" alt="Btrfs card, dark">
</p>

*The screenshots are the two cards rendered with sample numbers.*

## Requirements

- Apple Silicon Mac, macOS 13 or newer
- Xcode Command Line Tools (`xcode-select --install`), for `swift`
- anylinuxfs:
  ```bash
  brew tap nohajc/anylinuxfs
  brew trust nohajc/anylinuxfs
  brew install anylinuxfs
  ```
- An admin account: reading the raw disk needs `sudo`, which the app requests through a native password dialog.

## Install

### Option 1: the DMG

1. Install [anylinuxfs](https://github.com/nohajc/anylinuxfs) (see Requirements).
2. Download `btrfs4mac-<version>.dmg` from the [Releases page](https://github.com/shatyrko/btrfs4mac/releases), open it and drag **btrfs4mac** onto **Applications**.
3. **The first launch is blocked by macOS.** The app is signed ad hoc and not notarized (notarizing needs a paid Apple Developer account), so Gatekeeper refuses a downloaded copy with a message like "btrfs4mac can't be opened because Apple cannot check it for malicious software". It is a one-time step:
   1. Open btrfs4mac once (double-click) and close the message.
   2. Open **System Settings ▸ Privacy & Security**, scroll down to **Security**.
   3. Next to *"btrfs4mac" was blocked to protect your Mac*, click **Open Anyway**, confirm with your password or Touch ID, then open the app again and confirm **Open**.

   On macOS 15 (Sequoia) and later, the old right-click ▸ Open shortcut no longer works; the Settings step above is the way. The same thing from a terminal:
   ```bash
   xattr -dr com.apple.quarantine /Applications/btrfs4mac.app
   ```
4. Optional: check the download against the `.sha256` file from the release: `shasum -a 256 -c btrfs4mac-<version>.dmg.sha256`.

### Option 2: build it yourself

A copy you build on your own Mac is not quarantined, so Gatekeeper does not get in the way.

```bash
git clone https://github.com/shatyrko/btrfs4mac.git
cd btrfs4mac
scripts/build.sh
open /Applications/btrfs4mac.app
```

`scripts/build.sh` builds with SwiftPM, signs the app ad hoc (no Apple developer account) and installs it to `/Applications` (or `~/Applications` if that is not writable). `scripts/make-dmg.sh` makes the DMG. The app has no Dock icon, only the menu bar icon.

## Choosing the drive

btrfs4mac looks at your external drives and takes the first one with a partition that macOS cannot read itself (no volume, no mount point, an unknown partition type such as a raw GUID or "Linux"), which is what Btrfs and LUKS look like to macOS. The volume label does not matter: the mount point is read from the system's mount table.

If more than one drive qualifies, a "Choose Drive" submenu appears and remembers your pick. To pin a drive by the name macOS reports for it:

```bash
diskutil info /dev/diskN | grep "Media Name"
defaults write local.btrfs4mac diskName "Your Drive Name"
```

Restart the app afterwards. The keep-alive interval and the anylinuxfs path are constants in `Sources/btrfs4mac/Support.swift`.

## Menu

| State | Items |
| --- | --- |
| Drive not plugged in | status only |
| Locked | Unlock and Mount…, LUKS Header, Eject Drive |
| Mounted | dashboard, Open in Finder, Lock, Lock and Eject Drive, the Btrfs card (subvolumes with sizes, snapshots, data check), Keep Drive Awake with its LUKS Header submenu, About, Eject Drive and Quit |

Flow: plug the drive in, start the app. It asks for the passphrase at once, mounts the volume and opens Finder. While data moves, the menu bar icon shows ↑ (writing), ↓ (reading) or ↕.

## How it works

- The drive is found among the external physical disks (see "Choosing the drive"); its partition is passed to anylinuxfs. The volume is recognised afterwards by its NFS entry in the mount table (`diskNsM.local:/mnt/<label>`).
- **Mount:** `sudo -A --preserve-env=ALFS_PASSPHRASE anylinuxfs mount -w false --ignore-permissions /dev/diskXsY`. The passphrase travels in the environment variable `ALFS_PASSPHRASE`, never on a command line. `sudo` asks for the Mac password through a small askpass helper (a native dialog), written to `~/Library/Application Support/btrfs4mac/`. `--ignore-permissions` is needed because the Btrfs root directory is owned by root.
- **Unmount:** `anylinuxfs unmount --wait-for-vm`; **eject:** `diskutil eject`.
- **Btrfs tools** run `btrfs` inside the VM with `anylinuxfs vm exec`, which needs a terminal, so the app wraps it in `script`.
- **Scrub:** the VM's root file system is read-only, so btrfs cannot record scrub progress and `btrfs scrub status` shows nothing useful. The app runs `btrfs scrub start -B` in the foreground of a `vm exec` session; the scrub keeps going inside the VM if the app quits. Whether one is running comes from the VM's process list, progress from the VM's own counter of bytes read from the drive (`/sys/block/vda/stat`) against the "Total to scrub" figure, and the history (started, finished, cancelled, checksum errors) from the VM's kernel log, so a restarted app picks up a running scrub where it is. The percentage is an estimate (hence the "≈"): the counter also includes any other reads since the VM started.
- **LUKS header backup:** reads the first 32 MiB of the partition with `sudo dd`, finds the real header size in the LUKS metadata (LUKS1 and LUKS2) and saves just that, mode 0600. It is the same content `cryptsetup luksHeaderBackup` writes, so `cryptsetup luksHeaderRestore` accepts it.
- **Snapshots** go to `.snapshots/<time>/` (`_root` for the top level, one entry per subvolume) or `.snapshots/<time>-<name>/` for a single subvolume. A snapshot of the top level alone would hold only empty folders where subvolumes are, so the whole-volume snapshot covers each subvolume too.
- **Quit** unmounts and stops the VM. Killing the app (`pkill btrfs4mac`) leaves the mount and VM running on purpose, so the app can restart without unmounting.
- Automatic actions are logged to `~/Library/Logs/btrfs4mac.log`; anylinuxfs keeps its own logs in `~/Library/Logs/anylinuxfs-*.log`.

## Security notes

- A header backup plus an old passphrase unlocks the drive. Keep the file private, and off the drive itself (the app refuses to save it there).
- "Remember in Keychain" stores the passphrase in your login keychain (item `btrfs4mac.luks`). Anyone logged in as you with the keychain unlocked can then open the drive. It is off unless you tick it; "Forget Saved Passphrase" removes it.
- The Mac password is only ever typed into the system dialog that `sudo` shows; the app does not see or store it.
- The app's own network access is a single update check; everything else is local. See "Network access" below.

## Network access

If you run a firewall (Little Snitch, LuLu, …) it will ask about these. What each one is and whether you can refuse it:

| Connection | Made by | Why | Can you block it? |
| --- | --- | --- | --- |
| `api.github.com`, HTTPS | btrfs4mac | Update check: one request for the latest anylinuxfs release, at start and every 12 hours. Sends nothing but a generic `User-Agent: btrfs4mac`. | **Yes.** Everything works without it; you only lose the "Update available" notice. |
| Virtual network `172.27.1.0/30` | anylinuxfs (`vmnet-helper`, or `gvproxy`) | A private network between your Mac and the Linux VM that reads the drive. | No: it is how the volume reaches Finder. It never leaves the Mac. |
| NFS to `172.27.1.2`, ports 111, 2049, 32765, 32767 (TCP and UDP) | macOS NFS client → the VM | The volume is served by the VM as an NFS share and mounted at `/Volumes/<label>` (anylinuxfs' own documentation: by default it is reachable only from localhost). | No, same reason. Local only. |
| `dl-cdn.alpinelinux.org` and the registry holding the VM image, HTTPS | anylinuxfs | Downloads the Alpine Linux image and its packages (Btrfs tools, cryptsetup, the NFS server) the first time it runs, and again when you update it. | Only needed for the first setup and for upgrades. |

Nothing else leaves your Mac: not the LUKS passphrase, not the Mac password, not file names or contents. If you want to see for yourself what is contacted, your firewall's connection log or `lsof -i -n -P | grep -E "btrfs4mac|anylinuxfs|vmnet"` shows it. The Linux-side hostnames above are what I observed; anylinuxfs decides where it downloads from, so check its documentation for changes.

## Troubleshooting

- **A firewall (Little Snitch, LuLu, …) asks about the app on every start.** The app is signed ad hoc, so every build has a new signature and a firewall sees a new program each time. Sign with a stable local certificate to avoid it, or see "Network access" above for what each connection is and which you can refuse.
- **`-600` when relaunching right after `pkill`.** The old instance was still exiting; run `open` again.
- **"Cannot probe /dev/diskNsM … Insufficient permissions".** The mount was started without `sudo`; use the app, which asks for it.

## Limitations

- Built and tested for one drive on one Mac (Apple Silicon, macOS 26). Treat it as a starting point and try it on a drive that holds nothing you cannot lose first: it handles encrypted data and runs `sudo`.
- Keep-alive only works while the volume is mounted, and it cannot stop the Mac from sleeping.
- Reads and writes go through an NFS share served by the VM, so small-file performance is lower than a native disk.

## Licenses and credits

- btrfs4mac is released under the [MIT License](LICENSE).
- It runs [anylinuxfs](https://github.com/nohajc/anylinuxfs) (GPL-3.0) as a separate program that you install yourself; no anylinuxfs code is included or linked.
- The small glyphs in the menu are Apple SF Symbols, used inside the app's interface as Apple's terms allow. The app icon is an original drawing (`scripts/make-icon.swift`) and does not use SF Symbols.
- Not affiliated with or endorsed by SanDisk, Western Digital, Apple or the anylinuxfs project. Product names are used only to say what the tool was tested with.

## What "No errors" means

The badge on the dashboard reads Btrfs' own per-device error counters, the ones `btrfs device stats` prints, through the VM. Btrfs keeps them in the filesystem itself and bumps them whenever something goes wrong:

- `write_io_errs`, `read_io_errs`, `flush_io_errs`: the drive failed or refused a write, a read or a flush
- `corruption_errs`: a block was read and its checksum did not match (silent corruption caught)
- `generation_errs`: a block's generation number did not match what the metadata expects (an inconsistency)

The app adds the five up. All zero is the green "No errors"; anything else turns the badge red with the total.

What it does not tell you: the counters only move when Btrfs actually touches something broken, so data nobody has read since it went bad is unchecked (a scrub, in the Btrfs card, reads and verifies everything). It is also not SMART: SMART is not available through most USB bridges, so wear, reallocated sectors and temperature stay invisible. The counters last from when the filesystem was created until someone resets them with `btrfs device stats -z`.

## Releasing

Work happens on `main`. To ship a version, push a tag; GitHub Actions builds the DMG on a macOS runner and publishes the release with the DMG and its checksum:

```bash
git tag v0.3.1
git push origin v0.3.1
```

The version in the app comes from the tag. "Build" runs on every push to `main` to catch a broken commit early. To try the release build without publishing anything, run the "Release" workflow by hand from the Actions tab; it keeps the DMG as a downloadable artifact.
