#!/usr/bin/env bash
# build-archiso.sh
# YAMLでカスタム可能な Arch Linux ISO ビルドスクリプト（UEFI対応）
# 依存: archiso, yq (v4), git（relengコピーが必要な場合）
set -euo pipefail



# ===== 設定 =====
WORKDIR="$PWD/work"
ISO_ROOT="$WORKDIR/iso"
AIROOTFS="$WORKDIR/airootfs"
ISO_NAME="frankos"
ISO_LABEL="FRANK_LIVE"
ISO_VERSION="$(date +%Y.%m.%d)"
OUTPUT="$PWD/out"
ARCH="x86_64"

# ===== 前準備 =====
echo "[*] 作業ディレクトリを初期化..."

rm -rf work/ out/ mnt_esp/
rm -rf "$WORKDIR" "$OUTPUT"
mkdir -p "$AIROOTFS" "$ISO_ROOT" "$OUTPUT"

# ===== ベースシステム作成 =====
echo "[*] ベースシステムを pacstrap でインストール..."
pacstrap  "$AIROOTFS" base linux linux-firmware vim networkmanager archiso mkinitcpio-archiso cinnamon lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings xorg-server noto-fonts noto-fonts-cjk noto-fonts-emoji fcitx5-im fcitx5-mozc fcitx5-configtool papirus-icon-theme eog
# ===== 設定ファイル追加 =====
echo "[*] 基本設定を投入..."
echo "keita" > "$AIROOTFS/etc/hostname"

cat <<EOF > "$AIROOTFS/etc/vconsole.conf"
KEYMAP=jp106
FONT=Lat2-Terminus16
EOF

cat <<EOF > "$AIROOTFS/etc/locale.gen"
en_US.UTF-8 UTF-8
ja_JP.UTF-8 UTF-8
EOF

mkdir -p "$AIROOTFS/etc/dconf/db/local.d"
cat <<EOF > "$AIROOTFS/etc/dconf/db/local.d/01-cinnamon"
[org/cinnamon/desktop/interface]
gtk-theme='Arc-Dark'
icon-theme='Papirus'
cursor-theme='Adwaita'
EOF
cat <<EOF > "$AIROOTFS/etc/dconf/db/local.d/05-language"
[org/cinnamon/desktop/interface]
gtk-im-module='ibus'
EOF
arch-chroot "$AIROOTFS" locale-gen
mkdir -p "$AIROOTFS/etc/pacman.d"
cp /etc/pacman.conf "$AIROOTFS/etc/"
cp /etc/pacman.d/mirrorlist "$AIROOTFS/etc/pacman.d/"
echo "LANG=ja_JP.UTF-8" > "$AIROOTFS/etc/locale.conf"


mkdir -p "$AIROOTFS/etc/lightdm"
sed -i 's/^#autologin-user=.*/autologin-user=root/' "$AIROOTFS/etc/lightdm/lightdm.conf"
sed -i 's/^#autologin-session=.*/autologin-session=cinnamon/' "$AIROOTFS/etc/lightdm/lightdm.conf"

# chroot先で archiso パッケージをインストール

# archisoパッケージ導入とHOOKS設定
mkdir -p "$AIROOTFS/usr/share/backgrounds/gnome"
cp image.png "$AIROOTFS/usr/share/backgrounds/gnome/"
mkdir -p "$AIROOTFS/etc/dconf/db/local.d"
cat <<EOF > "$AIROOTFS/etc/dconf/db/local.d/00-wallpaper"
[org/cinnamon/desktop/background]
picture-uri='file:///usr/share/backgrounds/gnome/image.png'
EOF


mkdir -p "$AIROOTFS/etc/profile.d"
cat <<'EOF' > "$AIROOTFS/etc/profile.d/fcitx5.sh"
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
EOF
mkdir -p "$AIROOTFS/etc/skel/.config"
cat <<EOF > "$AIROOTFS/etc/skel/.config/user-dirs.locale"
ja_JP
EOF


arch-chroot "$AIROOTFS" systemctl set-default graphical.target
arch-chroot "$AIROOTFS" systemctl enable lightdm

arch-chroot "$AIROOTFS" dconf update
sed -i 's/^HOOKS=.*/HOOKS=(base udev archiso block filesystems keyboard fsck)/' \
    "$AIROOTFS/etc/mkinitcpio.conf"

sed -i 's/^MODULES=.*/MODULES=(loop squashfs)/' "$AIROOTFS/etc/mkinitcpio.conf"

arch-chroot "$AIROOTFS" mkinitcpio -P 






