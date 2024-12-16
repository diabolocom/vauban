#!/usr/bin/env bash

PROCESS_NAME=main
export PS4='+ [$PROCESS_NAME][${FUNCNAME:-main}] '

NEWLINE=$'\n'
TAB=$'\t'

set -eTEo pipefail

set "-$VAUBAN_SET_FLAGS"

trap 'set +x; end 1' SIGUSR1 SIGTERM
trap 'set +x; end' EXIT
trap 'set +x; catch_err $?' ERR

get_pgid() {
    cut -d " " -f 5 < "/proc/$$/stat" | tr ' ' '\n'
}


pgid="$(get_pgid)"
if [[ "$$" != "$pgid" ]]; then
    exec setsid "$(readlink -f "$0")" "$@"
fi

function run_as_root() {
    echo "Must be run as root"
    exit 1
}

function to_boolean() {
    local val="$1"
    if [[ "$val" == "yes" ]]; then
        echo True
    else
        echo False
    fi
}

function cleanup() {
    local iso8601
    rm -rf tmp rootfs.img "$STACKTRACE_FILE"

    # Keep the conffs that were built (in case it's needed), but move them
    # so that they won't be sent again to dhcp servers on upload
    #
    if [[ -d overlayfs ]]; then
        (
        cd overlayfs
        shopt -s nullglob
        iso8601="$(date --iso-8601=seconds)"
        for dir in overlayfs-*; do
            mv "$dir" "$iso8601-$dir"
        done
        )
    fi

    umount linux-build/merged > /dev/null 2> /dev/null || true
    losetup -D > /dev/null 2> /dev/null || true

    # Remove our locks
    find "$BUILD_PATH" "$KUBE_IMAGE_DOWNLOAD_PATH" -maxdepth 2 -type f -name "*.vauban.lock" -exec bash -c 'file="$1" ; [[ "'$$'" = "$(cat "$file")" ]] && rm "$file"' bash {} \; 2> /dev/null

    "${_arg_build_engine}"_cleanup_build_engine
}

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]:-.}" )" &> /dev/null && pwd )
function stacktrace() {
    cd "$SCRIPT_DIR"
    local i=1 line file func
    while read -r line func file < <(caller "$i"); do
        printf "[%s] %+20s:%-3s %s(): %s\n" "$i" "$file" "$line" "$func" "$(sed -n "$line"p "$file")" 1>&2
        i=$((i+1))
    done
}

function send_sentry() {
     # Don't do anything if sentry-cli command doesn't exist
    if ! command -v sentry-cli > /dev/null; then
        return 0
    fi

    local return_code="${1:-}"
    local stacktrace_msg="${2:-}"
    cd "$SCRIPT_DIR"
    local line file func
    read -r line func file < <(caller 1)
    error_line="$(sed -n "$line"p "$file" | awk '{$1=$1};1')"

    UPLOAD_CI_SSH_KEY='***' UPLOAD_CREDS='***' VAULTED_SSHD_KEYS_KEY='***' REGISTRY_PASSWORD='***' sentry-cli send-event \
        -m "'$error_line': return code ${return_code}" \
        -t conffs:"${_arg_conffs:-}" \
        -t rootfs:"${_arg_rootfs:-}" \
        -t name:"${_arg_name:-}" \
        -t stages:"${_arg_stages:-}" \
        -e this_cmd:"${this_command:-}" \
        -t kernel:"${_arg_kernel:-}" \
        -t upload:"${_arg_upload:-}" \
        -t debian_release:"${_arg_debian_release:-}" \
        -t branch:"${_arg_branch:-}" \
        -t initramfs:"${_arg_initramfs:-}" \
        -t source_image:"${_arg_source_image:-}" \
        -a "$stacktrace_msg" \
        -t user_sudo:"${SUDO_USER:-${USER:-undefined}}" \
        --logfile "$recap_file" || echo Could not send sentry event 1>&2
}

STACKTRACE_FILE="$(mkdir -p /tmp/vauban > /dev/null && mktemp -p /tmp/vauban/)"
function catch_err() {
    if [[ "${ANSIBLE_PLAYBOOK_RUNNING:-false}" == "false" ]]; then
        stacktrace_msg="$(stacktrace 2>&1)"
        send_sentry "$1" "$stacktrace_msg"
        if [[ -n ${2:-} ]]; then
            tail -n 15 "$2" >> "$STACKTRACE_FILE"
        fi
        echo -e "$stacktrace_msg" >> "$STACKTRACE_FILE"
    fi
    if [[ "$$" == "$BASHPID" ]]; then
        end 1
    else
        PGID="$(get_pgid)"
        kill -10 -- "$PGID"
        sleep 1
        kill -15 -- -"$PGID" > /dev/null 2> /dev/null
        wait > /dev/null 2> /dev/null
    fi
}

