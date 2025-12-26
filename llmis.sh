#!/usr/bin/env bash
# Lubi Linux minimal install on Artix: Linux + dinit + Limine + Btrfs + Snapper
# Author: Luca (Lubi)
# Purpose: Didactic, modular, reproducible installer without GUI.
# Mode: UEFI-only (no BIOS support)

set -Eeuo pipefail

#######################################
# CONFIGURACIÓN: AJUSTA ESTAS VARIABLES
#######################################

ESP_DEV="/dev/sda1"
SWAP_DEV="/dev/sda2"
ROOT_DEV="/dev/sda3"

ESP_LABEL="BOOT"
ROOT_LABEL="ROOT"

LOCALE="es_CL.UTF-8"
HOSTNAME="lubi"
TIMEZONE="America/Santiago"
KEYMAP="es"

NEW_USER="lubi"
NEW_USER_PASS="NewPass"
ROOT_PASS="NewPass"

KERNEL_PKG="linux"
INIT_SYS="dinit"
USE_LIMINE="yes"

BTRFS_OPTS="noatime,compress=zstd:3,space_cache=v2,ssd,discard=async"

#######################################
# FUNCIONES AUXILIARES
#######################################

msg() { printf "\n[INFO] %s\n" "$*"; }
err() { printf "\n[ERROR] %s\n" "$*" >&2; }
run() { echo "+ $*"; "$@"; }

require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { err "Comando requerido no encontrado: $c"; exit 1; }
  done
}

confirm_device() {
  lsblk -f "$ROOT_DEV" "$ESP_DEV" "$SWAP_DEV" || { err "Verifica dispositivos/particiones"; exit 1; }
}

#######################################
# PRECHECKS
#######################################

msg "Verificando comandos requeridos..."
require_cmd lsblk mkfs.btrfs mount umount btrfs blkid swapon mkswap pacstrap artix-chroot genfstab sed awk grep useradd passwd ln rsync

msg "Confirmando dispositivos..."
confirm_device

#######################################
# FORMATEO Y MONTAJES
#######################################

msg "Formateando ESP (UEFI-only, FAT32)..."
run mkfs.fat -F32 -n "$ESP_LABEL" "$ESP_DEV"

msg "Formateando SWAP..."
run mkswap "$SWAP_DEV"
run swapon "$SWAP_DEV"

msg "Formateando ROOT Btrfs..."
run mkfs.btrfs -f -L "$ROOT_LABEL" "$ROOT_DEV"

msg "Montando ROOT temporal para crear subvolúmenes..."
run mount -o "$BTRFS_OPTS" "$ROOT_DEV" /mnt

msg "Creando subvolúmenes Lubi..."
run btrfs subvolume create /mnt/@
run btrfs subvolume create /mnt/@system
run btrfs subvolume create /mnt/@home
run btrfs subvolume create /mnt/@var
run btrfs subvolume create /mnt/@log
run btrfs subvolume create /mnt/@snapshots
run btrfs subvolume create /mnt/@tmp

msg "Desmontando ROOT para remonte por subvolúmenes..."
run umount /mnt

msg "Montando subvolúmenes en estructura final..."
run mount -o "$BTRFS_OPTS",subvol=@ "$ROOT_DEV" /mnt
run mkdir -p /mnt/{boot,home,var,log,.snapshots,tmp,usr,etc}

run mount -o "$BTRFS_OPTS",subvol=@home      "$ROOT_DEV" /mnt/home
run mount -o "$BTRFS_OPTS",subvol=@var       "$ROOT_DEV" /mnt/var
run mount -o "$BTRFS_OPTS",subvol=@log       "$ROOT_DEV" /mnt/log
run mount -o "$BTRFS_OPTS",subvol=@snapshots "$ROOT_DEV" /mnt/.snapshots
run mount -o "$BTRFS_OPTS",subvol=@tmp       "$ROOT_DEV" /mnt/tmp
run mount -o "$BTRFS_OPTS",subvol=@system    "$ROOT_DEV" /mnt/usr

msg "Montando ESP en /boot/EFI..."
run mkdir -p /mnt/boot/EFI
run mount "$ESP_DEV" /mnt/boot/EFI

#######################################
# BASE DE SISTEMA: ARTIX + DINIT
#######################################

