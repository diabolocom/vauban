#!/usr/bin/env bash

# shellcheck disable=SC2029

function docker_import() {
    echo "Importing in docker the filesystem from the provided ISO"
    local name
    name="$1"
    echo "Creating $name/raw-iso"
    tar -C "fs-$_arg_iso" -c . | docker import - "$name/raw-iso"
}

function apply_stages() {
    # apply_stages will go from the image $source_name and will create $final_name by applying $stages
    # $prefix_name is the common prefix name to all the intermediate steps.
    # ie:
    # $source_name -> $prefix_name/$stage[1] -> $prefix_name/$stage[2] -> $final_name
    #
    # $hostname is the hostname to use for the image building process. This will
    # simulate the docker build instance like it was named $hostname

    local source_name="$1"
    shift
    local prefix_name="$1"
    shift
    local final_name="$1"
    shift
    local hostname="$1"
    shift
    stages=$*

    docker image inspect "$source_name" > /dev/null 2>&1 || pull_image "$source_name"

    local iter_source_name="$source_name"

    for stage in $stages; do
        if [[ "$stage" = *"@"* ]]; then
            local_branch="$(echo $stage | cut -d'@' -f1)"
            local_pb="$(echo $stage | cut -d'@' -f2)"
        else
            local_branch="$_arg_branch"
            local_pb="$stage"
        fi
        echo "Applying stage $stage to $iter_source_name (playbook $local_pb from branch $local_branch)"
        docker build \
            --build-arg SOURCE="${iter_source_name}" \
            --build-arg PLAYBOOK="$local_pb" \
            --build-arg BRANCH="$local_branch" \
            --build-arg HOOK_PRE_ANSIBLE="${HOOK_PRE_ANSIBLE:-}" \
            --build-arg HOOK_POST_ANSIBLE="${HOOK_POST_ANSIBLE:-}" \
            --build-arg ANSIBLE_EXTRA_ARGS="${ANSIBLE_EXTRA_ARGS:-}" \
            --build-arg ANSIBLE_ROOT_DIR="${ANSIBLE_ROOT_DIR:-}" \
            --build-arg HOSTNAME="$hostname" \
            --no-cache \
            -t "${prefix_name}/${local_pb}" \
            -f Dockerfile.stages .
        iter_source_name="${prefix_name}/${local_pb}"
    done
    echo "Tagging $final_name on $iter_source_name"
    docker tag "$iter_source_name" "$final_name"
}

function import_iso() {
    local name
    name="$1"
    docker_import "$name"
    docker build \
        --build-arg SSH_KEY="$(cat "$_arg_ssh_priv_key")" \
        --build-arg CACHE="$(date)" \
        --build-arg SOURCE="${name}/raw-iso" \
        --build-arg ISO="$_arg_iso" \
        --build-arg BRANCH="$_arg_branch" \
        -t "${name}/iso" \
        -f Dockerfile.base .
}

