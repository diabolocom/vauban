#!/usr/bin/env bash
# chellcheck disable=SC2029,SC2034
# shellcheck disable=SC2154

set -eEuo pipefail

ANSIBLE_PLAYBOOK_RUNNING="false"

function prepare_stage_for_host() {
    "${_arg_build_engine}"_prepare_stage_for_host "$@"
}

function end_stage_for_host() {
    "${_arg_build_engine}"_end_stage_for_host "$@"
}

function init_build_engine() {
    "${_arg_build_engine}"_init_build_engine
}

function prepare_rootfs() {
    "${_arg_build_engine}"_prepare_rootfs "$@"
}


function create_parent_rootfs() {
    vauban_log "Will create a rootfs from a Debian Release (${_arg_debian_release})"
    "${_arg_build_engine}"_create_parent_rootfs "$@"
    vauban_log "Rootfs imported. Will run it though the build_rootfs to run eventual stages"
}


function put_sshd_keys() {
    [[ "${2:0:1}" = "/" ]] || vauban_log "put_sshd_keys \$host \$dst needs an absolute path for the \$dst"

    "${VAULT_ENGINE}"_put_sshd_keys "$@"
}


function apply_stage() {
    local source_name="$1"
    shift
    local prefix_name="$1"
    shift
    local stage="$1"
    shift
    local is_conffs="$1"
    shift
    local final_name="$1"
    shift
    hosts=$*

    local pids_prepare_stage=()
    local pids_end_stage=()
    local hosts_built=()
    local local_prefix=""
    local local_source_name=""
    local local_final_name=""
    local current_dir


    if [[ "$stage" = *"@"* ]]; then
        local_branch="$(echo "$stage" | cut -d'@' -f1)"
        local_pb="$(echo "$stage" | cut -d'@' -f2)"
    else
        local_branch="$_arg_branch"
        local_pb="$stage"
    fi

    (
    cd ansible
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/"$local_branch")" ]] || git reset "origin/$local_branch" --hard
    )

    vauban_log " - Applying stage $stage to ${source_name//\/HOSTNAME/} (playbook $local_pb from branch $local_branch) on $hosts"
    vauban_log "   - Starting a container/pod for each host"
    for host in $hosts; do
        if [[ "$is_conffs" == "yes" ]]; then
            local_prefix="$prefix_name/$host"
            local_source_name="${source_name//HOSTNAME/$host}"
            if [[ -z "$final_name" ]]; then
                local_final_name=""
            else
                local_final_name="$final_name/$host"
            fi
        else
            local_prefix="$prefix_name"
            local_source_name="$source_name"
            local_final_name="$final_name"
        fi
        hosts_built+=("$host")
        {
            trap 'set +x; catch_err $?' ERR
            PROCESS_NAME="prepare_stage"
            prepare_stage_for_host "$host" "$local_pb" "$local_source_name" "$local_branch" "$is_conffs" "$local_prefix/$local_pb" "$local_final_name"
        } &
        pids_prepare_stage+=("$!")
    done

    wait_pids "pids_prepare_stage" "hosts_built"

    current_dir="$(pwd)"
    cd "ansible/${ANSIBLE_ROOT_DIR:-.}"
    export ANSIBLE_ANY_ERRORS_FATAL=True
    export ANSIBLE_BECOME_ALLOW_SAME_USER=False
    export ANSIBLE_KEEP_REMOTE_FILES=True
    export ANSIBLE_TIMEOUT=60
    export ANSIBLE_DOCKER_TIMEOUT=60
    export ANSIBLE_INVENTORY_CACHE_TIMEOUT=10
    if [[ "$_arg_build_engine" == "docker" ]]; then
        ansible_connection_module="community.docker.docker_api"
    elif [[ "$_arg_build_engine" == "kubernetes" ]]; then
        ansible_connection_module="ansible.builtin.ssh"
    fi

    eval "$HOOK_PRE_ANSIBLE"

    vauban_log "   - Running ansible-playbook"

    ANSIBLE_PLAYBOOK_RUNNING="true"
    # shellcheck disable=SC2086 # Intended splitting
    eval ansible-playbook --forks 200 "$local_pb" --diff -l "${hosts// /,}" -c "$ansible_connection_module" -v -e \''{"in_vauban": True, "in_conffs_build": '\''"$(to_boolean is_conffs)"'\''}'\' $ANSIBLE_EXTRA_ARGS | tee -a "$ansible_recap_file"
    ANSIBLE_PLAYBOOK_RUNNING="false"

    eval "$HOOK_POST_ANSIBLE"

    cd "$current_dir"

    vauban_log "    - Stage $stage applied successfully. Waiting for each container/pod to wrap up"
    for host in $hosts; do
        if [[ "$is_conffs" == "yes" ]]; then
            local_prefix="$prefix_name/$host"
        else
            local_prefix="$prefix_name"
        fi
        {
            trap 'set +x; catch_err $?' ERR
            # shellcheck disable=SC2034 # variable is actually used elswhere
            PROCESS_NAME="end_stage"
            end_stage_for_host "$host" "$local_prefix/$local_pb" "$local_final_name"
        } &
        pids_end_stage+=("$!")
    done
    wait_pids "pids_end_stage" "hosts_built"
    wait

    vauban_log "    - Stage built"
}

