#!/usr/bin/env bash

# shellcheck disable=SC2029

# Building images with dracut and docker

set -eTEo pipefail


# shellcheck source=vauban-config.sh
source vauban-config.sh
# shellcheck source=utils.sh
source utils.sh
# shellcheck source=vauban-backend.sh
source vauban-backend.sh
source vauban-docker.sh
source vauban-kubernetes.sh

[ "$(whoami)" != "root" ] && run_as_root

function check_args() {
    if [[ "$_arg_rootfs" = "yes" ]]; then
        if [[ -z "$_arg_debian_release" && -z "$_arg_source_image" ]]; then
            echo "You're trying to build a roofs (an image) without giving me a base !"
            echo "You must provide a debian release name, or the name of another image to be used as a base"
            echo
            print_help
            exit 1
        fi
    fi
    if [[ "$_arg_conffs" = "yes" ]] && [[ -z "$_arg_ansible_host" ]]; then
        echo "Won't build the config rootfs (conffs): --ansible-host not provided"
        _arg_conffs="no"
    fi
    if [[ "$_arg_conffs" = "yes" ]] && [[ "$_arg_rootfs" = "no" ]] && [[ -z "$_arg_source_image" ]]; then
        echo "Can't build conffs from ISO only, without building rootfs. Specify a source image with -s"
        exit 1
    fi
    if [[ "$_arg_initramfs" = "yes" ]] && [[ -z "$_arg_debian_release" ]]; then
        echo "Building the initramfs requires a debian release (--debian-release) to get the kernel and kernel modules from"
        exit 1
    fi
    if [[ "$_arg_kernel" = "yes" ]] && [[ -z "$_arg_debian_release" ]]; then
        echo "Building the kernel requires a debian release (--debian-release) to get the kernel version and sources from"
        exit 1
    fi
    if [[ "$_arg_build_engine" != "docker" ]] && [[ "$_arg_build_engine" != "kubernetes" ]]; then
        echo "--build-engine only supported values: docker, kubernetes"
        exit 1
    fi
}

function main() {
    local kernel
    local kernel_version=""
    local prefix_name
    local source_name
    local upload_list=""
    # Try to be nicer
    ionice -c3 -p $$ > /dev/null 2>&1 || true
    renice -n 20 $$ > /dev/null 2>&1 || true

    check_args


vauban_log "$NEWLINE$(cat <<"EOF"

 ____      ____        ____    ____   ____       _____          ____  _____   ______
|    |    |    |  ____|\   \  |    | |    | ___|\     \    ____|\   \|\    \ |\     \
|    |    |    | /    /\    \ |    | |    ||    |\     \  /    /\    \\\    \| \     \
|    |    |    ||    |  |    ||    | |    ||    | |     ||    |  |    |\|    \  \     |
|    |    |    ||    |__|    ||    | |    ||    | /_ _ / |    |__|    | |     \  |    |
|    |    |    ||    .--.    ||    | |    ||    |\    \  |    .--.    | |      \ |    |
|\    \  /    /||    |  |    ||    | |    ||    | |    | |    |  |    | |    |\ \|    |
| \ ___\/___ / ||____|  |____||\___\_|____||____|/____/| |____|  |____| |____||\_____/|
 \ |   ||   | / |    |  |    || |    |    ||    /     || |    |  |    | |    |/ \|   ||
  \|___||___|/  |____|  |____| \|____|____||____|_____|/ |____|  |____| |____|   |___|/
    \(    )/      \(      )/      \(   )/    \(    )/      \(      )/     \(       )/
     '    '        '      '        '   '      '    '        '      '       '       '
=======================================================================================
EOF
)"
vauban_log "                                $current_date"
vauban_log "recap file: $recap_file"
    if [[ "$_arg_rootfs" = "yes" ]]; then
        if [[ -n "$_arg_source_image" ]]; then
            prefix_name="$(echo "$_arg_source_image" | cut -d'/' -f1)"
            source_name="$_arg_source_image"
        else
            create_parent_rootfs "$_arg_name" "$_arg_debian_release" "${_arg_stages[@]}"
            prefix_name="debian-$_arg_debian_release"
            source_name="$prefix_name/iso"
        fi
        build_rootfs "$source_name" "$prefix_name" "$_arg_name" "$_arg_name" "${_arg_stages[@]}"
        _arg_source_image="$source_name"  # conffs will be built on top of what we just built
    fi
    if [[ "$_arg_conffs" = "yes" ]]; then
        if [[ -n "$_arg_source_image" ]]; then
            prefix_name="$(echo "$_arg_source_image" | cut -d'/' -f1)"
            build_conffs "$_arg_source_image" "$prefix_name"
        else
            build_conffs "$_arg_name" "$prefix_name"
        fi
    fi
    if [[ "$_arg_initramfs" = "yes" ]]; then
        [[ -z "${name:-}" ]] && name="$_arg_name"
        build_initramfs "$name"
        kernel="./vmlinuz-default"
        #kernel_version="$(get_kernel_version "$kernel")"
    fi
    if [[ "$_arg_kernel" = "yes" ]]; then
        [[ -z "${name:-}" ]] && name="$_arg_name"
        build_kernel "$name"
        kernel="./vmlinuz"
        kernel_version="$(get_kernel_version "$kernel")"
    fi
    if [[ $_arg_upload = "yes" ]]; then
        upload "$_arg_name" "$kernel_version" "$upload_list"
        if [[ "$_arg_rootfs" = "yes" ]]; then
            set_deployed "$_arg_name"
        fi
    fi
    vauban_log "Done ! Exiting at $current_date"
    end 0
}

