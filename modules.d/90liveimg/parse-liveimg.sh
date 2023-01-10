#!/bin/sh
# live img images - live images from .img (or .tgz) files
# root=liveimg:[path-to-backing-file]

[ -z "$root" ] && root=$(getarg root=)

# live updates
updates=$(getarg liveimg.updates=)
if [ -n "$updates" ]; then
    echo "$updates" > /tmp/liveimgupdates.info
    echo '[ -e /tmp/liveimgupdates.done ]' > \
        "$hookdir"/initqueue/finished/liveimgupdates.sh
fi

str_starts "$root" "liveimg:" && livepath="$root"
str_starts "$livepath" "liveimg:" || return
livepath="${livepath#liveimg:}"

echo "VAUBAN: $livepath" >> /dev/kmsg
sleep 1

info "liveimg: looking for file in $livepath"
root="liveimg"
rootok=1
wait_for_dev -n /dev/root
/sbin/initqueue --settled --unique /sbin/liveimgroot "$livepath"
