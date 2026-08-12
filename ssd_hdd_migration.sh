#!/bin/bash
#
# ssd_hdd_migration.sh
#
# A three-stage tool for migrating a running Linux system from an HDD to
# an SSD, then splitting /home back onto the HDD for extra capacity while
# keeping the OS on the faster SSD.
#
#   Stage 1: clone       - clone your current system onto a target SSD
#   Stage 2: split-home  - shrink the old HDD partition (kept as backup)
#                           and create a dedicated /home partition on it
#   Stage 3: cleanup      - remove the now-redundant /home copy left on
#                           the SSD after Stage 2 is confirmed working
#
# Run each stage separately, verifying the result (and rebooting where
# noted) before moving to the next one.
#
# Usage:
#   sudo bash ssd_hdd_migration.sh clone --ssd /dev/sdX
#   sudo bash ssd_hdd_migration.sh split-home --disk /dev/sdY --old-root-part /dev/sdY2 --backup-size 100
#   sudo bash ssd_hdd_migration.sh cleanup --home-part /dev/sdY3
#
# Always run `lsblk` yourself first and double check device names before
# passing them in. Getting this wrong can destroy data.
#
# COMPATIBILITY:
#   - Works on any distro using GRUB as its bootloader (Debian/Ubuntu,
#     Fedora/RHEL, Arch and derivatives, openSUSE). Bootloader and
#     initramfs commands are auto-detected inside the chroot rather than
#     hardcoded. Not for systemd-boot, rEFInd, or other non-GRUB setups.
#   - split-home requires your EXISTING root partition to be ext2/3/4.
#     Btrfs (common on Fedora/openSUSE) and XFS (common on RHEL) use
#     entirely different resize mechanics (or, for XFS, can't shrink at
#     all) and are deliberately refused rather than guessed at.
#   - clone itself has no filesystem restriction — it always creates a
#     fresh ext4 target regardless of your source filesystem, since it
#     copies files with rsync rather than cloning block-for-block.

set -euo pipefail

# ---------------------------------------------------------------------------
# SHARED HELPERS
# ---------------------------------------------------------------------------
log()  { echo -e "[$(date '+%H:%M:%S')] $*"; }
die()  { echo -e "ERROR: $*" >&2; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die "Run this with sudo."
}

confirm() {
    local prompt="$1"
    read -rp "$prompt Type YES (all caps) to continue: " REPLY
    [[ "$REPLY" == "YES" ]] || { echo "Aborted. No changes were made."; exit 1; }
}

# Maps missing commands to an install hint for the detected package manager.
suggest_install() {
    local pkgs="$1"
    if command -v apt >/dev/null 2>&1; then
        echo "  sudo apt install $pkgs"
    elif command -v dnf >/dev/null 2>&1; then
        echo "  sudo dnf install $pkgs"
    elif command -v pacman >/dev/null 2>&1; then
        echo "  sudo pacman -S $pkgs"
    elif command -v zypper >/dev/null 2>&1; then
        echo "  sudo zypper install $pkgs"
    else
        echo "  (install '$pkgs' or equivalent using your distro's package manager)"
    fi
}

check_dependencies() {
    local missing=() cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Missing required tools: ${missing[*]}" >&2
        echo "Typical package names: parted, rsync, util-linux (blkid/wipefs/partprobe)," >&2
        echo "dosfstools (mkfs.fat), e2fsprogs (mkfs.ext4/e2fsck/resize2fs). Try:" >&2
        suggest_install "parted rsync dosfstools e2fsprogs util-linux" >&2
        die "Install the missing tools above and re-run."
    fi
}

usage() {
    cat <<'EOF'
Usage:
  sudo bash ssd_hdd_migration.sh clone --ssd /dev/sdX
  sudo bash ssd_hdd_migration.sh split-home --disk /dev/sdY --old-root-part /dev/sdY2 [--backup-size 100]
  sudo bash ssd_hdd_migration.sh cleanup --home-part /dev/sdY3

Stages must be run in order, with a reboot + verification between clone
and split-home. See the comments at the top of this script for details.
EOF
    exit 1
}