function end() {
    local return_code="${1:-}"
    trap '' EXIT
    set +xeE
    [[ -z "$(jobs -p)" ]] || kill "$(jobs -p)" 2> /dev/null
    if [[ "$$" == "$BASHPID" ]]; then
        if [[ -z "$return_code" ]] || [[ "$return_code" == "0" ]]; then
            print_recap "$return_code"
        fi

        if [[ "${ANSIBLE_PLAYBOOK_RUNNING:-false}" == "true" ]]; then
            vauban_log "   - ansible-playbook failed !"
            tail -n 30 "$ansible_recap_file" >&2
        else
            cat "$STACKTRACE_FILE" >&2
        fi
        cleanup
    fi
    [[ -z "$return_code" ]] || exit "$return_code"
}

function image_name_to_local_path() {
    echo "${1//\//_}"
}

function find_kernel() {
    local path="$1"
    find "$path" -type f -name 'vmlinuz*' | sort | tail -n 1
}

function get_kernel_version() {
    file "$1" | grep -oE 'version ([^ ]+)' | sed -e 's/version //'
}

function get_rootfs_kernel_version() {
    local working_dir="$1"
    file "$(find "$working_dir"/boot -type f -name "vmlinuz*" | sort | tail -n 1)" | grep -oE "version ([^ ]+)" | sed -e "s/version //"
}

function bootstrap_release() {
    local release_path="$1"
    if [[ -n "$DEBIAN_APT_GET_PROXY" ]]; then
        echo 'Acquire::HTTP::Proxy "'"$DEBIAN_APT_GET_PROXY"'";' > "$release_path/etc/apt/apt.conf.d/01-proxy"
    fi
    vauban_log " - Preparing the debian release with needed packages and latest kernel"
    chroot "$release_path" bin/bash <<- "EOF"
    set -e;
    echo "" > /etc/fstab;
    export DEBIAN_FRONTEND=noninteractive

    debian_version="$(cat /etc/debian_version)"

    if [[ "$debian_version" > 12 ]]; then
        sed -i 's/main$/main contrib non-free non-free-firmware/' /etc/apt/sources.list;
    else
        sed -i 's/main$/main contrib non-free/' /etc/apt/sources.list;
    fi
    echo "Removing grub and updating and installing some base packages";
    export INITRD=No
    apt-get update;
    apt-get install -o Dpkg::Options::="--force-confold" --force-yes -y firmware-bnx2x locales lsb-release xfsprogs isc-dhcp-client;
    localedef -i en_US -f UTF-8 en_US.UTF-8
    if [[ "$version" = "10."* ]]; then
        apt-get install -y -o Dpkg::Options::="--force-confold" --force-yes dracut dracut-core dracut-network 2>&1 > /dev/null || true
    else
        (
        cd /tmp
        apt-get download dracut-core dracut-network dracut-live dracut-squash
        PATH=/usr/local/sbin:/usr/bin/:/sbin dpkg -i dracut*  || true
        apt-get install -y --fix-broken
        )
    fi
    apt-get remove -y initramfs-tools grub2-common > /dev/null;
    echo "Updating linux kernel and headers";
    apt-get install -o Dpkg::Options::="--force-confold" --force-yes -y linux-image-amd64 linux-headers-amd64 > /dev/null;
    # remove old kernel/headers version.
    # List all linux headers/image, get only 'local' (meaning the one installed but not downloadable anymore, aka old kernel version)
    # extract package name and remove
    apt-get clean -y;
    apt-get remove -y $(apt list --installed 2>/dev/null | grep -E 'linux-(headers|image)-' | grep local 2>&1 | sed -E 's/\/.+$//g') > /dev/null;
    apt-get autoremove -y;
EOF
}

function prepare_debian_release() {
    local release_path="$1"
    # FIXME remove after use
    if [[ -d "$release_path" ]]; then
        vauban_log "Working directory $release_path is already being used"
        end 1
    fi
    mkdir -p "$release_path" "$DEBIAN_CACHE_PATH"
    vauban_log " - Running debootstrap"
    http_proxy=$DEBIAN_APT_GET_PROXY https_proxy=$DEBIAN_APT_GET_PROXY debootstrap --cache-dir="$DEBIAN_CACHE_PATH" --include=curl,ca-certificates,xz-utils,console-setup --extra-suites="${_arg_debian_release}"-proposed-updates "$_arg_debian_release" "$release_path"
    bootstrap_release "$release_path"
    vauban_log " - Debian release prepared"
}


function clone_ansible_repo() {
    GIT_SSH_COMMAND="ssh -i $(pwd)/$_arg_ssh_priv_key -o IdentitiesOnly=yes -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
    export GIT_SSH_COMMAND
    if [[ ! -d ansible ]]; then
        git clone "$ANSIBLE_REPO" ansible 2> /dev/null
    fi
    (
    cd ansible
    git config --global --add safe.directory "$(pwd)"
    git fetch 2> /dev/null
    )
}

