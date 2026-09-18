#!/usr/bin/env bash
# Construct the BlissOS 16 golden disk offline from the ISO, baking in:
#   * static dropbear sshd (root, pubkey) + scp
#   * adbd over TCP (5555)
#   * screen-off disabled (stay awake)
# Matches anyvm-org/blissos-builder hooks/offline-construct.sh, adapted to
# loop+kpartx (nbd module absent on this node).
set -Eeuo pipefail
cd /work
ASRC="blissos-16"
RAW=/work/golden.raw
M_TGT=/work/m_tgt
M_EFS=/work/m_efs

DB=/work/db/dropbear-2022.83
KEYDIR=/work/db
[ -x "$DB/dropbear" ] || { echo "dropbear not built"; exit 1; }
[ -s "$KEYDIR/dropbear_rsa_host_key" ] || { echo "host keys missing"; exit 1; }

# host key authorized key: generate a fresh build key if absent
[ -e /root/.ssh/id_rsa ] || ssh-keygen -f /root/.ssh/id_rsa -q -N ""
HOST_PUB="$(cat /root/.ssh/id_rsa.pub)"
[ -e /work/guest_id_rsa ] || ssh-keygen -f /work/guest_id_rsa -q -N ""

echo "=== create 20G raw target ==="
rm -f "$RAW"; truncate -s 20G "$RAW"
L="$(losetup -f --show "$RAW")"
echo "loop=$L"
parted -s "$L" mklabel msdos
parted -s "$L" mkpart primary ext4 1MiB 100%
parted -s "$L" set 1 boot on
kpartx -a "$L"
P="/dev/mapper/$(basename "$L")p1"
mkfs.ext4 -F -L BlissOS "$P"
mkdir -p "$M_TGT"; mount "$P" "$M_TGT"

echo "=== populate /$ASRC ==="
mkdir -p "$M_TGT/$ASRC/data/dropbear/.ssh"
cp /work/iso/kernel     "$M_TGT/$ASRC/kernel"
cp /work/iso/initrd.img "$M_TGT/$ASRC/initrd.img"
cp /work/efsx/system.img "$M_TGT/$ASRC/system.img"
file "$M_TGT/$ASRC/system.img"

# grow system.img for dropbear
truncate -s +128M "$M_TGT/$ASRC/system.img"
e2fsck -fy "$M_TGT/$ASRC/system.img" >/dev/null 2>&1 || true
resize2fs "$M_TGT/$ASRC/system.img" >/dev/null

echo "=== bake dropbear into system.img ==="
M_SYS=/work/m_sys; mkdir -p "$M_SYS"
mount -o loop,rw "$M_TGT/$ASRC/system.img" "$M_SYS"
if [ -d "$M_SYS/system/bin" ]; then R="$M_SYS/system"; else R="$M_SYS"; fi
echo "system root=$R"
install -m 0755 "$DB/dropbear" "$R/bin/dropbear"
install -m 0755 "$DB/scp"      "$R/bin/scp"

printf 'root:x:0:0:root:/data/dropbear:/system/bin/sh\n' > "$R/etc/passwd"
printf '/system/bin/sh\n/bin/sh\n' > "$R/etc/shells"

cat > "$R/etc/init/dropbear.rc" <<'RC'
service dropbear /system/bin/dropbear -F -E -s -p 22 -r /data/dropbear/dropbear_rsa_host_key -r /data/dropbear/dropbear_ed25519_host_key
    class main
    user root
    group root shell inet net_admin
    oneshot

on post-fs-data
    start dropbear

on property:sys.boot_completed=1
    start dropbear
RC

cat > "$R/etc/init/anyvm-stayawake.rc" <<'RC'
on property:sys.boot_completed=1
    exec_background - root root -- /system/bin/sh -c "settings put system screen_off_timeout 2147483647; settings put secure sleep_timeout 2147483647; svc power stayon true; setprop service.adb.tcp.port 5555; setprop persist.adb.tcp.port 5555; setprop ctl.restart adbd"
RC

_bp="$(find "$M_SYS" -maxdepth 3 -name build.prop | head -1)"
if [ -n "$_bp" ]; then
  printf '\nservice.adb.tcp.port=5555\npersist.adb.tcp.port=5555\nro.adb.secure=0\n' >> "$_bp"
fi
sync -f "$M_SYS" 2>/dev/null || sync
umount "$M_SYS"

echo "=== /data ssh material ==="
cp "$KEYDIR/dropbear_rsa_host_key"     "$M_TGT/$ASRC/data/dropbear/dropbear_rsa_host_key"
cp "$KEYDIR/dropbear_ed25519_host_key" "$M_TGT/$ASRC/data/dropbear/dropbear_ed25519_host_key"
printf '%s\n' "$HOST_PUB" > "$M_TGT/$ASRC/data/dropbear/.ssh/authorized_keys"
cp /work/guest_id_rsa     "$M_TGT/$ASRC/data/dropbear/.ssh/id_rsa"
cp /work/guest_id_rsa.pub "$M_TGT/$ASRC/data/dropbear/.ssh/id_rsa.pub"
chmod 700 "$M_TGT/$ASRC/data/dropbear/.ssh"
chmod 600 "$M_TGT/$ASRC/data/dropbear/.ssh/authorized_keys" "$M_TGT/$ASRC/data/dropbear/.ssh/id_rsa"

echo "=== GRUB (BIOS) ==="
grub-install --target=i386-pc --boot-directory="$M_TGT/boot" \
  --modules="part_msdos ext2 normal linux search configfile echo" "$L"
cat > "$M_TGT/boot/grub/grub.cfg" <<CFG
set timeout=2
set default=0
menuentry "BlissOS 16" {
    search --no-floppy --set=root -f /$ASRC/kernel
    linux /$ASRC/kernel root=/dev/ram0 SRC=/$ASRC androidboot.selinux=permissive HWACCEL=0
    initrd /$ASRC/initrd.img
}
CFG

sync -f "$M_TGT" 2>/dev/null || sync
umount "$M_TGT"
kpartx -d "$L"
losetup -d "$L"

echo "=== convert raw -> qcow2 ==="
qemu-img convert -O qcow2 -o lazy_refcounts=on "$RAW" /work/golden.qcow2
rm -f "$RAW"
ls -la /work/golden.qcow2
qemu-img info /work/golden.qcow2
echo DONE