[[ $# -ge 1 ]] || usage
STAGE="$1"; shift

# ---------------------------------------------------------------------------
# STAGE 1: CLONE — copy the running system onto a target SSD
# ---------------------------------------------------------------------------
stage_clone() {
    local SSD_DEV="" MOUNT_POINT="/mnt/ssd" EFI_SIZE="513MiB"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ssd) SSD_DEV="$2"; shift 2 ;;
            *) die "Unknown option for clone: $1" ;;
        esac
    done
    [[ -n "$SSD_DEV" ]] || die "clone requires --ssd /dev/sdX"
    [[ -b "$SSD_DEV" ]] || die "$SSD_DEV is not a block device."

    require_root
    check_dependencies parted rsync blkid wipefs partprobe mkfs.fat mkfs.ext4 chroot findmnt lsblk blockdev

    local ROOT_SRC_DEV; ROOT_SRC_DEV=$(findmnt -n -o SOURCE /)
    local ROOT_SRC_DISK; ROOT_SRC_DISK="/dev/$(lsblk -no pkname "$ROOT_SRC_DEV")"
    [[ "$SSD_DEV" != "$ROOT_SRC_DISK" ]] || \
        die "$SSD_DEV is the disk your current root filesystem is on. Refusing to wipe it."

    log "=== Current disk layout ==="
    lsblk
    echo
    log "Current root filesystem: $ROOT_SRC_DEV (on $ROOT_SRC_DISK)"
    log "Target SSD to WIPE and clone onto: $SSD_DEV"
    echo

    # Refuse to proceed if the target is smaller than the space actually used
    local USED_KB SSD_BYTES
    USED_KB=$(df --output=used / | tail -1)
    SSD_BYTES=$(blockdev --getsize64 "$SSD_DEV")
    if (( USED_KB * 1024 > SSD_BYTES )); then
        die "Used space on / ($((USED_KB / 1024 / 1024))GB) exceeds $SSD_DEV's capacity. Free up space or pick a larger SSD."
    fi

    confirm "This will ERASE $SSD_DEV and clone your system onto it."

    # Unmount anything currently auto-mounted from the target disk
    for part in $(lsblk -lno NAME "$SSD_DEV" | tail -n +2); do
        umount "/dev/$part" 2>/dev/null || true
    done

    log "=== Wiping and partitioning $SSD_DEV ==="
    wipefs -a "$SSD_DEV"
    parted -s "$SSD_DEV" -- mklabel gpt
    parted -s "$SSD_DEV" -- mkpart ESP fat32 1MiB "$EFI_SIZE"
    parted -s "$SSD_DEV" -- set 1 esp on
    parted -s "$SSD_DEV" -- mkpart root ext4 "$EFI_SIZE" 100%
    partprobe "$SSD_DEV"; sleep 2

    local EFI_PART="${SSD_DEV}1" ROOT_PART="${SSD_DEV}2"
    [[ -b "$EFI_PART" ]] || EFI_PART="${SSD_DEV}p1"
    [[ -b "$ROOT_PART" ]] || ROOT_PART="${SSD_DEV}p2"

    log "=== Formatting partitions ==="
    mkfs.fat -F32 "$EFI_PART"
    mkfs.ext4 -F "$ROOT_PART"

    log "=== Mounting $ROOT_PART at $MOUNT_POINT ==="
    mkdir -p "$MOUNT_POINT"
    mount "$ROOT_PART" "$MOUNT_POINT"
    mkdir -p "$MOUNT_POINT/boot/efi"
    mount "$EFI_PART" "$MOUNT_POINT/boot/efi"

    log "=== Copying system files (this may take a while) ==="
    rsync -aAXv / \
      --exclude="/dev/*" --exclude="/proc/*" --exclude="/sys/*" \
      --exclude="/tmp/*" --exclude="/run/*" --exclude="/mnt/*" \
      --exclude="/media/*" --exclude="/lost+found" \
      --exclude="/boot/efi/*" --exclude="/swapfile" \
      "$MOUNT_POINT"

    log "=== Copying EFI partition contents ==="
    rsync -aAXv /boot/efi/ "$MOUNT_POINT/boot/efi/"

    log "=== Updating fstab with new UUIDs ==="
    local NEW_ROOT_UUID NEW_EFI_UUID OLD_ROOT_UUID OLD_EFI_SRC_DEV OLD_EFI_UUID
    NEW_ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
    NEW_EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
    OLD_ROOT_UUID=$(blkid -s UUID -o value "$ROOT_SRC_DEV")
    OLD_EFI_SRC_DEV=$(findmnt -n -o SOURCE /boot/efi)
    OLD_EFI_UUID=$(blkid -s UUID -o value "$OLD_EFI_SRC_DEV")

    cp "$MOUNT_POINT/etc/fstab" "$MOUNT_POINT/etc/fstab.bak"
    sed -i "s/$OLD_ROOT_UUID/$NEW_ROOT_UUID/" "$MOUNT_POINT/etc/fstab"
    sed -i "s/$OLD_EFI_UUID/$NEW_EFI_UUID/" "$MOUNT_POINT/etc/fstab"
    log "New fstab:"; cat "$MOUNT_POINT/etc/fstab"

    log "=== Installing GRUB on the SSD ==="
    mount --bind /dev  "$MOUNT_POINT/dev"
    mount --bind /proc "$MOUNT_POINT/proc"
    mount --bind /sys  "$MOUNT_POINT/sys"
    # Bootloader/initramfs commands and the boot-menu label are detected
    # inside the chroot rather than hardcoded, so this works whether the
    # cloned system is Debian/Ubuntu-family, Fedora/RHEL-family, Arch-family,
    # or openSUSE.
    chroot "$MOUNT_POINT" /bin/bash -c '
        set -e
        . /etc/os-release
        BOOTLOADER_ID="${ID:-linux}"

        if command -v update-initramfs >/dev/null 2>&1; then
            update-initramfs -u
        elif command -v dracut >/dev/null 2>&1; then
            dracut --force
        elif command -v mkinitcpio >/dev/null 2>&1; then
            mkinitcpio -P
        else
            echo "WARNING: no known initramfs tool found; skipping." >&2
        fi

        if command -v grub-install >/dev/null 2>&1; then
            GRUB_INSTALL=grub-install
        elif command -v grub2-install >/dev/null 2>&1; then
            GRUB_INSTALL=grub2-install
        else
            echo "ERROR: no grub-install/grub2-install found in the cloned system." >&2
            exit 1
        fi
        "$GRUB_INSTALL" --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="$BOOTLOADER_ID"

        if command -v update-grub >/dev/null 2>&1; then
            update-grub
        elif command -v grub-mkconfig >/dev/null 2>&1; then
            mkdir -p /boot/grub
            grub-mkconfig -o /boot/grub/grub.cfg
        elif command -v grub2-mkconfig >/dev/null 2>&1; then
            mkdir -p /boot/grub2
            grub2-mkconfig -o /boot/grub2/grub.cfg
        else
            echo "ERROR: no update-grub/grub-mkconfig/grub2-mkconfig found." >&2
            exit 1
        fi
    '
    umount "$MOUNT_POINT/dev" "$MOUNT_POINT/proc" "$MOUNT_POINT/sys"
    umount "$MOUNT_POINT/boot/efi"
    umount "$MOUNT_POINT"

    log "=== Stage 1 complete ==="
    echo "Reboot, open your BIOS/UEFI boot menu, and select the SSD's 'ubuntu' entry."
    echo "If there are two 'ubuntu' entries (old HDD + new SSD), use 'efibootmgr -v' to"
    echo "identify the one with the SSD's GUID and reorder with 'efibootmgr -o'."
    echo "Verify with 'findmnt /' after rebooting before running the split-home stage."
}

