#!/usr/bin/env bash

# shellcheck disable=SC2029

function docker_import() {
    echo "Importing in docker the filesystem from the provided ISO"
    local name
    name="$1"
    echo "Creating $name/raw-iso"
    tar -C "fs-$_arg_iso" -c . | docker import - "$name/raw-iso"
}

function prepare_stage_for_host() {
    local host="$1"
    local playbook="$2"
    local source="$3"
    local branch="$4"
    local container_id

    # Let's make sure we work on the new container
    $real_docker container stop "$host" > /dev/null 2>&1 || true
    $real_docker container rm "$host" > /dev/null 2>&1 || true

    sleep 2
    for i in $(seq 1 15); do
        for id in $($real_docker ps -q); do
            if [[ "$($real_docker exec "$id" cat /tmp/stage-ready 2>/dev/null)" == "$host" ]]; then
                container_id="$id"
                if ! $real_docker rename "$container_id" "$host"; then
                    echo "Failed to rename container $container_id. Aborting"
                    end 1
                fi
                break 2
            fi
        done
        if [[ "$i" == "14" ]]; then
            echo "Waited to find our container for too long. Aborting .."
            end 1
        fi
        sleep 2
    done

    if [[ ! -n ${CI} ]]; then
        # Try to make the container nice
        container_pid="$(ps aux | grep "$container_id" | grep -v grep | awk '{ print $2 }')"
        renice -n 19 -p "$container_pid" > /dev/null 2>&1 || true
        ionice -c 3 -p "$container_pid" > /dev/null 2>&1 || true
    fi

    imginfo_update="$(echo -e "\n\
    - date: $(date --iso-8601=seconds)\n\
      playbook: ${playbook}\n\
      hostname: ${host}\n\
      source: ${source}\n\
      git-sha1: $(git rev-parse HEAD)\n\
      git-branch: ${branch}\n" | base64 -w0)"
    $real_docker exec "$id" bash -c "echo -e $imginfo_update | base64 -d >> /imginfo"
    echo -e "\n[all]\n$host\n" >> ansible/${ANSIBLE_ROOT_DIR:-.}/inventory

    $real_docker exec "$id" touch /tmp/stage-begin
    exit 0
}

function apply_stage() {
    local source_name="$1"
    shift
    local prefix_name="$1"
    shift
    local add_host_to_prefix="$1"
    shift
    local stage="$1"
    shift
    hosts=$*

    local pids_docker_build=()
    local pids_prepare_stage=()
    local hosts_built=()
    local local_prefix=""
    local local_source_name=""


    if [[ "$stage" = *"@"* ]]; then
        local_branch="$(echo $stage | cut -d'@' -f1)"
        local_pb="$(echo $stage | cut -d'@' -f2)"
    else
        local_branch="$_arg_branch"
        local_pb="$stage"
    fi

    clone_ansible_repo
    cd ansible/${ANSIBLE_ROOT_DIR:-.}
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/$local_branch)" ]] || git reset "origin/$local_branch" --hard
    cd -

    echo "Applying stage $stage to $source_name (playbook $local_pb from branch $local_branch) on $hosts"
    for host in $hosts; do
        if [[ "$add_host_to_prefix" == "yes" ]]; then
            local_prefix="$prefix_name/$host"
            local_source_name="$(echo $source_name | sed -e s,HOSTNAME,"$host", )"
        else
            local_prefix="$prefix_name"
            local_source_name="$source_name"
        fi
        docker image inspect "$local_source_name" > /dev/null 2>&1 || pull_image "$local_source_name"
        { set -x; trap - ERR;
            docker build \
                --build-arg SOURCE="${local_source_name}" \
                --build-arg HOST_NAME="$host" \
                --no-cache \
                -t "${local_prefix}/${local_pb}" \
                -f Dockerfile.external-stages .
        } > "$vauban_log_path/vauban-docker-build-${vauban_start_time}/${host}.log" 2>&1 &
        pids_docker_build+=("$!")
        hosts_built+=("$host")
        { set -x; trap - ERR;
            prepare_stage_for_host "$host" "$local_pb" "$local_source_name" "$local_branch" "$last_container_id"
        } > "$vauban_log_path/vauban-prepare-stage-${vauban_start_time}/${host}.log" 2>&1 &
        pids_prepare_stage+=("$!")
    done

    wait_pids "pids_prepare_stage" "hosts_built" "prepare stage"

    cd ansible/${ANSIBLE_ROOT_DIR:-.}
    eval "$HOOK_PRE_ANSIBLE"
    export ANSIBLE_ANY_ERRORS_FATAL=True
    export ANSIBLE_BECOME_ALLOW_SAME_USER=False
    export ANSIBLE_KEEP_REMOTE_FILES=True
    if eval ansible-playbook --forks 200 "$local_pb" --diff -l "$(echo $hosts | sed -e 's/ /,/g')" -c community.docker.docker_api -v $ANSIBLE_EXTRA_ARGS; then
        file_to_touch=/tmp/stage-built
    else
        file_to_touch=/tmp/stage-failed
    fi
        for host in $hosts; do
            docker exec "$host" touch "$file_to_touch"
        done
    eval "$HOOK_POST_ANSIBLE"

    echo "Done with ansible for the stage $stage. Waiting for each container to wrap up ..."
    wait_pids "pids_docker_build" "hosts_built" "build stage $stage"
    wait
    echo "All build-containers exited"
    cd -
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
    local add_host_to_prefix="$1"
    shift
    local final_name="$1"
    shift
    stages=$*

    local local_source_name=""
    local local_final_name=""

    docker image inspect "$source_name" > /dev/null 2>&1 || pull_image "$source_name"

    local iter_source_name="$source_name"

    echo "Applying stages to build our hosts"
    for stage in $stages; do
        apply_stage "$iter_source_name" "$prefix_name" "$add_host_to_prefix" "$stage" $hosts
        if [[ "$add_host_to_prefix" == "yes" ]]; then
            iter_source_name="${prefix_name}/HOSTNAME/${local_pb}"
        else
            iter_source_name="${prefix_name}/${local_pb}"
        fi
    done
    echo "All stages were applied. Tagging docker images"
    for host in $hosts; do
        if [[ "$add_host_to_prefix" == "yes" ]]; then
            local_source_name="$(echo $iter_source_name | sed -e s,HOSTNAME,"$host", )"
            local_final_name="$final_name/$host"
        else
            local_source_name="$iter_source_name"
            local_final_name="$final_name"
        fi
        echo "Tagging $local_final_name on $local_source_name"
        docker tag "$local_source_name" "$local_final_name" > /dev/null 2>&1
    done
}

