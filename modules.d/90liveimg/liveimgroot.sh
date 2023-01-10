#!/bin/sh
# liveimgroot - fetch a live image from a disk

type getarg > /dev/null 2>&1 || . /lib/dracut-lib.sh

PATH=/usr/sbin:/usr/bin:/sbin:/bin

[ -e /tmp/liveroot.downloaded ] && exit 0

livepath="$1"
info "fetching $livepath"
echo "VAUBAN fetching $livepath" >> /dev/kmsg



file_fetch_path() {
    local path_to_file="$1" outloc="$2"
    file="/${path_to_file##*//}"
    dev="${path_to_file%%//*}"
    echo "VAUBAN file is $file" >> /dev/kmsg
    echo "VAUBAN dev is $dev" >> /dev/kmsg
    mkdir -p /run/liveimg_file || return 253
    echo "VAUBAN attempting to mount $dev" >> /dev/kmsg
    mount -t auto -o ro "$dev" /run/liveimg_file >> /dev/kmsg 2>> /dev/kmsg || return 253
    echo "VAUBAN mount successful. Looking for $file" >> /dev/kmsg
    cp -f -- "/run/liveimg_file/$file" "$outloc" || return $?
    echo "VAUBAN $file found and cp-ed to $outloc" >> /dev/kmsg
    umount /run/liveimg_file || true
}

local outdir
outdir="$(mkuniqdir /tmp liveimgroot)"
cd "$outdir" || exit
# shellcheck disable=SC2086
file_fetch_path "$livepath" "$outdir/root.tgz"
if [ $? != 0 ]; then
    warn "failed to find live image: error $?"
    imgfile=
    echo "VAUBAN: no root file found in $livepath" >> /dev/kmsg
    sleep 1200
else
    echo "VAUBAN found file, put in $outdir/root.tgz" >> /dev/kmsg
    imgfile="$outdir/root.tgz"
fi

if [ "${imgfile##*.}" = "iso" ]; then
    root=$(losetup -f)
    losetup "$root" "$imgfile"
else
    root=$imgfile
fi

echo "VAUBAN: calling dmsquash-live-root $root" >> /dev/kmsg

echo ok > /tmp/liveroot.downloaded

exec /sbin/dmsquash-live-root "$root"