mkdir -p "$ISO_ROOT/isolinux"
cp /usr/lib/syslinux/bios/isolinux.bin "$ISO_ROOT/isolinux/"
cp /usr/lib/syslinux/bios/ldlinux.c32 "$ISO_ROOT/isolinux/"
cp /usr/lib/syslinux/bios/menu.c32 "$ISO_ROOT/isolinux/"
cp /usr/lib/syslinux/bios/libcom32.c32 "$ISO_ROOT/isolinux/"
cp /usr/lib/syslinux/bios/libutil.c32 "$ISO_ROOT/isolinux/"

cat <<EOF > "$ISO_ROOT/isolinux/isolinux.cfg"
UI menu.c32
PROMPT 0
TIMEOUT 50
DEFAULT frankos

LABEL frankos
    MENU LABEL Boot FrankOS Live (BIOS)
    LINUX /vmlinuz-linux
    INITRD /initramfs-linux.img
    APPEND archisobasedir=arch archisolabel=FRANK_LIVE
EOF

# 鍵の初期化
arch-chroot "$AIROOTFS" pacman-key --init
arch-chroot "$AIROOTFS" pacman-key --populate archlinux

# pacman DBの初期化（念のため）
arch-chroot "$AIROOTFS" pacman -Sy --noconfirm

# 最新のmirrorlistをISOに組み込む
cp /etc/pacman.d/mirrorlist "$AIROOTFS/etc/pacman.d/"



# root パスワード設定（例: "root"）
echo "root:root" | arch-chroot "$AIROOTFS" chpasswd

# systemdサービス有効化
arch-chroot "$AIROOTFS" systemctl enable NetworkManager

# ===== カスタムファイル追加例 =====
mkdir -p "$AIROOTFS/root"
echo "Welcome to MyArch Live!" > "$AIROOTFS/root/README.txt"

# ===== squashfs 作成 =====
echo "[*] squashfs イメージ作成..."
mkdir -p "$ISO_ROOT/arch/$ARCH"
mksquashfs "$AIROOTFS" "$ISO_ROOT/arch/$ARCH/airootfs.sfs"  -comp xz -Xbcj x86


# ===== ブートローダー構築 (systemd-boot UEFI) =====
echo "[*] EFI ブートローダー準備..."
# 1. EFI用FATイメージ作成
dd if=/dev/zero of="$ISO_ROOT/efiboot.img" bs=1M count=200
mkfs.vfat "$ISO_ROOT/efiboot.img"


# 2. マウントしてファイルコピー
mkdir mnt_esp


# 2. マウントしてファイルコピー
sudo mount "$ISO_ROOT/efiboot.img" mnt_esp

mkdir -p mnt_esp/EFI/BOOT
cp /usr/lib/systemd/boot/efi/systemd-bootx64.efi mnt_esp/EFI/BOOT/BOOTX64.EFI
cp "$AIROOTFS/boot/vmlinuz-linux" mnt_esp/
cp "$AIROOTFS/boot/initramfs-linux.img" mnt_esp/
# loader.conf と arch.conf を配置
mkdir -p mnt_esp/loader/entries
cat <<EOF | sudo tee mnt_esp/loader/loader.conf
default  frank
timeout  3
console-mode max
editor   no
EOF

cat <<EOF | sudo tee mnt_esp/loader/entries/arch.conf
title   FrankOS Live (${ISO_VERSION})
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options archisobasedir=arch archisolabel=FRANK_LIVE
EOF

sudo umount -l mnt_esp
rmdir mnt_esp

# カーネルと initramfs を ISOルートにコピー
cp "$AIROOTFS/boot/vmlinuz-linux" "$ISO_ROOT/"
cp "$AIROOTFS/boot/initramfs-linux.img" "$ISO_ROOT/"

# ===== ISO 作成 =====
echo "[*] ISO イメージ生成..."
xorriso -as mkisofs \
  -eltorito-boot isolinux/isolinux.bin \
  -no-emul-boot \
  -boot-load-size 4 \
  -boot-info-table \
  -iso-level 3 \
  -full-iso9660-filenames \
  -volid FRANK_LIVE \
  -eltorito-alt-boot \
  -e efiboot.img \
  -no-emul-boot \
  -isohybrid-gpt-basdat \
  -output "${OUTPUT}/${ISO_NAME}-${ISO_VERSION}-${ARCH}.iso" \
  "$ISO_ROOT"

echo "[*] 完了! 出力: ${OUTPUT}/${ISO_NAME}-${ISO_VERSION}-${ARCH}.iso"
