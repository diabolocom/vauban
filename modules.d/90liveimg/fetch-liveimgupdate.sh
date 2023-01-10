#!/bin/sh
# fetch-liveimgupdate - fetch an update image for dmsquash-live media.

# no updates requested? we're not needed.
[ -e /tmp/liveimgupdates.info ] || return 0

command -v getarg > /dev/null || . /lib/dracut-lib.sh
command -v unpack_img > /dev/null || . /lib/img-lib.sh

read -r path_to_file < /tmp/liveimgupdates.info

info "fetching live updates from $path_to_file"

echo "Trying to get $path_to_file" >> /dev/kmsg
sleep 5

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

if ! file_fetch_path "$path_to_file" /tmp/updates.img; then
    echo "VAUBAN: failed to find $path_to_file" >> /dev/kmsg
    warn "failed to fetch update image!"
    warn "path: $path_to_file"
    sleep 5
    return 1
fi

if ! unpack_img /tmp/updates.img /updates.tmp.$$; then
    echo "VAUBAN: failed to unpack /tmp/updates.img" >> /dev/kmsg
    ls -lah "/tmp/updates.img" >> /dev/kmsg
    warn "failed to unpack update image!"
    warn "path: $path_to_file"
    sleep 5
    return 1
fi

copytree /updates.tmp.$$ /updates
mv /tmp/liveimgupdates.info /tmp/liveimgupdates.done
