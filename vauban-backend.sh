#!/usr/bin/env bash
# shellcheck disable=SC2029,SC2154,SC2034

set -eEuo pipefail

function docker_import() {
    echo "Importing in docker the filesystem from the provided ISO"
    local name
    name="$1"
    echo "Creating $name/raw-iso"
    tar -C "overlay-$_arg_iso" -c . | docker import - "$name/raw-iso"
}

function prepare_stage_for_host() {
    local host="$1"
    local playbook="$2"
    local source="$3"
    local branch="$4"
    local container_id
    local timeout=600

    container_id="$(docker container inspect $host | jq -r '.[].Id')"
    container_ip="$(docker container inspect $host | jq -r '.[].NetworkSettings.Networks.bridge.IPAddress')"

    if [[ -z ${CI:-} ]]; then
        # Try to make the container nice
        container_pid="$(ps aux | grep "$container_id" | grep -v grep | awk '{ print $2 }')"
        ls "/proc/$container_pid/task" | xargs renice -n 19 > /dev/null 2>&1 || true
        cat /proc/"$container_pid"/task/*/children | xargs renice -n 19 > /dev/null 2>&1 || true
    fi

    ansible_sha1="$( (cd ansible; git rev-parse HEAD) )"
    vauban_sha1="$(git rev-parse HEAD)"
    imginfo_update="$(echo -e "\n\
    - date: $(date --iso-8601=seconds)\n\
      playbook: ${playbook}\n\
      hostname: ${host}\n\
      source: ${source}\n\
      git-sha1: ${ansible_sha1}\n\
      git-branch: ${branch}\n\
      vauban-sha1: ${vauban_sha1}\n" | base64 -w0)"
    retry 3 timeout 2 docker exec "$host" bash -c "echo -e $imginfo_update | base64 -d >> /imginfo"
    echo -e "\n[all]\n$host\n" >> ansible/${ANSIBLE_ROOT_DIR:-.}/inventory

    # This takes time

    for i in $(seq 1 $timeout); do
        if [[ "$(docker inspect "$container_id" | jq '.[].State.Status' -r)" != "running" ]]; then
            echo "container exited. Aborting .."
            exit 1
        fi
        if [[ "$(timeout 3 curl -m 2 "http://$container_ip:8000/ready" 2>/dev/null)" == "ready" ]]; then
            echo "Our container is ready. Let's signal it that we are ready to pursue as well."
            break
        fi
        if [[ "$i" == "$((timeout - 1))" ]]; then
            echo "Waited for our container to be ready for too long. Aborting .."
            exit 1
        fi
        sleep 0.5
    done
}

function end_stage_for_host() {
    local host="$1"
    local status="$2"
    local timeout=60

    if [[ "$(docker inspect "$host" | jq '.[].State.Status' -r)" != "running" ]]; then
        echo "Container already exited. Aborting .."
        exit 1
    fi

    container_ip="$(docker container inspect $host | jq -r '.[].NetworkSettings.Networks.bridge.IPAddress')"

    printf "Container for %s signaled us %s" "$host" "$(retry 3 timeout 3 curl -m 2 http://"$container_ip":8000$status 2> /dev/null)"

    echo "Waiting for container $host to exit"
    for i in $(seq 1 $timeout); do
        if [[ "$(docker inspect "$host" | jq '.[].State.Status' -r)" == "exited" ]]; then
            echo "Container exited. Continuing .."
            break
        fi
        if [[ "$i" == "$((timeout - 1))" ]]; then
            echo "Our container doesn't want to stop. Aborting .."
            exit 1
        fi
        sleep 0.5
    done
    docker commit "$host" "${local_prefix}/${local_pb}"
    docker_push "${local_prefix}/${local_pb}"
    docker logs "$host" > "$vauban_log_path/vauban-docker-logs-${vauban_start_time}/${host}.log" 2>&1
    docker container rm "$host"
    echo "Docker container commited and pushed. Success !"
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
    local in_conffs="$1"
    shift
    hosts=$*

    local pids_prepare_stage=()
    local pids_end_stage=()
    local hosts_built=()
    local local_prefix=""
    local local_source_name=""
    local status


    if [[ "$stage" = *"@"* ]]; then
        local_branch="$(echo $stage | cut -d'@' -f1)"
        local_pb="$(echo $stage | cut -d'@' -f2)"
    else
        local_branch="$_arg_branch"
        local_pb="$stage"
    fi

    clone_ansible_repo
    (
    cd ansible
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/$local_branch)" ]] || git reset "origin/$local_branch" --hard
    )

    echo "Applying stage $stage to $source_name (playbook $local_pb from branch $local_branch) on $hosts"
    for host in $hosts; do
        if [[ "$add_host_to_prefix" == "yes" ]]; then
            local_prefix="$prefix_name/$host"
            local_source_name="${source_name//HOSTNAME/$host}"
        else
            local_prefix="$prefix_name"
            local_source_name="$source_name"
        fi
        docker image inspect "$local_source_name" > /dev/null 2>&1 || pull_image "$local_source_name"

        # Let's make sure we work on the new container
        docker container stop "$host" > /dev/null 2>&1 || true
        docker container rm "$host" > /dev/null 2>&1 && echo "!! removed existing container for $host" || true
        docker run \
            --name "$host" \
            --hostname "$host" \
            --add-host "$host:127.0.0.1" \
            --add-host "$host:::1" \
            --env SOURCE="${local_source_name}" \
            --env PLAYBOOK="${local_pb}" \
            --env HOST_NAME="$host" \
            --env IN_CONFFS="$in_conffs" \
            --volume "$(pwd)"/docker-entrypoint.sh:/docker-entrypoint.sh \
            --entrypoint /docker-entrypoint.sh \
            --user root \
            --detach \
            --workdir /root \
            --tty \
            --tmpfs /tmp \
            ${local_source_name}
        hosts_built+=("$host")
        { set -x; trap send_sentry ERR;
            trap - SIGUSR1;
            trap 'previous_command=${this_command:-}; this_command=$BASH_COMMAND' DEBUG;
            prepare_stage_for_host "$host" "$local_pb" "$local_source_name" "$local_branch"
        } > "$vauban_log_path/vauban-prepare-stage-${vauban_start_time}/${host}.log" 2>&1 &
        pids_prepare_stage+=("$!")
    done

    wait_pids "pids_prepare_stage" "hosts_built" "prepare stage $stage"

    local current_dir="$(pwd)"
    cd ansible/${ANSIBLE_ROOT_DIR:-.}
    export ANSIBLE_ANY_ERRORS_FATAL=True
    export ANSIBLE_BECOME_ALLOW_SAME_USER=False
    export ANSIBLE_KEEP_REMOTE_FILES=True
    export ANSIBLE_TIMEOUT=60
    export ANSIBLE_DOCKER_TIMEOUT=60

    echo "Running HOOK_PRE_ANSIBLE"
    eval "$HOOK_PRE_ANSIBLE"
    echo "Done with HOOK_PRE_ANSIBLE"

    echo "Running ansible-playbook"
    if eval ansible-playbook --forks 200 "$local_pb" --diff -l "$(echo $hosts | sed -e 's/ /,/g')" -c community.docker.docker_api -v -e \''{"in_vauban": True, "in_conffs_build": '\''"$(to_boolean in_conffs)"'\''}'\' $ANSIBLE_EXTRA_ARGS | tee -a "$ansible_recap_file" ; then
        status=/success
    else
        status=/failed
    fi
    tail -n 50 "$ansible_recap_file" >> "$recap_file"

    echo "Running HOOK_POST_ANSIBLE"
    eval "$HOOK_POST_ANSIBLE"
    echo "Done with HOOK_POST_ANSIBLE"

    echo "Done with ansible for the stage $stage. Waiting for each container to wrap up, signaling status=$status ..."
    for host in $hosts; do
        if [[ "$add_host_to_prefix" == "yes" ]]; then
            local_prefix="$prefix_name/$host"
        else
            local_prefix="$prefix_name"
        fi
        { set -x; trap send_sentry ERR;
            trap - SIGUSR1;
            trap 'previous_command=${this_command:-}; this_command=$BASH_COMMAND' DEBUG;
            end_stage_for_host "$host" "$status"
        } > "$vauban_log_path/vauban-end-stage-${vauban_start_time}/${host}.log" 2>&1 &
        pids_end_stage+=("$!")
    done
    wait_pids "pids_end_stage" "hosts_built" "end stage $stage"
    wait

    echo "All build-containers exited"
    cd "$current_dir"
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
    local in_conffs="$1"
    shift
    stages=$*

    local local_source_name=""
    local local_final_name=""

    docker image inspect "$source_name" > /dev/null 2>&1 || pull_image "$source_name"

    local iter_source_name="$source_name"

    echo "Applying stages to build our hosts"
    for stage in $stages; do
        apply_stage "$iter_source_name" "$prefix_name" "$add_host_to_prefix" "$stage" "$in_conffs" $hosts
        if [[ "$add_host_to_prefix" == "yes" ]]; then
            iter_source_name="${prefix_name}/HOSTNAME/${local_pb}"
        else
            iter_source_name="${prefix_name}/${local_pb}"
        fi
    done
    echo "All stages were applied. Tagging docker images"
    for host in $hosts; do
        if [[ "$add_host_to_prefix" == "yes" ]]; then
            local_source_name="${iter_source_name//HOSTNAME/$host}"
            local_final_name="$final_name/$host"
        else
            local_source_name="$iter_source_name"
            local_final_name="$final_name"
        fi
        echo "Tagging $local_final_name on $local_source_name"
        docker tag "$local_source_name" "$local_final_name" > /dev/null 2>&1
        docker_push "$local_final_name"
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
    docker_push "$name"/iso
}

function put_sshd_keys() {
    local host
    local dest
    host="$1"
    dest="${2:-tmp}"

    echo "Putting sshd keys for $host"

    (
    cd vault
    if [[ ! -f "$host".tar.gpg ]]; then
        echo "Generating SSH keys for $host"
        mkdir -p "$host/etc/ssh"
        ssh-keygen -A -f "$host"
    else
        echo "Using SSH keys from the vault"
        echo "$VAULTED_SSHD_KEYS_KEY" | gpg -d --no-symkey-cache --pinentry-mode loopback --passphrase-fd 0 "$host.tar.gpg" > "$host.tar"
        tar xvf "$host.tar"
    fi
    mkdir -p ../"$dest"/etc/ssh/
    cp -r "$host"/etc/ssh/* ../"$dest"/etc/ssh/
    chmod 0600 ../"$dest"/etc/ssh/ssh_host_*
    chmod 0644 ../"$dest"/etc/ssh/ssh_host_*.pub

    if [[ ! -f "$host.tar.gpg" ]]; then
        echo "Adding SSH key to the vault"
        tar cvf "$host.tar" "$host"
        echo "$VAULTED_SSHD_KEYS_KEY" | gpg -c --no-symkey-cache --pinentry-mode loopback --passphrase-fd 0 "$host.tar" # > "$host.tar.gpg"
    fi
    rm -rf "$host" "$host.tar"
    )
}

function export_rootfs() {
    local image_name="$1"

    rm -rf tmp && mkdir tmp
    echo "Creating rootfs from $image_name"
    docker create --name $$ "$image_name" --entrypoint bash
    (
    cd tmp && docker export $$ | tar x
    docker rm $$
    )
    chroot "tmp" bin/bash << "EOF"
    (
    cd etc
    ln -sfr /run/resolvconf/resolv.conf resolv.conf  # We must do that here because docker mounts resolv.conf
    )
    if [[ -d /toslash ]]; then
        cp -r /toslash/* / && rm -rf /toslash  # This is also to allow us to write things in /etc/hostname or /etc/hosts
    fi
    apt-get clean -y
    rm -rf /root/.ssh/vauban__id_ed25519 /root/ansible /root/.ansible /boot/initrd* /var/lib/apt/lists/* /tmp/* /var/tmp/* || true
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
    apply_stages "$source_name" "$prefix_name" "no" "$final_name" "no" "$stages"
    export_rootfs "$final_name"
    echo "rootfs has been fully built !"
}

function build_conffs_given_host() {
    local host="$1"
    local source_name="$2"
    local prefix_name="$3"

    printf "Building conffs for host=%s\n" "$host"
    local current_dir="$(pwd)"
    mkdir -p overlayfs && cd overlayfs
    overlayfs_args=""
    first="yes"
    for stage in "${_arg_stages[@]}"; do
        if [[ "$stage" = *"@"* ]]; then
            local_pb="$(echo "$stage" | cut -d'@' -f2)"
        else
            local_pb="$stage"
        fi
        layer_path="$(docker inspect "$prefix_name/$local_pb" | jq -r '.[0].GraphDriver.Data.UpperDir')"
        if [[ $first = "yes" ]] && [[ -n "$(find "$layer_path" -type c)" ]]; then
            echo "file deletion in first layer of conffs detected"
            echo "Incriminated files:"
            find "$layer_path" -type c
        fi
        layer_path_no_diff="$(dirname "$layer_path")"  # removes the /diff at the end
        docker_overlay_dir="$(dirname "$layer_path_no_diff")"  # should returns /var/lib/docker/overlay2 by default
        short_layer_path="$docker_overlay_dir/l/$(cat $layer_path_no_diff/link)"
        first="no"
        if [[ $overlayfs_args == *"$short_layer_path"* ]]; then
            echo "Layer already added. There might be stage misconfiguration/repetion"
            echo "Layer $layer_path will be ignored."
            continue
        fi
        overlayfs_args=":$short_layer_path$overlayfs_args"
    done
    mkdir -p "overlayfs-${host}/merged" "overlayfs-${host}/upperdir" "overlayfs-${host}/workdir" "overlayfs-${host}/lower" && cd "overlayfs-${host}"

    if [[ -n "$overlayfs_args" ]]; then
        mount -t overlay overlay -o "rw,lowerdir=lower$overlayfs_args,workdir=workdir,upperdir=upperdir,metacopy=off" merged
    else
        echo "WARNING: Creating some empty conffs !"
    fi
    rm -rf "conffs-$host.tgz"
    cd "$current_dir"
    put_sshd_keys "$host" "overlayfs/overlayfs-$host/merged"
    (
    cd "overlayfs/overlayfs-${host}"
    (
    cd merged
    if [[ -d toslash ]]; then cp -r toslash/* . && rm -rf toslash; fi
    rm -rf var/lib/apt/lists/*
    )
    # There is a bug in old version of overlayfs where whiteout are not well understood and
    # are kept as buggy char devices on the merged dir. Touching the file and removing
    # it fixes this
    find . -type c -exec bash -c 'filename="$1"; stat "$filename" >/dev/null 2>/dev/null || (touch "$filename" && rm "$filename")' bash {} \;
    tar cvfz "conffs-$host.tgz" \
        -C merged \
        --exclude "var/log" \
        --exclude "var/cache" \
        --exclude "root/ansible" \
        . > /dev/null
    if [[ -n "$overlayfs_args" ]]; then
        umount merged
    fi
    )
}

function build_conffs() {
    get_conffs_hosts

    local source_name="$1"
    local prefix_name="$2"
    local pids=()
    local hosts_built=()

    apply_stages "$source_name" "$prefix_name" "yes" "$prefix_name" "yes" "${_arg_stages[@]}"

    add_section_to_recap "build_conffs: Hosts recap"
    for host in $hosts; do
        host_prefix_name="$prefix_name/$host"  # All intermediate images will be named name/host/stage
        # with name being the name of the OS being installed, like debian-10.8
        build_conffs_given_host "$host" "$source_name" "$host_prefix_name"
        add_content_to_recap "$host: success"
    done
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
    mount_rbind "overlay-$_arg_iso"

    cp dracut.conf "overlay-$_arg_iso/"
    echo "Installing dracut in chroot"
    chroot "overlay-$_arg_iso" bin/bash << "EOF"
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -o Dpkg::Options::="--force-confold" --force-yes -y openssh-server firmware-bnx2x
    cd tmp
    version="$(cat /etc/debian_version)"
    if [[ "$version" = "10."* ]]; then
        apt-get install -y -o Dpkg::Options::="--force-confold" --force-yes dracut dracut-core dracut-network 2>&1 > /dev/null || true
    else
        if [[ "$version" = "12."* ]]; then
            mkdir -p /etc/apt/sources.list.d/
            cat /etc/apt/sources.list | sed -e 's,bookworm-proposed-updates,bookworm,g' | sed -e 's,non-free$,non-free non-free-firmware,g' > /etc/apt/sources.list.d/debian-12.list
            apt-get update;
            apt-get install -o Dpkg::Options::="--force-confold" --force-yes -y firmware-bnx2x isc-dhcp-client
        fi
        apt-get download dracut-core dracut-network dracut-live dracut-squash
        PATH=/usr/local/sbin:/usr/bin/:/sbin dpkg -i dracut*
        apt-get install -y --fix-broken
    fi
    apt-get install -y xfsprogs
    version="$(cat /etc/debian_version)"
EOF
    chroot "overlay-$_arg_iso" bin/bash << EOF
    [[ ! -d /overlay-$_arg_iso ]] && ln -s / /overlay-$_arg_iso
EOF
    put_sshd_keys "$name" "overlay-$_arg_iso/"
    cp -r modules.d/* "overlay-$_arg_iso/usr/lib/dracut/modules.d/"

    echo "Running dracut in chrooted environment"

    chroot "overlay-$_arg_iso" bin/bash << EOF
    dracut -N --conf dracut.conf -f -k "$modules" initramfs.img $kernel_version 2>&1 > /dev/null;
    rm /overlay-$_arg_iso;
EOF

    umount_rbind "overlay-$_arg_iso"
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

    modules="overlay-$_arg_iso/usr/lib/modules/$kernel_version"
    if [ ! -d "$modules" ]; then
        printf "%s does not exist. Cannot find kernel modules for version %s" "$modules" "$kernel_version"
        exit 1
    fi
    chroot_dracut "$name" "$modules" "$kernel_version"
    mv "overlay-$_arg_iso/initramfs.img" .
}

function upload() {
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
    must_symlink=0
    for file in $upload_list; do
        if [[ "$file" == "vmlinuz" ]] || [[ "$file" == "initramfs.img" ]] || [[ "$file" == "vmlinuz-default" ]]; then
            if [[ -z "$kernel_version" ]]; then
                echo kernel_version not defined and to be used for "$file". Aborting
                exit 1
            fi
            remote_file="$file-$kernel_version"
            curl -s -f -u "$UPLOAD_CREDS" "$UPLOAD_ENDPOINT"/upload/vauban/linux/"$remote_file" -F "file=@$file" | jq .ok
            must_symlink=1
        else
            remote_file="$(basename "$file")"
            curl -s -f -u "$UPLOAD_CREDS" "$UPLOAD_ENDPOINT"/upload/vauban/$master_name/"$remote_file" -F "file=@$file" | jq .ok
        fi
    done
    if [[ $must_symlink == 1 ]]; then
        curl -s -f -u "$UPLOAD_CREDS" "$UPLOAD_ENDPOINT"/upload/vauban/symlink-linux/$master_name/$kernel_version -XPOST | jq .ok
    fi

    echo "All resources uploaded !"
}

function build_kernel() {
    mount_iso
    umount linux-build || true
    rm -rf linux-build
    mkdir linux-build
    (
    cd linux-build
    mkdir upperdir workdir merged
    )

    mount -t overlay overlay -o rw,lowerdir="./overlay-$_arg_iso",workdir=./linux-build/workdir,upperdir=./linux-build/upperdir linux-build/merged

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