# ---------------------------------------------------------------------------
# STAGE 2: SPLIT-HOME — shrink the old HDD partition, add a /home partition
# ---------------------------------------------------------------------------
stage_split_home() {
    local HDD_DEV="" OLD_ROOT_PART="" BACKUP_SIZE_GB=100 MOUNT_POINT="/mnt/newhome"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --disk) HDD_DEV="$2"; shift 2 ;;
            --old-root-part) OLD_ROOT_PART="$2"; shift 2 ;;
            --backup-size) BACKUP_SIZE_GB="$2"; shift 2 ;;
            *) die "Unknown option for split-home: $1" ;;
        esac
    done
    [[ -n "$HDD_DEV" && -n "$OLD_ROOT_PART" ]] || \
        die "split-home requires --disk /dev/sdY --old-root-part /dev/sdY2"
    [[ -b "$HDD_DEV" && -b "$OLD_ROOT_PART" ]] || die "Device not found."

    require_root
    check_dependencies parted rsync blkid partprobe mkfs.ext4 e2fsck resize2fs findmnt lsblk

    local CURRENT_ROOT; CURRENT_ROOT=$(findmnt -n -o SOURCE /)
    [[ "$CURRENT_ROOT" != "$OLD_ROOT_PART" ]] || \
        die "You are still booted from $OLD_ROOT_PART. Boot from the SSD first (run Stage 1 and reboot)."

    # This stage shrinks the existing filesystem with resize2fs, which only
    # understands ext2/3/4. Btrfs and XFS need entirely different tooling
    # (and XFS can't shrink at all), so refuse rather than risk corruption.
    local FS_TYPE; FS_TYPE=$(blkid -s TYPE -o value "$OLD_ROOT_PART" || true)
    case "$FS_TYPE" in
        ext2|ext3|ext4) ;;
        "") die "Could not determine the filesystem type of $OLD_ROOT_PART." ;;
        *) die "$OLD_ROOT_PART is $FS_TYPE, not ext2/3/4. This script's shrink step only supports ext-family filesystems (resize2fs) — Btrfs and XFS require different tools and are not supported here." ;;
    esac

    log "=== Current disk layout ==="
    lsblk; echo

    if findmnt "$OLD_ROOT_PART" >/dev/null 2>&1; then
        log "Unmounting $OLD_ROOT_PART..."
        umount "$OLD_ROOT_PART"
    fi

    confirm "This will shrink $OLD_ROOT_PART to ${BACKUP_SIZE_GB}GB and create a new /home partition on $HDD_DEV."

    log "=== Checking filesystem ==="
    e2fsck -f "$OLD_ROOT_PART"

    log "=== Shrinking filesystem to ${BACKUP_SIZE_GB}G ==="
    resize2fs "$OLD_ROOT_PART" "${BACKUP_SIZE_GB}G"

    # Determine the partition number and its start offset (machine-readable, robust to layout)
    local PART_NUM PART_START_MIB
    PART_NUM=$(echo "$OLD_ROOT_PART" | grep -oE '[0-9]+$')
    PART_START_MIB=$(parted -sm "$HDD_DEV" unit MiB print | awk -F: -v n="$PART_NUM" '$1==n{gsub("MiB","",$2); print int($2)}')
    [[ -n "$PART_START_MIB" ]] || die "Could not determine partition start offset."

    local NEW_END_MIB=$((PART_START_MIB + BACKUP_SIZE_GB * 1024 + 100))  # +100MiB buffer

    # Delete + recreate the partition at the smaller size instead of using
    # 'resizepart', which requires an interactive-only confirmation prompt
    # that cannot be reliably scripted across parted versions. The filesystem
    # was already shrunk above, so this is safe: the new partition still
    # starts at the same offset and is sized to comfortably contain it.
    log "=== Resizing partition (delete + recreate at new size) ==="
    parted -s "$HDD_DEV" -- rm "$PART_NUM"
    parted -s "$HDD_DEV" -- mkpart root ext4 "${PART_START_MIB}MiB" "${NEW_END_MIB}MiB"

    log "=== Creating new /home partition in freed space ==="
    parted -s "$HDD_DEV" -- mkpart home ext4 "${NEW_END_MIB}MiB" 100%
    partprobe "$HDD_DEV"; sleep 2

    local NEW_HOME_PART="${HDD_DEV}$((PART_NUM + 1))"
    [[ -b "$NEW_HOME_PART" ]] || NEW_HOME_PART="${HDD_DEV}p$((PART_NUM + 1))"
    [[ -b "$NEW_HOME_PART" ]] || die "Could not locate the new /home partition after creation."
    log "New /home partition: $NEW_HOME_PART"

    log "=== Formatting $NEW_HOME_PART ==="
    mkfs.ext4 -F "$NEW_HOME_PART"

    log "=== Copying current /home onto the new partition ==="
    mkdir -p "$MOUNT_POINT"
    mount "$NEW_HOME_PART" "$MOUNT_POINT"
    rsync -aAXv /home/ "$MOUNT_POINT/"

    log "=== Updating /etc/fstab ==="
    local NEW_HOME_UUID; NEW_HOME_UUID=$(blkid -s UUID -o value "$NEW_HOME_PART")
    cp /etc/fstab /etc/fstab.bak.homephase2
    if grep -q " /home " /etc/fstab; then
        die "/etc/fstab already has a /home entry. Check it manually before proceeding."
    fi
    echo "UUID=$NEW_HOME_UUID  /home  ext4  defaults  0  2" >> /etc/fstab
    log "fstab entry added (backup at /etc/fstab.bak.homephase2):"
    tail -n 1 /etc/fstab

    umount "$MOUNT_POINT"

    log "=== Stage 2 complete ==="
    echo "Reboot now, then verify with:"
    echo "  df -h /home   (should show $NEW_HOME_PART)"
    echo "Your old /home data is still present, hidden under the SSD's root filesystem,"
    echo "until you run the cleanup stage."
}

