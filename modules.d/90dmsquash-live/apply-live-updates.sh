#!/bin/sh

if [ -h /dev/root ] && [ -d /run/initramfs/live/updates -o -d /updates ]; then
    info "Applying updates to live image..."
    echo "VAUBAN 90dmsquash-live: applying updates" >> /dev/kmsg
    mount -o bind /run $NEWROOT/run
    # avoid overwriting symlinks (e.g. /lib -> /usr/lib) with directories
    for d in /updates /run/initramfs/live/updates; do
        [ -d "$d" ] || continue
        (
            cd $d
            find . -depth -type d | while read dir; do
                mkdir -p "$NEWROOT/$dir"
            done
            find . -depth \! -type d | while read file; do
                cp -a "$file" "$NEWROOT/$file"
            done

            find . -depth -type d | while read dir; do
                mkdir -p "/sysroot/$dir" || true
            done
            find . -depth \! -type d | while read file; do
                cp -a "$file" "/sysroot/$file" || true
            done
        )
    done
    umount $NEWROOT/run
fi
# release resources on iso-scan boots with rd.live.ram
if [ -d /run/initramfs/isoscan ] &&
   [ -f /run/initramfs/squashed.img -o -f /run/initramfs/rootfs.img ]; then
    umount --detach-loop /run/initramfs/live
    umount /run/initramfs/isoscan
fi
