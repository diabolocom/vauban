#!/usr/bin/env bash

NEWLINE=$'\n'
TAB=$'\t'

function run_as_root() {
    echo "Must be run as root"
    exit 1
}

function cleanup() {
    rm -rf tmp rootfs.img

    # Keep the conffs that were built (in case it's needed), but move them
    # so that they won't be sent again to dhcp servers on upload
    if [[ -d overlayfs ]]; then
        cd overlayfs
        shopt -s nullglob
        local iso8601="$(date --iso-8601=seconds)"
        for dir in overlayfs-*; do
            mv "$dir" "$iso8601-$dir"
        done
        cd ..
    fi

    umount linux-build/merged > /dev/null 2> /dev/null || true
    umount "iso-$_arg_iso" > /dev/null 2> /dev/null || true
    umount "fs-$_arg_iso" > /dev/null 2> /dev/null || true
    losetup -D > /dev/null 2> /dev/null || true
}

function catch_err() {
    kill -10 $$
    exit 0
}

function end() {
    local return_code="${1:-}"
    set +eE
    cleanup
    print_recap
    exit $return_code
}

function get_os_name() {
    name=$(chroot "fs-$_arg_iso" bin/bash <<EOF
    name="\$(/usr/bin/lsb_release -i | cut -d$'\t' -f2 | tr '[:upper:]' '[:lower:]')"
    if [[ -f /etc/debian_version ]]; then
        version="\$(cat /etc/debian_version)"
    else
        version="\$(/usr/bin/lsb_release -r | cut -d$'\t' -f2)"
    fi
    printf '%s-%s' "\$name" "\$version"
EOF
    )
    echo "$name"
}

function find_kernel() {
    find "fs-$_arg_iso" -type f -name 'vmlinuz*' | sort | tail -n 1
}

function get_kernel_version() {
    file "$1" | grep -oE 'version ([^ ]+)' | sed -e 's/version //'
}

function get_rootfs_kernel_version() {
    local image_name="$1"
    # a combination of ~both functions above, but in docker
    docker run --rm --name "$$-kernel" --entrypoint bash "$image_name" -c \
        'file "$(find /boot -type f -name "vmlinuz*" | sort | tail -n 1)" \
          | grep -oE "version ([^ ]+)" | sed -e "s/version //"'
}

function bootstrap_fs() {
    # We need some DNS to install the packages needed to generate the initramfs
    chroot "fs-$_arg_iso" bin/bash <<- "EOF"
    set -x;
    rm -f /etc/resolv.conf;
    echo nameserver 8.8.8.8 > /etc/resolv.conf;
    echo "" > /etc/fstab;
    export DEBIAN_FRONTEND=noninteractive
    sed -i 's/main$/main contrib non-free/' /etc/apt/sources.list;
    apt-get remove -y initramfs-tools grub2-common;
    apt-get update;
    apt-get install -y locales;
    localedef -i en_US -f UTF-8 en_US.UTF-8
    apt-get install -y lsb-release;
    echo "deb http://deb.debian.org/debian $(lsb_release -s -c)-proposed-updates main contrib non-free" >> /etc/apt/sources.list;
    apt-get update;
    apt-get install -o Dpkg::Options::="--force-confold" --force-yes -y linux-image-amd64 linux-headers-amd64;
    # remove old kernel/headers version.
    # List all linux headers/image, get only 'local' (meaning the one installed but not downloadable anymore, aka old kernel version)
    # extract package name and remove
    apt-get remove -y $(apt list --installed 2>/dev/null | grep -E 'linux-(headers|image)-' | grep local 2>&1 | sed -E 's/\/.+$//g');
    apt-get autoremove -y;
EOF
}

function prepare_fs() {
    local fs
    fs="$(find "iso-$_arg_iso" -type f -name filesystem.squashfs)"

    if [[ -n "$fs" ]]; then
        rmdir "fs-$_arg_iso" && unsquashfs -d "fs-$_arg_iso" "$fs"
    fi
    bootstrap_fs
}

prepared="false"

