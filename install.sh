#!/usr/bin/env bash
set -e

DEV=$1
ROOT=${2:-$(mktemp -d)}
ROOT=$(realpath "$ROOT")

read -p "Username: " USER
read -p "Password: " -s PASSWORD

# Create partitions
blkdiscard -f "${DEV}"
parted --script "${DEV}" mklabel gpt
parted --script -a optimal "${DEV}" unit MiB mkpart esp fat32 1 1025
parted --script -a optimal "${DEV}" unit MiB mkpart swap 1025 17408  # 16GB swap
parted --script -a optimal "${DEV}" unit MiB mkpart root btrfs 17408 100%
parted --script "${DEV}" set 1 esp on

# Format partitions
DEVS=($(lsblk -np -x PATH -o PATH,TYPE "$DEV" | awk 'NF==2 && $2 == "part" {print $1}'))
ESP_DEV=${DEVS[0]}
SWAP_DEV=${DEVS[1]}
ROOT_DEV=${DEVS[2]}

mkfs.fat -F 32 -n ESP "$ESP_DEV"
mkfs.btrfs -f -L ROOT "$ROOT_DEV"

# Create btrfs subvols
mount "$ROOT_DEV" "$ROOT"
btrfs sub create "${ROOT}/@arch_root"
btrfs sub create "${ROOT}/@home"
umount "$ROOT"

# Generate fstab
partprobe
ESP_UUID=$(blkid -s UUID -o value "$ESP_DEV")
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV")
sed "s|ESPDEV|UUID=${ESP_UUID}|g;s|SWAPDEV|/dev/mapper/cryptswap|g;s|ROOTDEV|UUID=${ROOT_UUID}|g" fstab.in > fstab

# Mount partitions & install fstab
mount / --target-prefix "$ROOT" --fstab ./fstab
mount -a --target-prefix "$ROOT" --fstab ./fstab -o X-mount.mkdir
mkdir "${ROOT}/etc/"
cp ./fstab "${ROOT}/etc/"

# Install crypttab
SWAP_PARTUUID=$(blkid -s PARTUUID -o value "$SWAP_DEV")
sed "s/SWAPDEV/PARTUUID=${SWAP_PARTUUID}/g" crypttab.in > "${ROOT}/etc/crypttab"

# Install kernel cmdline
mkdir "${ROOT}/etc/cmdline.d"
sed "s/ROOTDEV/UUID=${ROOT_UUID}/g" cmdline.d/root.conf.in > "${ROOT}/etc/cmdline.d/root.conf"

# Bootstrap
pacstrap "$ROOT" base $(find packages.d -exec cat {} + | xargs)

# Use systemd-resolved stub-resolve.conf
ln -sf ../run/systemd/resolve/stub-resolv.conf "${ROOT}/etc/resolv.conf"

# Finish install in chroot
arch-chroot "$ROOT" << EOF
pacman --noconfirm -Syyu

ln -sf /usr/share/zoneinfo/US/Eastern /etc/localtime
hwclock --systohc

sed -i '/en_US.UTF-8/s/^#//g' /etc/locale.gen
locale-gen
echo LANG=en_US.UTF-8 > /etc/locale.conf

bootctl install

# Use systemd init instead of busybox
sudo sed -i '/^HOOKS/s/base udev/systemd/' /etc/mkinitcpio.conf
sudo sed -i '/^HOOKS/s/keymap consolefont/sd-vconsole/' /etc/mkinitcpio.conf

# Use Plymouth for boot splash
sudo sed -i '/^HOOKS/s/block/& plymouth/' /etc/mkinitcpio.conf

# Enable UKI generation
sed -i '/^#\(default\|fallback\)_uki/s/^#//g' /etc/mkinitcpio.d/linux.preset
sed -i '/^\(default\|fallback\)_image/s/^/#/g' /etc/mkinitcpio.d/linux.preset
mkinitcpio -p linux

echo mspatz-desktop > /etc/hostname

systemctl enable sshd.service
systemctl enable systemd-timesyncd.service
systemctl enable docker.service
systemctl enable libvirtd.service
systemctl enable power-profiles-daemon.service

systemctl enable systemd-resolved.service


useradd -m -G adm,wheel,uucp,sys,docker $USER
echo "${USER}:${PASSWORD}" | chpasswd

echo '%wheel ALL=(ALL) ALL' > /etc/sudoers.d/wheel

echo 'export EDITOR=vim' > /etc/profile.d/editor.sh
chmod +x /etc/profile.d/editor.sh

EOF

# Snapshot the root btrfs subvol
btrfs sub snap -r "${ROOT}" "${ROOT}/mnt/btrfs_root/@arch_root_initial_ro"
