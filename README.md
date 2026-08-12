# ssd_hdd_migration.sh

A three-stage tool for migrating a running Linux system from an HDD to an
SSD, then splitting `/home` back onto the HDD — so your OS runs fast from
the SSD while your bulk files live on the higher-capacity HDD.

No live USB required. No reinstall required. Runs from your existing,
booted Linux system.

## Distro compatibility

| | Supported |
|---|---|
| Debian, Ubuntu, and derivatives | ✅ |
| Fedora, RHEL, CentOS Stream | ✅ (bootloader/initramfs auto-detected) |
| Arch, Manjaro, and derivatives | ✅ (bootloader/initramfs auto-detected) |
| openSUSE | ✅ for `clone`; `split-home` only if root is ext4 (openSUSE defaults to Btrfs — see below) |
| Any distro using **GRUB** as the bootloader | ✅ |
| Any distro using **systemd-boot, rEFInd**, or another non-GRUB bootloader | ❌ not supported |
| Root filesystem is **ext2/3/4** | ✅ full support |
| Root filesystem is **Btrfs or XFS** | ✅ for `clone` (always creates a fresh ext4 target) — ❌ for `split-home`'s shrink step, which is refused outright rather than guessed at |

**Why the Btrfs/XFS limit exists:** `split-home` shrinks your *existing*
HDD partition using `resize2fs`, which only understands ext2/3/4. Btrfs
has its own, very different resize mechanism, and XFS cannot be shrunk at
all. Rather than attempt something unreliable, the script checks the
filesystem type up front and refuses with a clear error if it isn't
ext-family. `clone` itself has no such restriction, since it copies files
with `rsync` (not a block-level clone) onto a freshly created ext4
partition regardless of what your source filesystem is.

## Not supported

These aren't checked for or guarded against — the script assumes a fairly
standard single-disk desktop/laptop install:

- **LVM** (Logical Volume Manager) root filesystems. The script works with
  plain partitions only.
- **Encrypted (LUKS) root filesystems.** Not detected or handled.
- **Multi-boot setups with more than two OS's already installed.** Tested
  with a single existing Linux install; additional OS's on the same disk
  aren't accounted for and their boot entries aren't preserved or migrated.
- **Secure Boot compatibility isn't specifically verified.** GRUB's signed
  shim generally works fine with Secure Boot enabled, but this hasn't been
  tested end-to-end here — if you hit boot issues, try disabling Secure
  Boot temporarily to isolate the cause.

## What it does

| Stage | What happens |
|---|---|
| `clone` | Wipes a target SSD, partitions it (EFI + ext4 root), and clones your entire running system onto it, including `/home`. |
| `split-home` | Shrinks the old HDD root partition (kept as a backup image) and creates a new partition in the freed space, dedicated to `/home`. Moves your current `/home` onto it. |
| `cleanup` | Deletes the now-redundant `/home` copy left behind on the SSD after `split-home`, reclaiming that space. |

Each stage is run separately, with a reboot and manual verification
between `clone` and `split-home`. Nothing here silently chains into the
next stage — you stay in control at every step.

## Requirements

- **A Linux distro using GRUB with UEFI boot mode**, not Legacy/CSM. Check
  your BIOS settings if unsure. See the compatibility table above.
- **Two physical drives**: the source HDD you're currently booted from, and
  a target SSD with equal or greater free space than your HDD's *used*
  space (check with `df -h /`).
- **Root privileges** — every stage must be run with `sudo`.
- **Standard tools**: `parted`, `rsync`, `blkid`, `wipefs`, `partprobe`,
  `e2fsck`, `resize2fs`, `mkfs.ext4`, `mkfs.fat`, `chroot`, and (inside the
  cloned system) `grub-install`/`grub2-install` plus
  `update-grub`/`grub-mkconfig`/`grub2-mkconfig`. The script checks for
  these up front and tells you exactly what's missing, with an install
  command for your detected package manager (`apt`, `dnf`, `pacman`, or
  `zypper`), rather than failing partway through with a cryptic error.
- **A backup of anything irreplaceable**, stored elsewhere (external drive
  or cloud), before you start. This script is written defensively, but any
  operation that partitions and formats disks carries inherent risk. Don't
  skip this.

## Before you run anything

1. Run `lsblk` and identify your devices by size and model — **know for
   certain which device is your target SSD and which is your source HDD**
   before passing anything to this script. Getting a device name wrong can
   destroy the wrong disk.
2. Close unnecessary applications, especially anything with unsaved work,
   before the `clone` stage — files open during the copy could end up in a
   slightly inconsistent state on the new copy (your original stays
   untouched either way).
3. Make sure the SSD isn't currently mounted with data you need — `clone`
   wipes it completely.

## Usage

```bash
chmod +x ssd_hdd_migration.sh
```

### Stage 1 — Clone your system onto the SSD

```bash
sudo bash ssd_hdd_migration.sh clone --ssd /dev/sdX
```

Replace `/dev/sdX` with your target SSD (e.g. `/dev/sdb`). This:
- Refuses to run if `/dev/sdX` is the disk you're currently booted from.
- Refuses to run if your used space won't fit on the target.
- Wipes and partitions the SSD (512MB EFI + ext4 root).
- Copies your entire running system onto it, including `/home`.
- Updates `/etc/fstab` and installs GRUB on the SSD.

