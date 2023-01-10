#!/bin/sh

# make a read-only nfsroot writeable by using overlayfs
# the nfsroot is already mounted to $NEWROOT
# add the parameter rootovl to the kernel, to activate this feature

. /lib/dracut-lib.sh

if ! getargbool 0 rootovl ; then
    return
fi

modprobe overlay

# a little bit tuning
mount -o remount,noatime $NEWROOT

# Move root
# --move does not always work. Google >mount move "wrong fs"< for
#     details
mkdir -p /live/image
mount --bind $NEWROOT /live/image
umount $NEWROOT

# Create tmpfs
mkdir /cow
mount -n -t tmpfs -o mode=0755 tmpfs /cow
mkdir /cow/work /cow/rw /cow/config-work /cow/config-rw /cow/lower
echo "VAUBAN/ Mounting rootfs kin overlayfs for conffs" >> /dev/kmsg
mount -t overlay -o noatime,lowerdir=/live/image,upperdir=/cow/config-rw,workdir=/cow/config-work,default_permissions overlay /cow/lower

if [ -d /updates -o /run/initramfs/live/updates ]; then
    echo "VAUBAN/ Mounting conffs" > /dev/kmsg
    mount -o bind /run /cow/lower/run
    for d in /updates /run/initramfs/live/updates; do
        [ -d "$d" ] || continue
        (
            cd $d
            find . -depth -type d | while read dir; do
                mkdir -p "/cow/lower/$dir"
            done
            find . -depth \! -type d | while read file; do
                cp -a "$file" "/cow/lower/$file"
            done
        )
    done
    umount /cow/lower/run
else
    echo "VAUBAN/ No conffs to mount" > /dev/kmsg
fi


echo "VAUBAN/ Overlayfs on rootfs + (?conffs)" > /dev/kmsg
# Merge both to new Filesystem
mount -t overlay -o noatime,lowerdir=/cow/lower,upperdir=/cow/rw,workdir=/cow/work,default_permissions overlay $NEWROOT

# Let filesystems survive pivot
mkdir -p $NEWROOT/live/cow
mkdir -p $NEWROOT/live/image
mount --bind /cow/rw $NEWROOT/live/cow
umount /cow
mount --bind /live/image $NEWROOT/live/image
umount /live/image
echo "VAUBAN/ rootfs mounted" > /dev/kmsg