function get_conffs_hosts() {
    # Use this function to determine a list of hosts matching the --ansible-hosts vauban CLI argument
    # It uses ansible to resolve the ansible-specific syntax
    clone_ansible_repo
    local current_dir
    current_dir="$(pwd)"
    cd ansible && git reset "origin/$_arg_branch" --hard
    cd "${ANSIBLE_ROOT_DIR:-.}"
    hook_pre_ansible() { eval "$HOOK_PRE_ANSIBLE" ; } && hook_pre_ansible
    # Call ansible to resolve for us the --limit
    hosts="$(ansible -T 1 --list-hosts "$_arg_ansible_host"',!master-*' 2> /dev/null | tail -n+2 | sed -e 's/ //g' || echo)"
    hook_post_ansible() { eval "$HOOK_POST_ANSIBLE" ; } && hook_post_ansible
    if [[ -z $hosts ]]; then
        echo "Couldn't find any matching host in ansible inventory. If the name
provided is correct, maybe there's an error in function get_conffs_hosts"
    fi
    vauban_log "Building for:$NEWLINE$hosts"
    cd "$current_dir"
}

function wait_pids() {
    local -n local_pids="$1"
    local -n local_hosts_built="$2"
    local must_exit return_code
    must_exit="no"

    for i in "${!local_pids[@]}"; do
        return_code=0
        wait "${local_pids[i]}" || let "return_code=1"
        if [[ "$return_code" != 0 ]]; then
            must_exit="yes"  # one fail - everyone fail. No one's left behind !
        fi
    done
    if [[ "$must_exit" = "yes" ]]; then
        end 1
    fi
}



docker_loggedin="$(grep \""$REGISTRY_HOSTNAME"\" ~/.docker/config.json 2> /dev/null > /dev/null || echo false)"
current_date="$(date -u +%FT%H%M)"
function docker_login() {
    if [[ $docker_loggedin = "false" ]]; then
        docker_loggedin="true"
        if [[ -z "$REGISTRY_PASSWORD" ]]; then
            echo no REGISTRY_PASSWORD variable found, and not currently logged in to the docker registry.
            exit 1
        fi

        if [[ ! -f ~/.docker/config.json ]]; then
            mkdir ~/.docker
            jo auths="$(jo "$REGISTRY_HOSTNAME"="$(jo auth="$(printf "$REGISTRY_USERNAME":"$REGISTRY_PASSWORD" | base64 -w 0)")")" > ~/.docker/config.json
        else
            new_docker_config="$(jq -s '.[0] * .[1]' ~/.docker/config.json <(jo auths="$(jo "$REGISTRY_HOSTNAME"="$(jo auth="$(printf "$REGISTRY_USERNAME":"$REGISTRY_PASSWORD" | base64 -w 0)")")"))"
            echo "$new_docker_config" > ~/.docker/config.json
        fi
    fi
}
docker_login

function retry() {
    local n="$1"
    shift
    for i in $(seq 1 "$n"); do
        if (( i >= n )); then
            "$@"
        else
            # shellcheck disable=SC2015 # I know
            "$@" && break || true
        fi
    done
}

function docker_push() {
    local img_name="$1"

    vauban_log "Tagging docker image with $REGISTRY/$img_name"
    docker tag "$img_name" "$REGISTRY/$img_name:$current_date"
    docker tag "$img_name" "$REGISTRY/$img_name:latest"
    if [[ $_arg_upload == "yes" ]]; then
        vauban_log " - Pushing images"
        retry 3 docker push "$REGISTRY/$img_name:$current_date"
        retry 3 docker push "$REGISTRY/$img_name:latest"
        vauban_log " - Pushed"
    fi
}

function ssh() {
    env ssh -o StrictHostKeyChecking=accept-new "$@"
}

function scp() {
    env scp -o StrictHostKeyChecking=accept-new "$@"
}

function pull_image() {
    local image="$1"
    # shellcheck disable=SC2015  # I know what I'm doing
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
    if [[ $_arg_build_engine == "kubernetes" ]]; then
        retry 3 skopeo copy "docker://$image:$tag" "docker://$image:deployed"
    else
        docker tag "$image:$tag" "$image:deployed"
        retry 3 docker push "$image:deployed"
    fi
}

if [[ -n ${CI:-} ]]; then
    vauban_log_path=$CI_BUILDS_DIR/.tmp/vauban
else
    vauban_log_path=/tmp/vauban
fi
vauban_start_time="$(date --iso-8601=seconds | tr : _ | cut -d '+' -f1)"
recap_file="$vauban_log_path/$vauban_start_time-vauban.log"
ansible_recap_file="$vauban_log_path/$vauban_start_time-vauban-ansible.log"

function vauban_log() {
    printf "[%+15s] %s\n" "$PROCESS_NAME" "$@" | tee -a "$recap_file"
}

function print_recap() {
    set "+x"

    if [[ ${VAUBAN_PRINT_RECAP:-yes} == "yes" ]]; then
        echo "================================================="
        echo "================= RECAP ========================="
        echo "================================================="
        echo ""
        cat "$recap_file" || true
    fi
}