msg "Instalando base Artix..."
BASE_PKGS=(base "$KERNEL_PKG" linux-firmware btrfs-progs nano iproute2 iputils sudo)
INIT_PKGS=(dinit dinit-chroot)
BOOT_PKGS=(limine)
SNAP_PKGS=(snapper cronie)
CORE_SERVICES=(syslog-ng chrony seatd pipewire wireplumber nftables acpid dbus cups bluez networkmanager)
DINIT_SCRIPTS=(syslog-ng-dinit chrony-dinit seatd-dinit pipewire-dinit wireplumber-dinit nftables-dinit acpid-dinit dbus-dinit cups-dinit bluez-dinit networkmanager-dinit cronie-dinit snapper-dinit)

run pacstrap /mnt "${BASE_PKGS[@]}" "${INIT_PKGS[@]}" "${BOOT_PKGS[@]}" "${SNAP_PKGS[@]}" "${CORE_SERVICES[@]}" "${DINIT_SCRIPTS[@]}"

msg "Generando fstab..."
run genfstab -U /mnt >> /mnt/etc/fstab

#######################################
# CONFIGURACIÓN EN CHROOT
#######################################

msg "Entrando a chroot..."
artix-chroot /mnt /bin/bash -e <<'CHROOT'
set -Eeuo pipefail
msg() { printf "\n[CHROOT] %s\n" "$*"; }
run() { echo "+ $*"; "$@"; }

# --- Locales, zona horaria, hostname ---
msg "Locales y zona horaria..."
echo "es_CL.UTF-8 UTF-8" >> /etc/locale.gen
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=es_CL.UTF-8" > /etc/locale.conf
ln -sf /usr/share/zoneinfo/America/Santiago /etc/localtime
hwclock --systohc
echo "KEYMAP=es" > /etc/vconsole.conf

echo "lubi" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   lubi.localdomain lubi
EOF

# --- Configuraciones mínimas de servicios ---
msg "Configuraciones mínimas para estabilidad..."

# syslog-ng
cat > /etc/syslog-ng/syslog-ng.conf <<'EOF'
@version: 3.38
@include "scl.conf"
source s_src { system(); internal(); };
destination d_mesg { file("/var/log/messages"); };
log { source(s_src); destination(d_mesg); };
EOF

# chrony
cat > /etc/chrony.conf <<'EOF'
pool pool.ntp.org iburst
driftfile /var/lib/chrony/drift
rtcsync
makestep 1.0 3
EOF

# nftables
cat > /etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
  set allowed_tcp_ports { type inet_service; elements = { 22 } } # ajusta según necesidad
  chain input {
    type filter hook input priority 0;
    policy drop;

    iif lo accept
    ct state established,related accept

    # ICMP básico
    ip protocol icmp accept
    ip6 nexthdr icmpv6 accept

    # DHCP/MDNS útiles en LAN (ajusta según necesidad)
    udp dport { 67, 68, 5353 } accept

    # Permitir SSH si lo usas
    tcp dport @allowed_tcp_ports accept

    # Permitir tráfico desde la red local (ejemplo 192.168.0.0/16)
    ip saddr 192.168.0.0/16 accept
    ip6 saddr fc00::/7 accept
  }
  chain forward { type filter hook forward priority 0; policy drop; }
  chain output  { type filter hook output  priority 0; policy accept; }
}
EOF

# NetworkManager (ajuste mínimo; usa iwd si está presente)
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/wifi.conf <<'EOF'
[device]
wifi.backend=iwd
EOF

# BlueZ
mkdir -p /etc/bluetooth
cat > /etc/bluetooth/main.conf <<'EOF'
[General]
Name = Lubi
Class = 0x000100
DiscoverableTimeout = 0
PairableTimeout = 0
EOF

# DBus (generalmente no requiere cambios)
# PipeWire/WirePlumber: se inician en sesión de usuario; mantener instalados.

# --- Habilitar servicios dinit ---
msg "Habilitando servicios con dinit..."
mkdir -p /etc/dinit.d
if command -v dinitctl >/dev/null 2>&1; then
  for svc in syslog-ng chrony seatd pipewire wireplumber nftables acpid dbus cups bluez NetworkManager crond snapper; do
    dinitctl enable "$svc" || true
  done
fi

# --- Sudoers ---
msg "Sudoers..."
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# --- Usuario inicial ---
msg "Usuario inicial..."
useradd -m -G wheel -s /bin/bash "lubi"
echo "lubi:NewPass" | chpasswd
echo "root:NewPass" | chpasswd
mkdir -p /home/lubi/user
chown -R lubi:lubi /home/lubi

# --- Snapper: crear configs y política básica ---
msg "Snapper..."
snapper -c root create-config /
snapper -c home create-config /home || true
snapper -c system create-config /usr || true
snapper -c user create-config /home/lubi/user || true