function apply_stages() {
    # apply_stages will go from the image $source_name and will create $final_name by applying $stages
    # $prefix_name is the common prefix name to all the intermediate steps.
    # ie:
    # $source_name -> $prefix_name/$stage[1] -> $prefix_name/$stage[2] -> $prefix_name/$stages[3] aka $final_name
    #
    # The behaviour is slightly different if we are build conffs, as the names will be:
    # $source_name -> $prefix_name/$host/$stage[1] -> $prefix_name/$host/$stage[2] -> $prefix_name/$host/$stages[3] aka $final_name/$host
    #
    # $hostname is the hostname to use for the image building process. This will
    # simulate the docker build instance like it was named $hostname

    init_build_engine  # FIXME

    local source_name="$1"
    shift
    local prefix_name="$1"
    shift
    local final_name="$1"
    shift
    local is_conffs="$1"
    shift
    stages=$*

    local local_final_name=""
    local latest_stage=""

    if [[ $_arg_build_engine == "docker" ]]; then
        docker image inspect "$source_name" > /dev/null 2>&1 || pull_image "$source_name"
    fi

    local iter_source_name="$source_name"

    clone_ansible_repo

    vauban_log "Applying stages to build our hosts"
    for stage in $stages; do
        latest_stage="$stage"
    done
    for stage in $stages; do
        if [[ "$stage" == "$latest_stage" ]]; then
            local_final_name="$final_name"
        else
            local_final_name=""
        fi
        # shellcheck disable=SC2086 # splitting on purpose
        apply_stage "$iter_source_name" "$prefix_name" "$stage" "$is_conffs" "$local_final_name" $hosts
        if [[ "$is_conffs" == "yes" ]]; then
            iter_source_name="${prefix_name}/HOSTNAME/${local_pb}"
        else
            iter_source_name="${prefix_name}/${local_pb}"
        fi
    done
    vauban_log "All stages were applied"
}