# ARG_OPTIONAL_SINGLE([rootfs],[r],[Build the rootfs ?],[yes])
# ARG_OPTIONAL_SINGLE([initramfs],[i],[Build the initramfs ?],[yes])
# ARG_OPTIONAL_SINGLE([kernel],[p],[Build the custom kernel ?],[yes])
# ARG_OPTIONAL_SINGLE([conffs],[l],[Build the conffs ?],[yes])
# ARG_OPTIONAL_SINGLE([upload],[u],[Upload the generated master to DHCP servers ?],[yes])
# ARG_OPTIONAL_SINGLE([debian-release],[d],[The Debian release to use as a base (bookworm, testing, ...)])
# ARG_OPTIONAL_SINGLE([source-image],[s],[The source image to use as a base])
# ARG_OPTIONAL_SINGLE([ssh-priv-key],[k],[The SSH private key used to access Ansible repository ro],[./ansible-ro])
# ARG_OPTIONAL_SINGLE([name],[n],[The name of the image to be built],[master-test])
# ARG_OPTIONAL_SINGLE([branch],[b],[The name of the ansible branch],[master])
# ARG_OPTIONAL_SINGLE([ansible-host],[a],[The ansible hosts to generate the config rootfs on. Equivalent to ansible's --limit, but is empty by default],[])
# ARG_OPTIONAL_SINGLE([build-engine],[e],[The build engine used by vauban. Can be docker, kubernetes],[kubernetes])
# ARG_OPTIONAL_SINGLE([kubernetes-no-cleanup],[],[Don't cleanup kubernetes resources in the end],[no])
# ARG_POSITIONAL_INF([stages],[The stages to add to this image, i.e. the ansible playbooks to apply. For example pb_base.yml],[0])
# ARG_HELP([Build master images and makes coffee])
# ARGBASH_SET_INDENT([    ])
# ARGBASH_GO()
# needed because of Argbash --> m4_ignore([
### START OF CODE GENERATED BY Argbash v2.9.0 one line above ###
# Argbash is a bash code generator used to get arguments parsing right.
# Argbash is FREE SOFTWARE, see https://argbash.io for more info
# Generated online by https://argbash.io/generate


die()
{
    local _ret="${2:-1}"
    test "${_PRINT_HELP:-no}" = yes && print_help >&2
    echo "$1" >&2
    exit "${_ret}"
}


begins_with_short_option()
{
    local first_option all_short_options='ripludsknbaeh'
    first_option="${1:0:1}"
    test "$all_short_options" = "${all_short_options/$first_option/}" && return 1 || return 0
}