function ensure_devtmpfs() {
    [[ "$(mount | grep /dev | grep devtmpfs)" ]] || mount -t devtmpfs devtmpfs /dev
}

function mount_iso() {
    if [[ "$prepared" == "true" ]]; then
        return
    fi

    if [[ -d "iso-$_arg_iso" ]]; then
        umount "iso-$_arg_iso" || true
        umount "fs-$_arg_iso" || true
        rm -rf "iso-$_arg_iso" "fs-$_arg_iso"
    fi
    mkdir "iso-$_arg_iso" "fs-$_arg_iso" -p
    local type
    file_mime="$(file $iso_fullpath --mime-type -b)"
    file_basic="$(file $iso_fullpath -b)"
    if [[ "$file_mime" == "application/x-iso9660-image" ]]; then
        mount -o loop -t iso9660 "$iso_fullpath" "./iso-$_arg_iso"
    elif [[ "$file_basic" == "DOS/MBR boot sector, extended partition table (last)" ]]; then
        ensure_devtmpfs
        losetup -D
        local part
        part="$(losetup -f)"
        echo "Going to use: $part"
        if [[ ! -f "${iso_fullpath}-backup" ]]; then
            cp "${iso_fullpath}" "${iso_fullpath}-backup"
        elif [[ "$(xxhsum "${iso_fullpath}")" != "$(xxhsum "${iso_fullpath}-backup")" ]]; then
            cp "${iso_fullpath}-backup" "${iso_fullpath}"
        fi
        losetup -f -P "$iso_fullpath"
        mount -o loop -t ext4 "${part}p1" "./fs-$_arg_iso"
    fi
    prepare_fs
    prepared="true"
}

function get_conffs_hosts() {
    # Use this function to determine a list of hosts matching the --ansible-hosts vauban CLI argument
    # It uses ansible to resolve the ansible-specific syntax
    export GIT_SSH_COMMAND="ssh -i $(pwd)/$_arg_ssh_priv_key -o IdentitiesOnly=yes -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
    if [[ ! -d ansible ]]; then
        git clone "$ANSIBLE_REPO" ansible
        cd ansible && git checkout "$_arg_branch"
    else
        cd ansible && git fetch && git reset "origin/$_arg_branch" --hard
    fi
    cd ${ANSIBLE_ROOT_DIR:-.}
    hook_pre_ansible() { eval "$HOOK_PRE_ANSIBLE" ; } && hook_pre_ansible
    # Call ansible to resolve for us the --limit
    hosts="$(ansible -T 1 --list-hosts "$_arg_ansible_host"',!master-*' 2>&1 | grep -v WARNING | tail -n+2 | sed -e 's/ //g' || echo)"
    hook_post_ansible() { eval "$HOOK_POST_ANSIBLE" ; } && hook_post_ansible
    if [[ -z $hosts ]]; then
        echo "Couldn't find any matching host in ansible inventory. If the name
provided is correct, maybe there's an error in function get_conffs_hosts"
    fi
    cd - && cd ..
    add_to_recap conffs_hosts "Building for:$NEWLINE$hosts"
}

function wait_pids() {
    local -n local_pids="$1"
    local -n local_hosts_built="$2"
    local must_exit
    local return_code
    must_exit="no"

    for i in "${!local_pids[@]}"; do
        return_code=0
        wait "${local_pids[i]}" || let "return_code=1"
        if [[ "$return_code" != 0 ]]; then
            must_exit="yes"  # one fail - everyone fail. No one's left behind !
            add_content_to_recap "${NEWLINE}[KO] ${local_hosts_built[i]}:${TAB}failed !${NEWLINE}"
        else
            add_content_to_recap "${NEWLINE}[OK] ${local_hosts_built[i]}:${TAB}success${NEWLINE}"
        fi
    done
    if [[ "$must_exit" = "yes" ]]; then
        add_to_recap "build_conffs: logs" "Conffs not fully built. Check the build details in /tmp/vauban-logs/*-$build_time"
        end 1
    fi
}