function put_sshd_keys() {
    local host
    local dest
    host="$1"
    dest="${2:-tmp}"

    set -x
    echo "Putting sshd keys for $hosts"

    cd vault
    if [[ ! -f "$host".tar.gpg ]]; then
        echo "Generating SSH keys for $host"
        mkdir -p "$host/etc/ssh"
        ssh-keygen -A -f "$host"
    else
        echo $VAULTED_SSHD_KEYS_KEY | gpg -d --no-symkey-cache --pinentry-mode loopback --passphrase-fd 0 "$host.tar.gpg" > "$host.tar"
        tar xvf "$host.tar"
    fi
    mkdir -p ../"$dest"/etc/ssh/
    cp -r "$host"/etc/ssh/* ../"$dest"/etc/ssh/
    chmod 0600 ../"$dest"/etc/ssh/ssh_host_*
    chmod 0644 ../"$dest"/etc/ssh/ssh_host_*.pub

    if [[ ! -f "$host.tar.gpg" ]]; then
        tar cvf "$host.tar" "$host"
        echo $VAULTED_SSHD_KEYS_KEY | gpg -c --no-symkey-cache --pinentry-mode loopback --passphrase-fd 0 "$host.tar" # > "$host.tar.gpg"
    fi
    rm -rf "$host" "$host.tar"
    cd ..
}

function build_rootfs() {
    local image_name="$1"

    rm -rf tmp && mkdir tmp
    echo "Creating rootfs from $image_name"
    docker create --name $$ "$image_name" --entrypoint bash
    cd tmp && docker export $$ | tar x
    docker rm $$
    cd ..
    chroot "tmp" bin/bash << "EOF"
    cd etc
    ln -sfr /run/resolvconf/resolv.conf resolv.conf  # We must do that here because docker mounts resolv.conf
    cd ..
    if [[ -d /toslash ]]; then
        cp -r /toslash/* / && rm -rf /toslash  # This is also to allow us to write things in /etc/hostname or /etc/hosts
    fi
    apt-get clean -y
    rm -rf root/.ssh/id_ed25519 root/ansible boot/initrd* /var/lib/apt/lists/* || true
EOF
    put_sshd_keys "$image_name"
    echo "Compressing rootfs"
    mksquashfs tmp rootfs.img -noappend -always-use-fragments -comp xz -no-exports
    tar cvf rootfs.tgz rootfs.img
}

function build_conffs_given_host() {
    local host="$1"
    local source_name="$2"
    local prefix_name="$3"

    printf "Building conffs for host=%s" "$host"
    apply_stages "$source_name" "$prefix_name" "$prefix_name" "$host" "${_arg_stages[@]}"
    mkdir -p overlayfs && cd overlayfs
    overlayfs_args=""
    first="yes"
    for stage in "${_arg_stages[@]}"; do
        if [[ "$stage" = *"@"* ]]; then
            local_pb="$(echo $stage | cut -d'@' -f2)"
        else
            local_pb="$stage"
        fi
        layer_path="$(docker inspect "$prefix_name/$local_pb" | jq -r '.[0].GraphDriver.Data.UpperDir')"
        if [[ $first = "yes" ]] && [[ -n "$(find "$layer_path" -type c)" ]]; then
            echo "file deletion in first layer of conffs detected"
            echo "Incriminated files:"
            find "$layer_path" -type c
        fi
        first="no"
        overlayfs_args=":$layer_path$overlayfs_args"
    done
    mkdir -p "overlayfs-${host}/merged" "overlayfs-${host}/upperdir" "overlayfs-${host}/workdir" "overlayfs-${host}/lower" && cd "overlayfs-${host}"

    if [[ -n "$overlayfs_args" ]]; then
        mount -t overlay overlay -o "rw,lowerdir=lower$overlayfs_args,workdir=workdir,upperdir=upperdir,metacopy=off" merged
    else
        echo "WARNING: Creating some empty conffs !"
    fi
    rm -rf "conffs-$host.tgz"
    cd ../..
    put_sshd_keys "$host" "overlayfs/overlayfs-$host/merged"
    cd "overlayfs/overlayfs-${host}"
    cd merged
    if [[ -d toslash ]]; then cp -r toslash/* . && rm -rf toslash; fi
    rm -rf var/lib/apt/lists/*
    cd ..
    tar cvfz "conffs-$host.tgz" \
        -C merged \
        --exclude "var/log" \
        --exclude "var/cache" \
        --exclude "root/ansible" \
        . > /dev/null
    if [[ -n "$overlayfs_args" ]]; then
        umount merged
    fi
    cd ../..
}

function build_conffs() {
    get_conffs_hosts

    local source_name="$1"
    local prefix_name="$2"
    local pids=()
    local hosts_built=()
    local i
    i=0
    mkdir -p /tmp/vauban-logs/
    local build_time
    build_time="$(date --iso-8601=seconds)"
    add_section_to_recap "build_conffs: Hosts recap"
    add_content_to_recap ""  # newline
    for host in $hosts; do
        host_prefix_name="$prefix_name/$host"  # All intermediate images will be named name/host/stage
        # with name being the name of the OS being installed, like debian-10.8
        { set -x; trap - ERR; build_conffs_given_host "$host" "$source_name" "$host_prefix_name" > /tmp/vauban-logs/"$prefix_name-$host-$build_time" ; } &
        pids+=("$!")
        hosts_built+=("$host")
        i=$((i + 1))
        if [[ $((i % 20)) -eq 0 ]]; then
            wait_pids "pids" "hosts_built"
            pids=()
            hosts_built=()
        fi
    done
    wait_pids "pids" "hosts_built"
    wait
    add_content_to_recap ""  # newline
    if [[ -n ${CI+x} ]]; then
        add_to_recap "build_conffs: logs" "$(
            for f in $(find /tmp/vauban-logs/ -type f); do
                echo $f
                echo
                tail -n 6 "$f" || true
                echo
            done)"
    else
        add_to_recap "build_conffs: logs" "Conffs built. Check the build details in /tmp/vauban-logs/*-$build_time"
    fi
    ci_commit_sshd_keys
}

function chroot_dracut() {
    local modules
    local name
    local kernel_version
    name="$1"
    modules="$2"
    kernel_version="$3"

    cd "fs-$_arg_iso"
    mkdir -p proc sys dev
    mount -t proc /proc proc/
    mount --rbind /sys sys/
    mount --rbind /dev dev/
    mount --make-rslave sys/
    mount --make-rslave dev/
    cd ..

    cp dracut.conf "fs-$_arg_iso/"
    chroot "fs-$_arg_iso" bin/bash << "EOF"
    set -x;
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -o Dpkg::Options::="--force-confold" --force-yes -y openssh-server firmware-bnx2x
    cd tmp
    version="$(cat /etc/debian_version)"
    if [[ "$version" = "10."* ]]; then
        apt-get install -y -o Dpkg::Options::="--force-confold" --force-yes dracut dracut-core dracut-network 2>&1 > /dev/null || true
    else
        apt-get download dracut-core dracut-network dracut-live dracut-squash
        PATH=/usr/local/sbin:/usr/bin/:/sbin dpkg -i dracut*
        apt-get install -y --fix-broken
    fi
    version="$(cat /etc/debian_version)"
EOF
    chroot "fs-$_arg_iso" bin/bash << EOF
    [[ ! -d /fs-$_arg_iso ]] && ln -s / /fs-$_arg_iso
EOF
    put_sshd_keys "$name" "fs-$_arg_iso/"
    cp -r modules.d/* "fs-$_arg_iso/usr/lib/dracut/modules.d/"
    chroot "fs-$_arg_iso" bin/bash << EOF
    dracut -N --conf dracut.conf -f -k "$modules" initramfs.img $kernel_version 2>&1 > /dev/null;
    rm /fs-$_arg_iso;
EOF
    umount -R "fs-$_arg_iso"/proc
    umount -R "fs-$_arg_iso"/sys
    umount -R "fs-$_arg_iso"/dev
}

function build_initramfs() {
    mount_iso
    local kernel
    local kernel_version
    local modules
    local name
    name="$1"
    kernel="$(find_kernel)"
    kernel_version="$(get_kernel_version "$kernel")"

    cp "$kernel" ./vmlinuz

    modules="fs-$_arg_iso/usr/lib/modules/$kernel_version"
    if [ ! -d "$modules" ]; then
        printf "%s does not exist. Cannot find kernel modules for version %s" "$modules" "$kernel_version"
        exit 1
    fi
    chroot_dracut "$name" "$modules" "$kernel_version"
    mv "fs-$_arg_iso/initramfs.img" .
}

function upload() {
    bootstrap_upload_in_ci
    local master_name
    local upload_list
    local file
    local kernel_version
    master_name="${1}"
    kernel_version="${2:-}"
    upload_list="${3:-}"
    if [[ -z "$upload_list" ]]; then
        if [[ $_arg_initramfs = "yes" ]]; then
            upload_list="initramfs.img vmlinuz"
        fi;
        if [[ $_arg_rootfs = "yes" ]]; then
            upload_list="$upload_list rootfs.tgz"
        fi;
        if [[ $_arg_conffs = "yes" ]]; then
            upload_list="$upload_list overlayfs/overlayfs-*/conffs-*.tgz"
        fi;

        # if still empty, send everything
        if [[ -z "$upload_list" ]]; then
            upload_list="initramfs.img vmlinuz rootfs.tgz overlayfs-*/conffs-*.tgz"
        fi;
    fi;
    # Exand upload list
    add_to_recap upload "Uploaded: "$upload_list
    for host in $UPLOAD_HOSTS_LIST; do
        # Detect if needs to use sudo
        local opt_sudo=""
        ssh "$host" touch "$UPLOAD_DIR" || opt_sudo=sudo

        # don't quote opt_sudo to not call empty string if empty
        ssh "$host" $opt_sudo mkdir -p "$UPLOAD_DIR/$master_name/" "$UPLOAD_DIR/linux/"


        for file in $upload_list; do
            scp "$file" "$host:/tmp"
            remote_file="$(basename "$file")"

            if [[ "$file" == "vmlinuz" ]] || [[ "$file" == "initramfs.img" ]]; then
                if [[ -z "$kernel_version" ]]; then
                    echo kernel_version not defined and to be used. Aborting
                    exit 1
                fi
                remote_file="$file-$kernel_version"
                ssh "$host" $opt_sudo mv "/tmp/$file" "$UPLOAD_DIR/linux/$remote_file"
                ssh "$host" $opt_sudo chmod 0664 "$UPLOAD_DIR/linux/$remote_file"
            else
                if [[ "$file" == "rootfs.tgz" ]] && [[ -n "$kernel_version" ]]; then
                    ssh "$host" $opt_sudo rm "$UPLOAD_DIR/$master_name/vmlinuz" || true
                    ssh "$host" $opt_sudo rm "$UPLOAD_DIR/$master_name/initramfs.img" || true
                    ssh "$host" $opt_sudo ln -s "../linux/vmlinuz-$kernel_version" "$UPLOAD_DIR/$master_name/vmlinuz"
                    ssh "$host" $opt_sudo ln -s "../linux/initramfs.img-$kernel_version" "$UPLOAD_DIR/$master_name/initramfs.img"
                fi
                ssh "$host" $opt_sudo mv "/tmp/$remote_file" "$UPLOAD_DIR/$master_name/"
                ssh "$host" $opt_sudo chmod 0664 "$UPLOAD_DIR/$master_name/$remote_file"
            fi
        done
        if [[ -n $opt_sudo ]]; then
            ssh "$host" $opt_sudo chown -R "$UPLOAD_OWNER" "$UPLOAD_DIR/$master_name/" "$UPLOAD_DIR/linux/"
            ssh "$host" $opt_sudo chmod 775 -R "$UPLOAD_DIR/$master_name/" "$UPLOAD_DIR/linux/"
        fi
    done
}