# THE DEFAULTS INITIALIZATION - POSITIONALS
_positionals=()
_arg_stages=()
# THE DEFAULTS INITIALIZATION - OPTIONALS
_arg_rootfs="yes"
_arg_initramfs="yes"
_arg_kernel="yes"
_arg_conffs="yes"
_arg_upload="yes"
_arg_debian_release=
_arg_source_image=
_arg_ssh_priv_key="./ansible-ro"
_arg_name="master-test"
_arg_branch="master"
_arg_ansible_host=
_arg_build_engine="kubernetes"
_arg_kubernetes_no_cleanup="no"


print_help()
{
    printf '%s\n' "Build master images and makes coffee"
    printf 'Usage: %s [-r|--rootfs <arg>] [-i|--initramfs <arg>] [-p|--kernel <arg>] [-l|--conffs <arg>] [-u|--upload <arg>] [-d|--debian-release <arg>] [-s|--source-image <arg>] [-k|--ssh-priv-key <arg>] [-n|--name <arg>] [-b|--branch <arg>] [-a|--ansible-host <arg>] [-e|--build-engine <arg>] [--kubernetes-no-cleanup <arg>] [-h|--help] [<stages-1>] ... [<stages-n>] ...\n' "$0"
    printf '\t%s\n' "<stages>: The stages to add to this image, i.e. the ansible playbooks to apply. For example pb_base.yml"
    printf '\t%s\n' "-r, --rootfs: Build the rootfs ? (default: 'yes')"
    printf '\t%s\n' "-i, --initramfs: Build the initramfs ? (default: 'yes')"
    printf '\t%s\n' "-p, --kernel: Build the custom kernel ? (default: 'yes')"
    printf '\t%s\n' "-l, --conffs: Build the conffs ? (default: 'yes')"
    printf '\t%s\n' "-u, --upload: Upload the generated master to DHCP servers ? (default: 'yes')"
    printf '\t%s\n' "-d, --debian-release: The Debian release to use as a base (bookworm, testing, ...) (no default)"
    printf '\t%s\n' "-s, --source-image: The source image to use as a base (no default)"
    printf '\t%s\n' "-k, --ssh-priv-key: The SSH private key used to access Ansible repository ro (default: './ansible-ro')"
    printf '\t%s\n' "-n, --name: The name of the image to be built (default: 'master-test')"
    printf '\t%s\n' "-b, --branch: The name of the ansible branch (default: 'master')"
    printf '\t%s\n' "-a, --ansible-host: The ansible hosts to generate the config rootfs on. Equivalent to ansible's --limit, but is empty by default (no default)"
    printf '\t%s\n' "-e, --build-engine: The build engine used by vauban. Can be docker, kubernetes (default: 'kubernetes')"
    printf '\t%s\n' "--kubernetes-no-cleanup: Don't cleanup kubernetes resources in the end (default: 'no')"
    printf '\t%s\n' "-h, --help: Prints help"
}