function import_iso() {
    local name
    name="$1"
    docker_import "$name"
    docker build \
        --build-arg SOURCE="${name}/raw-iso" \
        --build-arg ISO="$_arg_iso" \
        --build-arg VAUBAN_SHA1="$(git rev-parse HEAD || echo unspecified)" \
        --no-cache \
        -t "${name}/iso" \
        -f Dockerfile.external-base .
}

function put_sshd_keys() {
    local host
    local dest
    host="$1"
    dest="${2:-tmp}"

    echo "Putting sshd keys for $hosts"

    cd vault
    if [[ ! -f "$host".tar.gpg ]]; then
        echo "Generating SSH keys for $host"
        mkdir -p "$host/etc/ssh"
        ssh-keygen -A -f "$host"
    else
        echo "Using SSH keys from the vault"
        echo $VAULTED_SSHD_KEYS_KEY | gpg -d --no-symkey-cache --pinentry-mode loopback --passphrase-fd 0 "$host.tar.gpg" > "$host.tar"
        tar xvf "$host.tar"
    fi
    mkdir -p ../"$dest"/etc/ssh/
    cp -r "$host"/etc/ssh/* ../"$dest"/etc/ssh/
    chmod 0600 ../"$dest"/etc/ssh/ssh_host_*
    chmod 0644 ../"$dest"/etc/ssh/ssh_host_*.pub

    if [[ ! -f "$host.tar.gpg" ]]; then
        echo "Adding SSH key to the vault"
        tar cvf "$host.tar" "$host"
        echo $VAULTED_SSHD_KEYS_KEY | gpg -c --no-symkey-cache --pinentry-mode loopback --passphrase-fd 0 "$host.tar" # > "$host.tar.gpg"
    fi
    rm -rf "$host" "$host.tar"
    cd ..
}

function export_rootfs() {
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
    rm -rf root/.ssh/vauban__id_ed25519 root/ansible boot/initrd* /var/lib/apt/lists/* || true
EOF
    put_sshd_keys "$image_name"
    echo "Compressing rootfs"
    mksquashfs tmp rootfs.img -noappend -always-use-fragments -comp xz -no-exports
    tar cvf rootfs.tgz rootfs.img
    echo "rootfs compressed and bundled in tar archive"
}

function build_rootfs() {
    local source_name="$1"
    shift
    local prefix_name="$1"
    shift
    local final_name="$1"
    shift
    local hostname="$1"
    shift
    stages=$*

    hosts="$hostname"
    echo "Will start building the rootfs for $hostname"
    apply_stages "$source_name" "$prefix_name" "no" "$final_name" "$stages"
    export_rootfs "$final_name"
    echo "rootfs has been fully built !"
}

function build_conffs_given_host() {
    local host="$1"
    local source_name="$2"
    local prefix_name="$3"

    printf "Building conffs for host=%s\n" "$host"
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
    # There is a bug in old version of overlayfs where whiteout are not well understood and
    # are kept as buggy char devices on the merged dir. Touching the file and removing
    # it fixes this
    find -type c -exec bash -c 'stat {} >/dev/null 2>/dev/null || (touch {} && rm {})' \;
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

    apply_stages "$source_name" "$prefix_name" "yes" "$prefix_name" "${_arg_stages[@]}"

    add_section_to_recap "build_conffs: Hosts recap"
    add_content_to_recap ""  # newline
    for host in $hosts; do
        host_prefix_name="$prefix_name/$host"  # All intermediate images will be named name/host/stage
        # with name being the name of the OS being installed, like debian-10.8
        build_conffs_given_host "$host" "$source_name" "$host_prefix_name"
    done
    add_content_to_recap ""  # newline
    add_to_recap "build_conffs: logs" "Conffs built"
    ci_commit_sshd_keys
}

function chroot_dracut() {
    local modules
    local name
    local kernel_version
    name="$1"
    modules="$2"
    kernel_version="$3"

    echo "Preparing to chroot to generate the initramfs with dracut"

    echo "Mounting directories"
    cd "fs-$_arg_iso"
    mkdir -p proc sys dev
    mount -t proc /proc proc/
    mount --rbind /sys sys/
    mount --rbind /dev dev/
    mount --make-rslave sys/
    mount --make-rslave dev/
    cd ..

    cp dracut.conf "fs-$_arg_iso/"
    echo "Installing dracut in chroot"
    chroot "fs-$_arg_iso" bin/bash << "EOF"
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

    echo "Running dracut in chrooted environment"

    chroot "fs-$_arg_iso" bin/bash << EOF
    dracut -N --conf dracut.conf -f -k "$modules" initramfs.img $kernel_version 2>&1 > /dev/null;
    rm /fs-$_arg_iso;
EOF

    echo "Unmounting directories"
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

    cp "$kernel" ./vmlinuz-default

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
            upload_list="initramfs.img vmlinuz-default"
        fi;
        if [[ $_arg_kernel = "yes" ]]; then
            upload_list="vmlinuz"
        fi;
        if [[ $_arg_rootfs = "yes" ]]; then
            upload_list="$upload_list rootfs.tgz"
        fi;
        if [[ $_arg_conffs = "yes" ]]; then
            upload_list="$upload_list overlayfs/overlayfs-*/conffs-*.tgz"
        fi;

        # if still empty, send everything
        if [[ -z "$upload_list" ]]; then
            upload_list="initramfs.img vmlinuz rootfs.tgz overlayfs-*/conffs-*.tgz vmlinuz-default"
        fi;
    fi;

    echo "Will upload resources to distant TFTP/PXE server"

    # Expand upload list
    add_to_recap upload "Uploaded: "$upload_list
    for host in $UPLOAD_HOSTS_LIST; do
        # Detect if needs to use sudo
        local opt_sudo=""
        ssh "$host" touch "$UPLOAD_DIR" || opt_sudo=sudo

        # don't quote opt_sudo to not call empty string if empty
        ssh "$host" $opt_sudo mkdir -p "$UPLOAD_DIR/$master_name/" "$UPLOAD_DIR/linux/"


        for file in $upload_list; do
            if [[ ! -f "$file" ]]; then add_content_to_recap "Skipping file $file: not found" continue; fi
            scp "$file" "$host:/tmp"
            remote_file="$(basename "$file")"

            if [[ "$file" == "vmlinuz" ]] || [[ "$file" == "initramfs.img" ]] || [[ "$file" == "vmlinuz-default" ]]; then
                if [[ -z "$kernel_version" ]]; then
                    echo kernel_version not defined and to be used for "$file". Aborting
                    exit 1
                fi
                remote_file="$file-$kernel_version"
                ssh "$host" $opt_sudo mv "/tmp/$file" "$UPLOAD_DIR/linux/$remote_file"
                ssh "$host" $opt_sudo chmod 0664 "$UPLOAD_DIR/linux/$remote_file"
            else
                if [[ "$file" == "rootfs.tgz" ]] && [[ -n "$kernel_version" ]]; then
                    ssh "$host" $opt_sudo rm "$UPLOAD_DIR/$master_name/vmlinuz" || true
                    ssh "$host" $opt_sudo rm "$UPLOAD_DIR/$master_name/vmlinuz-default" || true
                    ssh "$host" $opt_sudo rm "$UPLOAD_DIR/$master_name/initramfs.img" || true
                    ssh "$host" $opt_sudo ln -s "../linux/vmlinuz-$kernel_version" "$UPLOAD_DIR/$master_name/vmlinuz"
                    ssh "$host" $opt_sudo ln -s "../linux/vmlinuz-default-$kernel_version" "$UPLOAD_DIR/$master_name/vmlinuz-default"
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

    echo "All resources uploaded !"
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

    chroot "linux-build/merged" bin/bash << "EOF"
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
    cp linux-build/merged/vmlinuz ./vmlinuz
    umount linux-build/merged
}
