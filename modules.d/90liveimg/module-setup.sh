#!/bin/bash
# module-setup.sh for liveimg

# called by dracut
check() {
    return 255
}

# called by dracut
depends() {
    echo dmsquash-live img-lib bash
    return 0
}

# called by dracut
install() {
    inst_hook cmdline 29 "$moddir/parse-liveimg.sh"
    inst_hook initqueue/settled 95 "$moddir/fetch-liveimgupdate.sh"
    inst_script "$moddir/liveimgroot.sh" "/sbin/liveimgroot"
    if dracut_module_included "systemd-initrd"; then
        inst_script "$moddir/liveimg-generator.sh" "$systemdutildir"/system-generators/dracut-liveimg-generator
    fi
    dracut_need_initqueue
}
