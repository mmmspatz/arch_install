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
parted --script -a optimal "${DEV}" unit MiB mkpart esp fat32 1 513
parted --script -a optimal "${DEV}" unit MiB mkpart root btrfs 513 100%
parted --script "${DEV}" set 1 esp on

# Format partitions
DEVS=($(lsblk -np -x PATH -o PATH "$DEV"))
ESP_DEV=${DEVS[1]}
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
UUIDS=($(lsblk -np -x PATH -o UUID "$DEV"))
ESP_UUID=${UUIDS[0]}
ROOT_UUID=${UUIDS[1]}
sed "s/ESPDEV/UUID=${ESP_UUID}/g;s/ROOTDEV/UUID=${ROOT_UUID}/g" fstab.in > fstab

# Mount partitions & install fstab
mount / --target-prefix "$ROOT" --fstab ./fstab
mount -a --target-prefix "$ROOT" --fstab ./fstab -o X-mount.mkdir
mkdir "${ROOT}/etc/"
cp ./fstab "${ROOT}/etc/"

# Bootstrap
pacstrap "$ROOT" $(<packages.txt)

#enable multilib
cat << EOF >> "${ROOT}/etc/pacman.conf"
[multilib]
Include = /etc/pacman.d/mirrorlist
EOF

# Finish install in chroot
arch-chroot "$ROOT" << EOF
pacman --noconfirm -Syyu

ln -sf /usr/share/zoneinfo/US/Eastern /etc/localtime
hwclock --systohc

sed -i '/en_US.UTF-8/s/^#//g' /etc/locale.gen
locale-gen
echo LANG=en_US.UTF-8 > /etc/locale.conf

echo mspatz-desktop > /etc/hostname

systemctl enable sshd.service
systemctl enable NetworkManager.service
systemctl enable gdm.service
systemctl enable bluetooth.service
systemctl enable systemd-timesyncd.service
systemctl enable docker.service

grub-install --target=x86_64-efi --efi-directory=/boot/esp --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

useradd -m -G adm,wheel,uucp,sys,docker $USER
echo "${USER}:${PASSWORD}" | chpasswd

echo '%wheel ALL=(ALL) ALL' > /etc/sudoers.d/wheel

EOF

# Snapshot the root btrfs subvol
btrfs sub snap -r "${ROOT}" "${ROOT}/mnt/btrfs_root/@arch_root_initial_ro"
