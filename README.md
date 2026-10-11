# G-Drive

A small macOS menu bar app for one external drive: a SanDisk Professional G-DRIVE, Btrfs on LUKS2, mounted on the Mac with [anylinuxfs](https://github.com/nohajc/anylinuxfs).

It does three things:

- **Unlock and mount** the drive (asks for the LUKS passphrase, optionally remembers it in the Keychain).
- **Lock, or lock and eject** it: unmounts, stops the helper VM, and powers the drive down for unplugging.
- **Keep-alive**: the drive switches itself off after a short idle time, and macOS cannot change that. While the volume is mounted the app writes and syncs a few bytes to `.g-drive-keepalive` every 20 seconds, so the drive never goes idle.

Personal tool, not for distribution. No Apple developer account, no notarization: the app is signed ad hoc and built on the machine that runs it.

## Requirements

- Apple Silicon Mac, macOS 13 or newer
- Xcode Command Line Tools (for `swift`)
- `brew tap nohajc/anylinuxfs && brew trust nohajc/anylinuxfs && brew install anylinuxfs`

## Build and install

```bash
scripts/build.sh
open ~/Applications/GDrive.app
```

The app is installed to `~/Applications`.

## Menu

| State | Items |
| --- | --- |
| Drive not plugged in | status only |
| Locked | Unlock and Mount…, Back Up LUKS Header…, Eject Drive |
| Mounted | live read/write activity, Open in Finder, Lock, Lock and Eject Drive, Back Up LUKS Header…, Keep-alive on/off, last keep-alive result |

Flow: plug the drive in, start the app. It finds the drive and asks for the passphrase at once, mounts it and opens Finder. While data moves, the menu bar icon shows ↑ (writing), ↓ (reading) or ↕, and the menu shows the rate.
If the drive drops off the bus and comes back under another name (`disk4` → `disk5`), the old mount is dead; the app clears it and asks again.

## How it works

- The drive is found by its media name (`G-DRIVE`, see `Config` in `Sources/GDrive/Support.swift`) among external physical disks; its first partition is passed to anylinuxfs.
- Mount runs `anylinuxfs mount -w false --ignore-permissions /dev/diskXsY` with the passphrase in `ALFS_PASSPHRASE`. `--ignore-permissions` is needed because the Btrfs root directory is owned by root.
- Unmount runs `anylinuxfs unmount --wait-for-vm 30`; eject runs `diskutil eject`.
- The mount point (`/Volumes/backup`), the interval and the media name are constants in `Support.swift`.

## Not done

- The Linux counterpart.
- Keep-alive does not stop the Mac from sleeping; the drive loses power when the Mac sleeps.

## LUKS header backup

"Back Up LUKS Header…" asks where to save, reads the first 32 MiB of the partition with `sudo dd`, finds the real header size in the LUKS metadata (LUKS1 and LUKS2) and saves just that, with mode 0600. This is the same content `cryptsetup luksHeaderBackup` writes, so `cryptsetup luksHeaderRestore` accepts it. Saving onto the drive itself is refused.

## More

- **Verify Backup…** (LUKS Header menu): compares a saved header file with the header on the drive. Reports "matches", "out of date" (same drive, header changed since) or "another drive" (different LUKS UUID).
- **Space and errors** in the menu: free space from `statfs`, error counters from `btrfs device stats`.
- **Btrfs menu**: read-only snapshots of the whole volume in `.snapshots` (take, open in Finder, delete) and a scrub (full checksum check of the data, start/cancel, last result). They run `btrfs` inside the anylinuxfs VM through `anylinuxfs vm exec`, which needs a terminal, so the app wraps it in `script`.

## Space, totals and subvolumes

- The menu shows used and free space, and how much macOS has counted as written and read since the drive was plugged in.
- **Btrfs ▸ Subvolumes** lists the subvolumes (open one in Finder, or create one with "New Subvolume…").
- A snapshot covers the top level and every subvolume, in `.snapshots/<time>/` (`_root` for the top level, `/` in a subvolume path becomes `__`). A snapshot of the top level alone would hold empty folders where the subvolumes are.
