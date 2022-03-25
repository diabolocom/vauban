#!/bin/bash

check() {
    # do not add modules if the kernel does not have overlayfs support
    [ -d /lib/modules/$kernel/kernel/fs/overlayfs ] || return 1
}

depends() {
    # We do not depend on any modules - just some root
    return 0
}

# called by dracut
installkernel() {
    instmods overlay
}

install() {
    inst_hook pre-pivot 10 "$moddir/overlay-mount.sh"
}
