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
    umount_rbind "overlay-$_arg_iso" > /dev/null 2> /dev/null || true
    umount "overlay-$_arg_iso" > /dev/null 2> /dev/null || true
    umount "fs-$_arg_iso" > /dev/null 2> /dev/null || true
    umount "iso-$_arg_iso" > /dev/null 2> /dev/null || true
    rm -rf "overlay-$_arg_iso" "fs-$_arg_iso" "iso-$_arg_iso" "upperdir-$_arg_iso" "workdir-$_arg_iso" > /dev/null 2>&1 || true
    losetup -D > /dev/null 2> /dev/null || true
}

function stacktrace {
   local i=1 line file func
   while read -r line func file < <(caller $i); do
      echo "[$i] $file:$line $func(): $(sed -n "${line}"p "$file")"
      ((i++))
   done
}

function send_sentry() {
    triggered_cmd="$previous_command"
    UPLOAD_CI_SSH_KEY=*** UPLOAD_CREDS=*** VAULTED_SSHD_KEYS_KEY=*** REGISTRY_PASSWORD=*** sentry-cli send-event \
        -m "'$triggered_cmd': return code $1 on line $2" \
        -t conffs:"${_arg_conffs:-}" \
        -t rootfs:"${_arg_rootfs:-}" \
        -t name:"${_arg_name:-}" \
        -t stages:"${_arg_stages:-}" \
        -e this_cmd:"${this_command:-}" \
        -t kernel:"${_arg_kernel:-}" \
        -t upload:"${_arg_upload:-}" \
        -t iso:"${_arg_iso:-}" \
        -t branch:"${_arg_branch:-}" \
        -t initramfs:"${_arg_initramfs:-}" \
        -t source_image:"${_arg_source_image:-}" \
        -a "$(stacktrace)" \
        -t user_sudo:"${SUDO_USER:-${USER:-undefined}}" \
        --logfile "$recap_file" || echo Could not send sentry event 1>&2
}

function catch_err() {
    send_sentry $@
    kill -10 $$
    exit 0
}

function end() {
    local return_code="${1:-}"
    set +eE
    [[ -z "$(jobs -p)" ]] || kill $(jobs -p)
    cleanup
    print_recap
    exit $return_code
}