# Política mínima (timeline diaria, límite de cantidad)
for cfg in root home system user; do
  conf="/etc/snapper/configs/$cfg"
  if [ -f "$conf" ]; then
    sed -i 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="yes"/' "$conf"
    sed -i 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="0"/' "$conf"
    sed -i 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="7"/' "$conf"
    sed -i 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="4"/' "$conf"
    sed -i 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="6"/' "$conf"
    sed -i 's/^TIMELINE_LIMIT_YEARLY=.*/TIMELINE_LIMIT_YEARLY="2"/' "$conf"
  fi
done

# Cron jobs para Snapper (timeline diaria a las 03:00 y cleanup semanal)
install -Dm755 /dev/stdin /etc/cron.daily/snapper-timeline <<'EOF'
#!/bin/sh
snapper -c root create -d "daily" >/dev/null 2>&1 || true
snapper -c home create -d "daily" >/dev/null 2>&1 || true
snapper -c system create -d "daily" >/dev/null 2>&1 || true
snapper -c user create -d "daily" >/dev/null 2>&1 || true
EOF
install -Dm755 /dev/stdin /etc/cron.weekly/snapper-cleanup <<'EOF'
#!/bin/sh
snapper -c root cleanup timeline >/dev/null 2>&1 || true
snapper -c home cleanup timeline >/dev/null 2>&1 || true
snapper -c system cleanup timeline >/dev/null 2>&1 || true
snapper -c user cleanup timeline >/dev/null 2>&1 || true
EOF

# --- mkinitcpio ---
msg "mkinitcpio..."
if [ -f /etc/mkinitcpio.conf ]; then
  sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block filesystems keyboard)/' /etc/mkinitcpio.conf
  mkinitcpio -P
fi

# --- Limine (UEFI-only) ---
msg "Limine (UEFI-only)..."
mkdir -p /boot/EFI/BOOT
cat > /boot/EFI/BOOT/limine.conf <<'EOF'
TIMEOUT=5
DEFAULT_ENTRY=Artix Lubi

:Artix Lubi
PROTOCOL=linux
KERNEL_PATH=boot:///vmlinuz-linux
CMDLINE=root=LABEL=LUBIROOT rw rootflags=subvol=@ loglevel=3 quiet
MODULE_PATH=boot:///initramfs-linux.img
EOF

if [ -f /usr/share/limine/BOOTX64.EFI ]; then
  cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI
fi
if [ -f /usr/share/limine/BOOTIA32.EFI ]; then
  cp /usr/share/limine/BOOTIA32.EFI /boot/EFI/BOOT/BOOTIA32.EFI
fi

msg "Chroot finalizado."
CHROOT

#######################################
# CREAR @user COMO SUBVOL POR USUARIO
#######################################

msg "Creando subvolumen @user para el usuario inicial..."
run mount -o "$BTRFS_OPTS" "$ROOT_DEV" /mnt
run btrfs subvolume create /mnt/home/lubi/@user
run umount /mnt

msg "Remontando y aplicando @user..."
run mount -o "$BTRFS_OPTS",subvol=@ "$ROOT_DEV" /mnt
run mount -o "$BTRFS_OPTS",subvol=@home "$ROOT_DEV" /mnt/home

# Migrar contenido previo si existía
if [ -d /mnt/home/lubi/user ]; then
  msg "Migrando /home/lubi/user a subvol @user..."
  run rsync -aHAX --delete /mnt/home/lubi/user/ /mnt/home/lubi/@user/
  run rm -rf /mnt/home/lubi/user
fi

# Montar @user en punto final
run mkdir -p /mnt/home/lubi/user
run mount -o "$BTRFS_OPTS",subvol=/home/lubi/@user "$ROOT_DEV" /mnt/home/lubi/user
run chown -R 1000:1000 /mnt/home/lubi/user  # UID/GID del usuario inicial

# Añadir entrada de fstab para @user (se crea después de genfstab)
cat >> /mnt/etc/fstab <<EOF

# Lubi user subvolume
LABEL=$ROOT_LABEL /home/lubi/user btrfs $BTRFS_OPTS,subvol=/home/lubi/@user 0 0
EOF

#######################################
# VERIFICACIÓN Y SALIDA
#######################################

msg "Mostrando fstab resultante:"
cat /mnt/etc/fstab

msg "Árbol de montajes actual:"
run lsblk -f

msg "Instalación base completada con núcleo de escritorio completo (UEFI-only)."
echo "Para finalizar: umount -R /mnt && swapoff $SWAP_DEV && reboot"