# ---------------------------------------------------------------------------
# STAGE 3: CLEANUP — remove the redundant /home copy left on the SSD
# ---------------------------------------------------------------------------
stage_cleanup() {
    local HOME_PART="" BIND_POINT="/mnt/oldroot"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --home-part) HOME_PART="$2"; shift 2 ;;
            *) die "Unknown option for cleanup: $1" ;;
        esac
    done
    [[ -n "$HOME_PART" ]] || die "cleanup requires --home-part /dev/sdYn"
    [[ -b "$HOME_PART" ]] || die "$HOME_PART is not a block device."

    require_root

    local ACTUAL_HOME_SRC; ACTUAL_HOME_SRC=$(findmnt -n -o SOURCE /home || true)
    [[ "$ACTUAL_HOME_SRC" == "$HOME_PART" ]] || \
        die "/home is not currently mounted from $HOME_PART (it's on '$ACTUAL_HOME_SRC'). Refusing to proceed — did Stage 2 finish and did you reboot?"

    local ROOT_SRC; ROOT_SRC=$(findmnt -n -o SOURCE /)
    [[ "$ROOT_SRC" != "$HOME_PART" ]] || die "Root and /home are the same device — nothing to clean up."

    # Plain (non-recursive) bind mount of / exposes the underlying directory
    # that /home is mounted over, without following the /home mount itself.
    # This lets us see and remove the leftover copy without ever unmounting
    # the live /home — avoiding the "target is busy" trap entirely.
    log "=== Mounting a bind view of the root filesystem ==="
    mkdir -p "$BIND_POINT"
    mount --bind / "$BIND_POINT"

    if [[ ! -d "$BIND_POINT/home" ]]; then
        umount "$BIND_POINT"
        die "$BIND_POINT/home doesn't exist — aborting for safety."
    fi

    log "Leftover copy found at $BIND_POINT/home:"
    ls "$BIND_POINT/home"
    du -sh "$BIND_POINT/home" 2>/dev/null || true

    confirm "This will permanently delete the above leftover copy from the SSD (your real /home on $HOME_PART is untouched)."

    rm -rf "${BIND_POINT:?}/home"/* "${BIND_POINT:?}/home"/.[!.]* 2>/dev/null || true
    umount "$BIND_POINT"

    log "=== Stage 3 complete ==="
    df -h /
    df -h /home
}

# ---------------------------------------------------------------------------
# DISPATCH
# ---------------------------------------------------------------------------
case "$STAGE" in
    clone)      stage_clone "$@" ;;
    split-home) stage_split_home "$@" ;;
    cleanup)    stage_cleanup "$@" ;;
    *) usage ;;
esac