You'll be shown `lsblk` output and asked to type `YES` before anything
destructive happens.

**After it finishes:** reboot, open your BIOS/UEFI boot menu, and select
**After it finishes:** reboot, open your BIOS/UEFI boot menu, and select
the SSD's boot entry (named after your distro, e.g. "ubuntu" or "fedora" —
pulled automatically from `/etc/os-release`). If two entries with the
same name appear (old HDD + new SSD), use `sudo efibootmgr -v` to tell
them apart by GUID, and `sudo efibootmgr -o <order>` to set the SSD's
entry first permanently.

**Verify before continuing:**
```bash
findmnt /        # should show your SSD's root partition
ls ~/Desktop     # confirm your files are present
```

### Stage 2 — Split `/home` onto the HDD

Only run this after you've confirmed you're booted from the SSD.

```bash
sudo bash ssd_hdd_migration.sh split-home \
  --disk /dev/sdY \
  --old-root-part /dev/sdY2 \
  --backup-size 100
```

- `--disk` is the HDD itself (e.g. `/dev/sda`).
- `--old-root-part` is the HDD's original root partition from before the
  clone (e.g. `/dev/sda2`) — this becomes a shrunk-but-intact backup.
- `--backup-size` (optional, default `100`) is how many GB to keep for
  that backup. Should comfortably exceed your actual used space.

This:
- Refuses to run if you're still booted from the old HDD partition.
- Shrinks the filesystem and partition to `--backup-size`.
- Creates a new partition in the freed space and formats it.
- Copies your current `/home` onto it.
- Adds a `/home` entry to `/etc/fstab` (refuses to run twice — won't
  duplicate the entry).

**After it finishes:** reboot, then verify:
```bash
df -h /home      # should show the new HDD partition
ls ~/Desktop     # confirm files are still there
```

At this point your real `/home` lives on the HDD. A redundant copy still
sits on the SSD, hidden underneath the new mount — harmless, just using
space. Use your system normally for a while before doing the final
cleanup — there's no rush.

### Stage 3 — Reclaim the redundant space on the SSD

```bash
sudo bash ssd_hdd_migration.sh cleanup --home-part /dev/sdY3
```

- `--home-part` is the new HDD `/home` partition created in Stage 2 (e.g.
  `/dev/sda3`).

This:
- Refuses to run unless `/home` is actually mounted from the partition you
  specify (protects against running this before Stage 2 is verified).
- Uses a bind-mount to safely view and delete the leftover copy on the SSD
  **without unmounting your live `/home`** — this avoids the classic
  "target is busy" problem caused by desktop apps holding files open.
- Shows you what it's about to delete and its size, and requires typing
  `YES` before deleting anything.

## Safety notes

- Every destructive step requires an explicit typed `YES` confirmation —
  nothing runs unattended.
- The script checks device identity before wiping or modifying anything
  and refuses to proceed if something looks wrong (wrong disk, wrong boot
  state, `/home` not where expected).
- `/etc/fstab` is backed up (`fstab.bak`, `fstab.bak.homephase2`) before
  any edit.
- Your original HDD data is never deleted by Stage 1 or Stage 2 — Stage 2
  only *shrinks* the old partition, keeping it as an intact backup. Only
  Stage 3 deletes anything, and only the redundant SSD copy, only after
  confirming `/home` is safely on the HDD.
- If you interrupt a stage partway through (e.g. Ctrl+C), don't assume
  it's safe to just re-run — check `lsblk` and `df -h` first to understand
  what state you're in before continuing.

## Troubleshooting

- **"target is busy" during any unmount**: something (a terminal session,
  a file manager, a background app) has a file open on that device. Close
  it, or check with `sudo fuser -vm <mountpoint>`. Stage 3 is designed to
  avoid this entirely by not unmounting `/home` directly.
- **System boots the old HDD instead of the new SSD after Stage 1**: check
  `sudo efibootmgr -v` for duplicate `ubuntu` entries and reorder with
  `sudo efibootmgr -o <order>` so the SSD's entry (matching its GPT GUID)
  boots first.
- **Moving these drives to different hardware later**: Linux doesn't need
  reactivation or reinstalling when the motherboard/CPU changes. Reconnect
  both drives, ensure the new board boots in UEFI mode, and either let the
  firmware auto-detect the fallback bootloader or select it manually from
  the one-time boot menu. `/etc/fstab` uses UUIDs, so drive letter changes
  (`sda`/`sdb` swapping) don't break anything.
- **`split-home` refuses to run, saying your filesystem isn't ext2/3/4**:
  your distro likely defaults to Btrfs (Fedora, openSUSE) or XFS (RHEL).
  This script's shrink step is ext-only by design (see the compatibility
  table above) — shrinking Btrfs or XFS safely requires different tooling
  this script doesn't implement.
- **Dependency check fails listing missing tools**: run the suggested
  install command for your package manager, then re-run the same stage —
  nothing destructive happens before the dependency check passes.