function build_kernel() {
    mount_iso
    umount linux-build || true
    rm -rf linux-build
    mkdir linux-build && cd linux-build
    mkdir upperdir workdir merged && cd ..

    mount -t overlay overlay -o rw,lowerdir="./fs-$_arg_iso",workdir=./linux-build/workdir,upperdir=./linux-build/upperdir linux-build/merged

    mkdir -p linux-build/merged/patches
    cp patches/* linux-build/merged/patches/

    while true; do sleep 1000; done
    chroot "linux-build/merged" bin/bash || true  << EOF
    apt-get install -y build-essential fakeroot devscripts ccache
    apt-get build-dep -y linux
    cd /root
    set -xe
    linux_pkg_ver="$(dpkg -s linux-image-amd64 | grep Version | cut -d' ' -f 2)"
    dget -u "https://deb.debian.org/debian/pool/main/l/linux/linux_${linux_pkg_ver}.dsc"
    linux_pkg_ver_short="$(find -maxdepth 1 -type d -name "linux-*" | cut -d- -f2)"
    cd linux-"$linux_pkg_ver_short"
    for patch in /patches/*; do
        patch -p1 < "$patch"
    done

    nice -n19 fakeroot debian/rules source
    nice -n19 fakeroot make -f debian/rules.gen setup_amd64_none_amd64 -j$(nproc)
    nice -n19 fakeroot make -f debian/rules.gen build-arch_amd64_none -j$(nproc)
    DEBIAN_KERNEL_USE_CCACHE=true nice -n19 fakeroot make -j$(nproc) -f debian/rules.gen binary-arch_amd64_none_amd64
    cd ..
    ar x linux*image*unsigned*deb > /dev/null
    tar xvf data.tar.xz > /dev/null
    cp ./boot/vmlinuz-* /vmlinuz
EOF
    while true; do sleep 1000; done
    umount linux-build/merged
}