function vault_put_sshd_keys() {
    local host dest vault_dir keys_algos keys_algo
    host="$1"
    dest="$2"

    vauban_log "  - Putting sshd keys for $host"
    vault_dir="$(mktemp -d)"
    (
    cd "$vault_dir"
    keys_algos="$(jo -a "$(jo type=ed25519 size=256)" "$(jo type=rsa size=4096)" "$(jo type=ecdsa size=384)")"
    echo "$keys_algos" | jq -c '.[]' | while read -r keys_algo; do
        type="$(echo "$keys_algo" | jq -r .type)"
        size="$(echo "$keys_algo" | jq -r .size)"
        kv_out="$(vault kv get -format json "$VAULT_PATH"sshd/"$host"/"$type" 2>/dev/null | jq .data.data || true)"
        key_name="ssh_host_${type}_key"
        if [[ -z "$kv_out" ]]; then
            ssh-keygen -t "$type" -f "$key_name" -q -N "" -b "$size"
            vault kv put "$VAULT_PATH"sshd/"$host"/"$type" @<(jo "$type=@$key_name" "$type.pub=@$key_name.pub")
        else
            echo "$kv_out" | jq -r ".$type" > "$key_name"
            echo "$kv_out" | jq -r '."'"$type"'.pub"' > "$key_name.pub"
        fi

    done
    mkdir -p "$dest"/etc/ssh/
    cp -r ./* "$dest"/etc/ssh/
    chmod 0600 "$dest"/etc/ssh/ssh_host_*
    chmod 0644 "$dest"/etc/ssh/ssh_host_*.pub
    )

    rm -rf "$vault_dir"
}

function local_put_sshd_keys() {
    local host
    local dest
    host="$1"
    dest="${2:-tmp}"

    vauban_log "  - Putting sshd keys for $host"

    (
    cd vault
    if [[ ! -f "$host".tar.gpg ]]; then
        vauban_log "   - Generating SSH keys for $host"
        mkdir -p "$host/etc/ssh"
        ssh-keygen -A -f "$host"
    else
        vauban_log "   - Using SSH keys from the vault"
        echo "$VAULTED_SSHD_KEYS_KEY" | gpg -d --no-symkey-cache --pinentry-mode loopback --passphrase-fd 0 "$host.tar.gpg" > "$host.tar"
        tar xvf "$host.tar"
    fi
    mkdir -p ../"$dest"/etc/ssh/
    cp -r "$host"/etc/ssh/* ../"$dest"/etc/ssh/
    chmod 0600 ../"$dest"/etc/ssh/ssh_host_*
    chmod 0644 ../"$dest"/etc/ssh/ssh_host_*.pub

    if [[ ! -f "$host.tar.gpg" ]]; then
        vauban_log "   - Adding SSH key to the vault"
        tar cvf "$host.tar" "$host"
        echo "$VAULTED_SSHD_KEYS_KEY" | gpg -c --no-symkey-cache --pinentry-mode loopback --passphrase-fd 0 "$host.tar" # > "$host.tar.gpg"
    fi
    rm -rf "$host" "$host.tar"
    )
}

function export_rootfs() {
    local image_name="$1"
    local working_dir
    working_dir="$BUILD_PATH/$(image_name_to_local_path "$image_name")"

    mkdir -p "$working_dir"
    vauban_log "Creating rootfs from $image_name"
    vauban_log " - Preparing rootfs files locally"
    prepare_rootfs "$image_name" "$working_dir"

    chroot "$working_dir" bin/bash << "EOF"
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
    put_sshd_keys "$image_name" "$working_dir"
    vauban_log " - Compressing rootfs"
    mkdir "$working_dir/proc" "$working_dir/dev" "$working_dir/sys" -p
    mksquashfs "$working_dir" rootfs.img -noappend -always-use-fragments -comp xz -no-exports
    tar cvf rootfs.tgz rootfs.img
    kernel_version="$(get_rootfs_kernel_version "$working_dir")"
    rm -rf "$working_dir"
    vauban_log "rootfs compressed and bundled in tar archive"
    upload_list="$upload_list rootfs.tgz"
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
    vauban_log "Will start building the rootfs for $hostname"
    apply_stages "$source_name" "$prefix_name" "$final_name" "no" "$stages"
    export_rootfs "$final_name"
    vauban_log "rootfs has been fully built !"
}

function build_conffs_given_host() {
    "${_arg_build_engine}"_build_conffs_for_host "$@"
}

function build_conffs() {
    get_conffs_hosts

    local source_name="$1"
    local prefix_name="$2"
    local hosts_built=()

    apply_stages "$source_name" "$prefix_name" "$prefix_name" "yes" "${_arg_stages[@]}"

    vauban_log "build_conffs: Hosts recap"
    for host in $hosts; do
        host_prefix_name="$prefix_name/$host"  # All intermediate images will be named name/host/stage
        # with name being the name of the OS being installed, like debian-10.8
        build_conffs_given_host "$host" "$source_name" "$host_prefix_name"
        vauban_log "$host: success"
    done
    vauban_log "build_conffs: logs" "Conffs built"
}

function chroot_dracut() {
    local modules_path
    local release_path
    local kernel_version
    release_path="$1"
    modules_path="$2"
    kernel_version="$3"

    vauban_log " - Preparing to chroot to generate the initramfs with dracut"

    cp dracut.conf "$release_path"
    cp -r modules.d/* "$release_path/usr/lib/dracut/modules.d/"

    chroot "$release_path" bin/bash << EOF
    dracut -N --conf dracut.conf -f -k "${modules_path#"$release_path"}" initramfs.img $kernel_version 2>&1 > /dev/null;
EOF
}

function build_initramfs() {
    local modules_path
    local release_path
    vauban_log "Building the initramfs"
    release_path="$BUILD_PATH/$_arg_debian_release"
    prepare_debian_release "$release_path"
    kernel="$(find_kernel "$release_path")"
    kernel_version="$(get_kernel_version "$kernel")"
    vauban_log " - Fetching kernel $kernel_version"

    cp "$kernel" ./vmlinuz-default

    modules_path="$release_path/usr/lib/modules/$kernel_version"
    if [[ ! -d "$modules_path" ]]; then
        printf "%s does not exist. Cannot find kernel modules for version %s" "$modules_path" "$kernel_version"
        end 1
    fi
    chroot_dracut "$release_path" "$modules_path" "$kernel_version"
    vauban_log " - initramfs.img created"
    mv "$release_path/initramfs.img" .
    rm -rf "$release_path"
    upload_list="$upload_list initramfs.img vmlinuz-default"
}

function upload() {
    local master_name
    local upload_list
    local file
    local kernel_version
    master_name="${1}"
    kernel_version="${2:-}"
    upload_list="${3:-}"
    vauban_log "Starting uploading resources"
    must_symlink=0
    for file in $upload_list; do
        if [[ "$file" == "vmlinuz" ]] || [[ "$file" == "initramfs.img" ]] || [[ "$file" == "vmlinuz-default" ]]; then
            if [[ -z "$kernel_version" ]]; then
                echo kernel_version not defined and to be used for "$file". Aborting
                end 1
            fi
            remote_file="$file-$kernel_version"
            vauban_log " - Uploading $file"
            retry 3 curl -s -f -u "$UPLOAD_CREDS" "$UPLOAD_ENDPOINT/upload/vauban/linux/$remote_file" -F "file=@$file" | jq .ok
            must_symlink=1
        else
            remote_file="$(basename "$file")"
            vauban_log " - Uploading $file"
            retry 3 curl -s -f -u "$UPLOAD_CREDS" "$UPLOAD_ENDPOINT/upload/vauban/$master_name/$remote_file" -F "file=@$file" | jq .ok
        fi
    done
    if [[ $must_symlink == 1 ]]; then
        vauban_log " - Creating symlinks $kernel_version"
        retry 3 curl -s -f -u "$UPLOAD_CREDS" "$UPLOAD_ENDPOINT/upload/vauban/symlink-linux/$master_name/$kernel_version" -XPOST | jq .ok
    fi

    vauban_log "All resources uploaded !"
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