function ci_commit_sshd_keys() {
    if [[ -n ${CI+x} ]]; then
        git config user.name "$GIT_USERNAME"
        git config user.email "$GIT_EMAIL"
        git remote rm origin2 || true
        git remote add origin2 "https://${GIT_TOKEN_USERNAME}:${GIT_TOKEN_PASSWORD}@$(echo "$CI_REPOSITORY_URL" | sed -e "s,.*@\(.*\),\1,")"
        git add vault && git commit -s -m "[CI] Update vault/" && git push origin2 HEAD:$CI_COMMIT_REF_NAME || true
    fi
}


function bootstrap_upload_in_ci() {
    if [[ -n ${CI+x} ]]; then
        mkdir -p ~/.ssh
        cat >> ~/.ssh/config << EOF
Host *
    user $UPLOAD_CI_SSH_USERNAME
IdentityFile ~/.ssh/deploy_id_ed25519
StrictHostKeyChecking accept-new
EOF
        set "+$VAUBAN_SET_FLAGS"
        echo "$UPLOAD_CI_SSH_KEY" | base64 -d > ~/.ssh/deploy_id_ed25519
        set "-$VAUBAN_SET_FLAGS"
        chmod 0600 ~/.ssh/deploy_id_ed25519
    fi
}

docker_loggedin="$(grep \"$REGISTRY_HOSTNAME\" ~/.docker/config.json 2> /dev/null > /dev/null || echo false)"
real_docker="$(which docker)"
current_date="$(date -u +%FT%H%M)"
function docker() {
    # A wrapper to login automatically and interact with the registry for us
    if [[ $docker_loggedin = "false" ]]; then
        docker_loggedin="true"
        if [[ -z "$REGISTRY_PASSWORD" ]]; then
            echo no REGISTRY_PASSWORD variable found, and not currently logged in to the docker registry.
            exit 1
        fi
        echo "$REGISTRY_PASSWORD" | $real_docker login "$REGISTRY_HOSTNAME" --username "$REGISTRY_USERNAME" --password-stdin
    fi

    $real_docker "$@"
    local ret="$?"

    img_name=""
    if [[ "$1" = "build" ]]; then
        next=false
        for arg in $@; do
            if [[ "$arg" = "-t" ]]; then
                next=true
                continue
            fi
            if [[ $next = "true" ]]; then
                img_name="$arg"
                break
            fi
        done
    fi
    if [[ "$1" = "tag" ]]; then
        # docker tag source destination
        # $0     $1  $2     $3
        img_name="$3"
    fi
    if [[ -n "$img_name" ]]; then
        $real_docker tag "$img_name" "$REGISTRY/$img_name:$current_date"
        $real_docker tag "$img_name" "$REGISTRY/$img_name:latest"
        $real_docker push "$REGISTRY/$img_name:$current_date"
        $real_docker push "$REGISTRY/$img_name:latest"

    fi
    return "$ret"
}

function pull_image() {
    local image="$1"
    docker pull "$image" && return 0 || true
    docker pull "$REGISTRY/$image"
    docker tag "$REGISTRY/$image" "$image"
}

function set_deployed() {
    local image="$1"
    local tag="${2:-latest}"
    if [[ $image != *"$REGISTRY_HOSTNAME"* ]]; then
        image="$REGISTRY/$image"
    fi
    "$real_docker" tag "$image:$tag" "$image:deployed"
    docker push "$image:deployed"
}

function add_to_recap() {
    local section="$1"
    shift
    local content="$@"
    RECAP="${RECAP:-}"

    RECAP="$(printf "%s\n\n============================\n%s\n============================\n\n%s\n\n" "$RECAP" "$section" "$content")"
}

function add_content_to_recap() {
    local content="$@"
    RECAP="${RECAP:-}"

    RECAP="$(printf "%s%s\n" "$RECAP" "$content")"
}

function add_section_to_recap() {
    local section="$@"
    RECAP="${RECAP:-}"

    RECAP="$(printf "%s\n\n============================\n%s\n============================\n\n" "$RECAP" "$section")"
}

function print_recap() {
    set "+$VAUBAN_SET_FLAGS"

    echo -e "$RECAP"

    set "-$VAUBAN_SET_FLAGS"
}