parse_commandline()
{
    _positionals_count=0
    while test $# -gt 0
    do
        _key="$1"
        case "$_key" in
            -r|--rootfs)
                test $# -lt 2 && die "Missing value for the optional argument '$_key'." 1
                _arg_rootfs="$2"
                shift
                ;;
            --rootfs=*)
                _arg_rootfs="${_key##--rootfs=}"
                ;;
            -r*)
                _arg_rootfs="${_key##-r}"
                ;;
            -i|--initramfs)
                test $# -lt 2 && die "Missing value for the optional argument '$_key'." 1
                _arg_initramfs="$2"
                shift
                ;;
            --initramfs=*)
                _arg_initramfs="${_key##--initramfs=}"
                ;;
            -i*)
                _arg_initramfs="${_key##-i}"
                ;;
            -p|--kernel)
                test $# -lt 2 && die "Missing value for the optional argument '$_key'." 1
                _arg_kernel="$2"
                shift
                ;;
            --kernel=*)
                _arg_kernel="${_key##--kernel=}"
                ;;
            -p*)
                _arg_kernel="${_key##-p}"
                ;;
            -l|--conffs)
                test $# -lt 2 && die "Missing value for the optional argument '$_key'." 1
                _arg_conffs="$2"
                shift
                ;;
            --conffs=*)
                _arg_conffs="${_key##--conffs=}"
                ;;
            -l*)
                _arg_conffs="${_key##-l}"
                ;;
            -u|--upload)
                test $# -lt 2 && die "Missing value for the optional argument '$_key'." 1
                _arg_upload="$2"
                shift
                ;;
            --upload=*)
                _arg_upload="${_key##--upload=}"
                ;;
            -u*)
                _arg_upload="${_key##-u}"
                ;;
            -d|--debian-release)
                test $# -lt 2 && die "Missing value for the optional argument '$_key'." 1
                _arg_debian_release="$2"
                shift
                ;;
            --debian-release=*)
                _arg_debian_release="${_key##--debian-release=}"
                ;;
            -d*)
                _arg_debian_release="${_key##-d}"
                ;;
            -s|--source-image)
                test $# -lt 2 && die "Missing value for the optional argument '$_key'." 1
                _arg_source_image="$2"
                shift
                ;;
            --source-image=*)
                _arg_source_image="${_key##--source-image=}"
                ;;
            -s*)
                _arg_source_image="${_key##-s}"
                ;;
            -k|--ssh-priv-key)
                test $# -lt 2 && die "Missing value for the optional argument '$_key'." 1
                _arg_ssh_priv_key="$2"
                shift
                ;;
            --ssh-priv-key=*)
                _arg_ssh_priv_key="${_key##--ssh-priv-key=}"
                ;;
            -k*)
                _arg_ssh_priv_key="${_key##-k}"
                ;;
            -n|--name)
                test $# -lt 2 && die "Missing value for the optional argument '$_key'." 1
                _arg_name="$2"
                shift
                ;;
            --name=*)
                _arg_name="${_key##--name=}"
                ;;
            -n*)
                _arg_name="${_key##-n}"
                ;;
            -b|--branch)
                test $# -lt 2 && die "Missing value for the optional argument '$_key'." 1
                _arg_branch="$2"
                shift
                ;;
            --branch=*)
                _arg_branch="${_key##--branch=}"
                ;;
            -b*)
                _arg_branch="${_key##-b}"
                ;;
            -a|--ansible-host)
                test $# -lt 2 && die "Missing value for the optional argument '$_key'." 1
                _arg_ansible_host="$2"
                shift
                ;;
            --ansible-host=*)
                _arg_ansible_host="${_key##--ansible-host=}"
                ;;
            -a*)
                _arg_ansible_host="${_key##-a}"
                ;;
            -e|--build-engine)
                test $# -lt 2 && die "Missing value for the optional argument '$_key'." 1
                _arg_build_engine="$2"
                shift
                ;;
            --build-engine=*)
                _arg_build_engine="${_key##--build-engine=}"
                ;;
            -e*)
                _arg_build_engine="${_key##-e}"
                ;;
            --kubernetes-no-cleanup)
                test $# -lt 2 && die "Missing value for the optional argument '$_key'." 1
                _arg_kubernetes_no_cleanup="$2"
                shift
                ;;
            --kubernetes-no-cleanup=*)
                _arg_kubernetes_no_cleanup="${_key##--kubernetes-no-cleanup=}"
                ;;
            -h|--help)
                print_help
                exit 0
                ;;
            -h*)
                print_help
                exit 0
                ;;
            *)
                _last_positional="$1"
                _positionals+=("$_last_positional")
                _positionals_count=$((_positionals_count + 1))
                ;;
        esac
        shift
    done
}


assign_positional_args()
{
    local _positional_name _shift_for=$1
    _positional_names=""
    _our_args=$((${#_positionals[@]} - 0))
    for ((ii = 0; ii < _our_args; ii++))
    do
        _positional_names="$_positional_names _arg_stages[$((ii + 0))]"
    done

    shift "$_shift_for"
    for _positional_name in ${_positional_names}
    do
        test $# -gt 0 || break
        eval "$_positional_name=\${1}" || die "Error during argument parsing, possibly an Argbash bug." 1
        shift
    done
}

parse_commandline "$@"
assign_positional_args 1 "${_positionals[@]}"

# OTHER STUFF GENERATED BY Argbash

### END OF CODE GENERATED BY Argbash (sortof) ### ])
# [ <-- needed because of Argbash

main

# ] <-- needed because of Argbash