function get_os_name() {
    name=$(chroot "overlay-$_arg_iso" bin/bash <<EOF
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
    find "overlay-$_arg_iso" -type f -name 'vmlinuz*' | sort | tail -n 1
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
    mount_rbind "overlay-$_arg_iso"

    chroot "overlay-$_arg_iso" bin/bash <<- "EOF"
    set -e;
    rm -f /etc/resolv.conf;
    echo nameserver 8.8.8.8 > /etc/resolv.conf;
    echo "" > /etc/fstab;
    export DEBIAN_FRONTEND=noninteractive
    sed -i 's/main$/main contrib non-free/' /etc/apt/sources.list;
    cat /etc/apt/sources.list | grep -v '^\s*#' | grep . | sort -u > /tmp/apt_sources; mv /tmp/apt_sources /etc/apt/sources.list;
    echo "Removing grub";
    export INITRD=No
    apt-get update;
    apt-get install -y dracut > /dev/null;
    apt-get remove -y initramfs-tools grub2-common > /dev/null;
    echo "Updating and installing some base packages";
    apt-get update > /dev/null;
    apt-get install -y locales > /dev/null;
    localedef -i en_US -f UTF-8 en_US.UTF-8
    apt-get install -y lsb-release > /dev/null;
    echo "deb http://deb.debian.org/debian $(lsb_release -s -c)-proposed-updates main contrib non-free" >> /etc/apt/sources.list;
    cat /etc/apt/sources.list | grep -v '^\s*#' | grep . | sort -u > /tmp/apt_sources; mv /tmp/apt_sources /etc/apt/sources.list;
    apt-get update > /dev/null;
    echo "Updating linux kernel and headers";
    apt-get install -o Dpkg::Options::="--force-confold" --force-yes -y linux-image-amd64 linux-headers-amd64 > /dev/null;
    # remove old kernel/headers version.
    # List all linux headers/image, get only 'local' (meaning the one installed but not downloadable anymore, aka old kernel version)
    # extract package name and remove
    apt-get clean -y;
    apt-get remove -y $(apt list --installed 2>/dev/null | grep -E 'linux-(headers|image)-' | grep local 2>&1 | sed -E 's/\/.+$//g') > /dev/null;
    apt-get autoremove -y;
EOF
    umount_rbind "overlay-$_arg_iso"
}

function prepare_fs() {
    local fs
    fs="$(find "iso-$_arg_iso" -type f -name filesystem.squashfs)"

    if [[ -n "$fs" ]]; then
        rmdir "fs-$_arg_iso" && unsquashfs -d "fs-$_arg_iso" "$fs"
    fi
    mount -t overlay overlay -o rw,lowerdir="fs-$_arg_iso",workdir="workdir-$_arg_iso",upperdir="upperdir-$_arg_iso" "overlay-$_arg_iso"
    bootstrap_fs
}

prepared="false"

function mount_rbind() {
    cd "$1"
    mkdir -p proc sys dev
    mount -t proc /proc proc/
    mount --rbind /sys sys/
    mount --rbind /dev dev/
    mount --make-rslave sys/
    mount --make-rslave dev/
    cd ..
}

function umount_rbind() {
    echo "Unmounting directories"
    umount -R "$1"/proc
    umount -R "$1"/sys
    umount -R "$1"/dev
}

function ensure_devtmpfs() {
    [[ "$(mount | grep /dev | grep devtmpfs)" ]] || mount -t devtmpfs devtmpfs /dev
}

function mount_iso() {
    if [[ "$prepared" == "true" ]]; then
        return
    fi
    if [[ -d "iso-$_arg_iso" ]]; then
        umount "iso-$_arg_iso" > /dev/null 2>&1 || true
        umount "fs-$_arg_iso" > /dev/null 2>&1 || true
        umount "overlay-$_arg_iso" > /dev/null 2>&1 || true
        rm -rf "iso-$_arg_iso" "fs-$_arg_iso" "overlay-$_arg_iso" "upperdir-$_arg_iso" "workdir-$_arg_iso"
    fi
    mkdir "iso-$_arg_iso" "fs-$_arg_iso" "overlay-$_arg_iso" "upperdir-$_arg_iso" "workdir-$_arg_iso" -p
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

        losetup -f -P "$iso_fullpath"
        mount -o loop,ro -t ext4 "${part}p1" "./fs-$_arg_iso"
    fi
    prepare_fs
    prepared="true"
}

function clone_ansible_repo() {
    export GIT_SSH_COMMAND="ssh -i $(pwd)/$_arg_ssh_priv_key -o IdentitiesOnly=yes -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
    if [[ ! -d ansible ]]; then
        git clone "$ANSIBLE_REPO" ansible
    fi
    cd ansible
    git config --global --add safe.directory "$(pwd)"
    git fetch
    cd ..
}

function get_conffs_hosts() {
    # Use this function to determine a list of hosts matching the --ansible-hosts vauban CLI argument
    # It uses ansible to resolve the ansible-specific syntax
    clone_ansible_repo
    cd ansible && git reset "origin/$_arg_branch" --hard
    cd ${ANSIBLE_ROOT_DIR:-.}
    hook_pre_ansible() { eval "$HOOK_PRE_ANSIBLE" ; } && hook_pre_ansible
    # Call ansible to resolve for us the --limit
    hosts="$(ansible -T 1 --list-hosts "$_arg_ansible_host"',!master-*' 2> /dev/null | tail -n+2 | sed -e 's/ //g' || echo)"
    hook_post_ansible() { eval "$HOOK_POST_ANSIBLE" ; } && hook_post_ansible
    if [[ -z $hosts ]]; then
        echo "Couldn't find any matching host in ansible inventory. If the name
provided is correct, maybe there's an error in function get_conffs_hosts"
    fi
    cd - > /dev/null && cd ..
    add_to_recap conffs_hosts "Building for:$NEWLINE$hosts"
}

function wait_pids() {
    local -n local_pids="$1"
    local -n local_hosts_built="$2"
    local job_name="$3"
    local must_exit
    local return_code
    must_exit="no"

    for i in "${!local_pids[@]}"; do
        return_code=0
        wait "${local_pids[i]}" || let "return_code=1"
        if [[ "$return_code" != 0 ]]; then
            must_exit="yes"  # one fail - everyone fail. No one's left behind !
            add_content_to_recap "[KO] [$job_name] ${local_hosts_built[i]}:${TAB}failed !"
        else
            add_content_to_recap "[OK] [$job_name] ${local_hosts_built[i]}:${TAB}success"
        fi
    done
    if [[ "$must_exit" = "yes" ]]; then
        add_to_recap "$job_name: details" "Job failed !. Check the build details in $recap_file or in $vauban_log_path/*$vauban_start_time/*.log"
        end 1
    fi
}


function ci_commit_sshd_keys() {
    if [[ -n ${CI:-} ]]; then
        git config user.name "$GIT_USERNAME"
        git config user.email "$GIT_EMAIL"
        git remote rm origin2 || true
        git remote add origin2 "https://${GIT_TOKEN_USERNAME}:${GIT_TOKEN_PASSWORD}@$(echo "$CI_REPOSITORY_URL" | sed -e "s,.*@\(.*\),\1,")"
        git add vault && git commit -s -m "[CI] Update vault/" && git push origin2 HEAD:$CI_COMMIT_REF_NAME || true
    fi
}


function bootstrap_upload_in_ci() {
    if [[ -n ${CI:-} ]]; then
        mkdir -p ~/.ssh
        cat >> ~/.ssh/config << EOF
Host *
    user $UPLOAD_CI_SSH_USERNAME
IdentityFile ~/.ssh/deploy_id_ed25519
StrictHostKeyChecking accept-new
EOF
        set "+x"
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

    $real_docker "$@" || $real_docker "$@" || $real_docker "$@" || $real_docker "$@"
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
        echo "Tagging docker image with $REGISTRY/$img_name and pushing it"
        $real_docker tag "$img_name" "$REGISTRY/$img_name:$current_date"
        $real_docker tag "$img_name" "$REGISTRY/$img_name:latest"
        $real_docker push "$REGISTRY/$img_name:$current_date" || \
            $real_docker push "$REGISTRY/$img_name:$current_date"
        $real_docker push "$REGISTRY/$img_name:latest" || \
            $real_docker push "$REGISTRY/$img_name:latest"
        echo "Pushed"

    fi
    return "$ret"
}

function ssh() {
    env ssh -o StrictHostKeyChecking=accept-new $@
}

function scp() {
    env scp -o StrictHostKeyChecking=accept-new $@
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
    echo "Pushing $image:deployed"
    docker push "$image:deployed" || \
        docker push "$image:deployed"
    echo "Pushed"
}

if [[ -n ${CI:-} ]]; then
    vauban_log_path=$CI_BUILDS_DIR/.tmp/vauban
else
    vauban_log_path=/tmp/vauban
fi
vauban_start_time="$(date --iso-8601=seconds)"
recap_file="$vauban_log_path/vauban-recap-$vauban_start_time"
ansible_recap_file="$vauban_log_path/vauban-ansible-recap-$vauban_start_time"

function init_log() {
    mkdir -p "$vauban_log_path"
    mkdir -p "$vauban_log_path/vauban-docker-build-${vauban_start_time}"
    mkdir -p "$vauban_log_path/vauban-prepare-stage-${vauban_start_time}"
    : >> $recap_file
}
init_log

function add_to_recap() {
    set "+x"
    local section="$1"
    shift
    local content="$@"


    printf "\n\n============================\n%s\n============================\n\n%s\n\n" "$section" "$content" >> "$recap_file"
    set "-$VAUBAN_SET_FLAGS"
}

function add_content_to_recap() {
    set "+x"
    local content="$@"

    printf "%s\n" "$content" >> "$recap_file"
    set "-$VAUBAN_SET_FLAGS"
}

function add_section_to_recap() {
    set "+x"
    local section="$@"

    printf "\n\n============================\n%s\n============================\n\n" "$section" >> "$recap_file"
    set "-$VAUBAN_SET_FLAGS"
}

function print_recap() {
    set "+x"

    cat "$recap_file" || true

    set "-$VAUBAN_SET_FLAGS"
}
