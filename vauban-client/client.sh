#!/usr/bin/env bash

trap 'end 1' ERR SIGTERM
set -ETeuo"$VAUBAN_CLIENT_FLAG" pipefail

RED="\e[91m"
GREEN="\e[92m"
YELLOW="\e[93m"
GRAY="\e[90m"
ENDCOLOR="\e[0m"
VERSION=0.8.4

USER_AGENT="${VAUBAN_CLIENT_USER_AGENT:-vauban-client} / $VERSION"

VAUBAN_CLIENT_CONFIG_PATH="${VAUBAN_CLIENT_CONFIG_PATH:-$HOME/.config/vauban_client.json}"

VAUBAN_CLIENT_SOURCE_PATH=FIXME_DURING_INSTALL
VAUBAN_ENDPOINT_DEFAULT=${VAUBAN_ENDPOINT_DEFAULT:-http://localhost}

function check_for_dependencies() {
    dependencies="curl jo jq python3 git"
    for dep in $dependencies; do
        command -v "$dep" >/dev/null || ( echo "$dep not found ! Please install it for this script to be working" ; exit 1 )
    done
}

function parse_or_reset_config() {
    local config

    if [[ ! -f "$VAUBAN_CLIENT_CONFIG_PATH" ]] || [[ $_arg_reset_config == "on" ]]; then
        echo -e "${YELLOW}Vauban client configuration file does not exist ($VAUBAN_CLIENT_CONFIG_PATH)${ENDCOLOR}"
        read -r -p "Let's create it. What your username ? " USERNAME
        echo "Good ! Now I need a password if Vauban is password protected"
        read -r -p "password: " APP_PASSWORD
        read -r -p "What endpoint to use ? (default: $VAUBAN_ENDPOINT_DEFAULT): " VAUBAN_ENDPOINT
        if [[ "$VAUBAN_ENDPOINT" == "" ]]; then
            VAUBAN_ENDPOINT="$VAUBAN_ENDPOINT_DEFAULT"
        fi
        jo "username=$USERNAME" "app_password=$APP_PASSWORD" "endpoint=$VAUBAN_ENDPOINT" > "$VAUBAN_CLIENT_CONFIG_PATH"
    fi

    config="$(cat "$VAUBAN_CLIENT_CONFIG_PATH")"
    USERNAME="$(echo "$config" | jq -r .username)"
    APP_PASSWORD="$(echo "$config" | jq -r .app_password)"
    VAUBAN_ENDPOINT="$(echo "$config" | jq -r .endpoint)"
}

function auth_curl() {
    local endpoint="$1"
    shift
    curl -s -u "$USERNAME:$APP_PASSWORD" -H "User-Agent: $USER_AGENT" "$VAUBAN_ENDPOINT$endpoint" "$@"
}

function cleanup() {
    set +eu
    if [[ "$_arg_no_cleanup" != "yes" ]] && [[ "$_arg_no_cleanup" != "on" ]]; then
        echo -e "${GRAY}Asked to cleanup things ...${ENDCOLOR}"
        auth_curl "/delete/$ulid" -XDELETE >/dev/null 2>/dev/null
    fi
}

function end() {
    cleanup
    exit "$1"
}

function get_recap_block() {
    python3 -c 'import sys; content="\n".join([x.strip() for x in sys.stdin]); print("\n".join(content.split("Building ")[-1].split("\n")[1:]));'
}

function run_build_job() {
    local update_freq=1
    local master
    if [[ -z "$_arg_name" ]]; then
        master="$_arg_master"
    else
        master="$_arg_name"
    fi
    local stage="$_arg_stage"
    jo_args="stage=$stage name=$master"
    if [[ -n $_arg_conffs ]]; then
        jo_args="$jo_args conffs=$_arg_conffs"
    fi
    if [[ -n $_arg_vauban_image ]]; then
        jo_args="$jo_args vauban-image=$_arg_vauban_image"
    fi
    if [[ -n $_arg_branch ]]; then
        jo_args="$jo_args branch=$_arg_branch"
    fi
    if [[ -n $_arg_no_cleanup ]]; then
        jo_args="$jo_args no-cleanup=$_arg_no_cleanup"
    fi
    if [[ -n $_arg_build_parents ]]; then
        jo_args="$jo_args build-parents=$_arg_build_parents"
    fi
    r="$(auth_curl "/build" --json "$(jo $jo_args)" || echo '{"status":"error, could not connect"}')"
    if [[ "$(echo "$r" | jq -r .status)" == "ok" ]]; then
        ulid="$(echo "$r" | jq -r .job_ulid)"
        job_logs=""
        echo -e "Job $YELLOW$ulid$ENDCOLOR added"
    else
        echo "Job was not added correctly ! :("
        echo "$r"
        exit 1
    fi

    for i in $(seq 1 $((3600 / update_freq))); do
        obj="$(auth_curl "/status/$ulid" || echo '{"status": "curl-failed"}')"
        status="$(echo "$obj" | jq -r .status || echo "unknown")"
        if [[ "$status" == "ok" ]]; then
            break
        elif [[ "$status" == "in-progress" ]]; then
            if [[ "$(echo "$obj" | jq -r .logs.status || echo ko)" == ok ]]; then
                prefix="$(echo -e "${YELLOW}[$ulid]$ENDCOLOR ")"
                logs="$(echo "$obj" | jq -r .logs.logs | sed -e 's,^,'"$prefix"',g')"
                diff --changed-group-format='%>' --unchanged-group-format='' <(echo -e "${job_logs}") <(echo -e "$logs") || true
                job_logs="$logs"
            fi
        elif [[ $status == "curl-failed" ]]; then
            echo -e "${YELLOW}[$ulid]$GRAY curl failed. will retry in $update_freq$ENDCOLOR"
        else
            echo -e "${RED}Job $YELLOW$ulid$RED failed ! status=$status"
            if [[ "$status" != "error" ]]; then
                echo "$obj"
            else
                echo "$obj" | jq -r .logs.logs | get_recap_block
            fi
            echo -e "$ENDCOLOR"
            end 1
        fi
        sleep $update_freq
    done
    echo -e "${GREEN}All built !"
}

function show_version() {
    echo -e "${YELLOW}vauban-client${ENDCOLOR} version: $VERSION"
    exit 0
}

function _check_for_update() {
    if [[ "$VAUBAN_CLIENT_SOURCE_PATH" == "FIXME_DURING_INSTALL" ]]; then
        if [[ -f "install.sh" ]]; then
            if [[ ${VAUBAN_CLIENT_DEV:-0} != "1" ]]; then
                echo -e "${YELLOW}Script being run from the directory. If not for development purposes, install it with$ENDCOLOR make install"
            fi
        else
            echo -e "${RED}Script was not installed via install.sh, or unsuccessfully. Will not detect updates but will continue execution$ENDCOLOR"
        fi
    else
        cd "$VAUBAN_CLIENT_SOURCE_PATH" && \
        timeout 3 git fetch && \
        remote_version="$(git show origin/main:vauban-client/client.sh | grep VERSION= | grep -Eo '[0-9]+\..+')" && \
        if [[ "$VERSION" != "$remote_version" ]]; then
            echo -e "${GREEN}A new update is available ! New version: $YELLOW$remote_version$ENDCOLOR, current version: $YELLOW$VERSION$ENDCOLOR"
            echo -e "Please follow update instructions on https://github.com/diabolocom/vauban"
        else
            echo -e "${GREEN}Running up-to-date vauban-client (v$VERSION)$ENDCOLOR"
        fi
    fi
}

function check_for_update() {
    _check_for_update || echo -e "${RED}Could not check for update, but will continue"
}

function check_for_empty_args() {
    if [[ $_arg_reset_config == "on" ]]; then
        exit 0
    fi
    local exit_code=0
    if [[ -z "$_arg_master" ]] && [[ -z "$_arg_name" ]]; then
        echo -e "$RED--name argument is not defined !$ENDCOLOR"
        exit_code=1
    fi
    if [[ -z "$_arg_stage" ]]; then
        echo -e "$RED--stage argument is not defined !$ENDCOLOR"
        exit_code=1
    elif [[ "$_arg_stage" != "rootfs" ]] && [[ "$_arg_stage" != "conffs" ]] && [[ "$_arg_stage" != "initramfs" ]] && [[ "$_arg_stage" != "all" ]]; then
        echo -e "$RED--stage argument is not a valid value !$ENDCOLOR\n\tValid values include: rootfs, conffs, initramfs, all"
        exit_code=1
    fi

    if [[ $exit_code != 0 ]]; then
        exit $exit_code
    fi
}

function main() {
    if [[ "$_arg_version" == "on" ]]; then
        show_version
    fi
    check_for_dependencies
    if [[ "${CHECK_FOR_UPGRADE:-on}" == "on" ]]; then
        check_for_update
    fi
    parse_or_reset_config
    check_for_empty_args
    trap 'cleanup' EXIT
    run_build_job
}

# ARG_OPTIONAL_SINGLE([name],[n],[Name of the master to build])
# ARG_OPTIONAL_SINGLE([master],[m],[Name of the master to build (alias to --name)])
# ARG_OPTIONAL_SINGLE([stage],[s],[Stage to build (rootfs, conffs, initramfs)])
# ARG_OPTIONAL_SINGLE([vauban-image],[i],[Override default vauban docker image to use])
# ARG_OPTIONAL_SINGLE([branch],[b],[Ansible branch to use (override config.yml)])
# ARG_OPTIONAL_SINGLE([conffs],[c],[Conffs hosts to build (override config.yml)])
# ARG_OPTIONAL_SINGLE([build-parents],[p],[How many parents objects to build],[0])
# ARG_OPTIONAL_SINGLE([no-cleanup],[],[Don't cleanup kubernetes resources],[no])
# ARG_OPTIONAL_SINGLE([extra-args],[x],[Extra arguments to provide])
# ARG_OPTIONAL_BOOLEAN([reset-config],[],[Reset config file ?])
# ARG_OPTIONAL_BOOLEAN([version],[v],[Print the version])
# ARG_HELP([Show the help msg])
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
	local first_option all_short_options='nmsibcpxvh'
	first_option="${1:0:1}"
	test "$all_short_options" = "${all_short_options/$first_option/}" && return 1 || return 0
}

# THE DEFAULTS INITIALIZATION - OPTIONALS
_arg_name=
_arg_master=
_arg_stage=
_arg_vauban_image=
_arg_branch=
_arg_conffs=
_arg_build_parents="0"
_arg_no_cleanup="no"
_arg_extra_args=
_arg_reset_config="off"
_arg_version="off"


print_help()
{
	printf '%s\n' "Show the help msg"
	printf 'Usage: %s [-n|--name <arg>] [-m|--master <arg>] [-s|--stage <arg>] [-i|--vauban-image <arg>] [-b|--branch <arg>] [-c|--conffs <arg>] [-p|--build-parents <arg>] [--no-cleanup <arg>] [-x|--extra-args <arg>] [--(no-)reset-config] [-v|--(no-)version] [-h|--help]\n' "$0"
	printf '\t%s\n' "-n, --name: Name of the master to build (no default)"
	printf '\t%s\n' "-m, --master: Name of the master to build (alias to --name) (no default)"
	printf '\t%s\n' "-s, --stage: Stage to build (rootfs, conffs, initramfs) (no default)"
	printf '\t%s\n' "-i, --vauban-image: Override default vauban docker image to use (no default)"
	printf '\t%s\n' "-b, --branch: Ansible branch to use (override config.yml) (no default)"
	printf '\t%s\n' "-c, --conffs: Conffs hosts to build (override config.yml) (no default)"
	printf '\t%s\n' "-p, --build-parents: How many parents objects to build (default: '0')"
	printf '\t%s\n' "--no-cleanup: Don't cleanup kubernetes resources (default: 'no')"
	printf '\t%s\n' "-x, --extra-args: Extra arguments to provide (no default)"
	printf '\t%s\n' "--reset-config, --no-reset-config: Reset config file ? (off by default)"
	printf '\t%s\n' "-v, --version, --no-version: Print the version (off by default)"
	printf '\t%s\n' "-h, --help: Prints help"
}


parse_commandline()
{
	while test $# -gt 0
	do
		_key="$1"
		case "$_key" in
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
			-m|--master)
				test $# -lt 2 && die "Missing value for the optional argument '$_key'." 1
				_arg_master="$2"
				shift
				;;
			--master=*)
				_arg_master="${_key##--master=}"
				;;
			-m*)
				_arg_master="${_key##-m}"
				;;
			-s|--stage)
				test $# -lt 2 && die "Missing value for the optional argument '$_key'." 1
				_arg_stage="$2"
				shift
				;;
			--stage=*)
				_arg_stage="${_key##--stage=}"
				;;
			-s*)
				_arg_stage="${_key##-s}"
				;;
			-i|--vauban-image)
				test $# -lt 2 && die "Missing value for the optional argument '$_key'." 1
				_arg_vauban_image="$2"
				shift
				;;
			--vauban-image=*)
				_arg_vauban_image="${_key##--vauban-image=}"
				;;
			-i*)
				_arg_vauban_image="${_key##-i}"
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
			-c|--conffs)
				test $# -lt 2 && die "Missing value for the optional argument '$_key'." 1
				_arg_conffs="$2"
				shift
				;;
			--conffs=*)
				_arg_conffs="${_key##--conffs=}"
				;;
			-c*)
				_arg_conffs="${_key##-c}"
				;;
			-p|--build-parents)
				test $# -lt 2 && die "Missing value for the optional argument '$_key'." 1
				_arg_build_parents="$2"
				shift
				;;
			--build-parents=*)
				_arg_build_parents="${_key##--build-parents=}"
				;;
			-p*)
				_arg_build_parents="${_key##-p}"
				;;
			--no-cleanup)
				test $# -lt 2 && die "Missing value for the optional argument '$_key'." 1
				_arg_no_cleanup="$2"
				shift
				;;
			--no-cleanup=*)
				_arg_no_cleanup="${_key##--no-cleanup=}"
				;;
			-x|--extra-args)
				test $# -lt 2 && die "Missing value for the optional argument '$_key'." 1
				_arg_extra_args="$2"
				shift
				;;
			--extra-args=*)
				_arg_extra_args="${_key##--extra-args=}"
				;;
			-x*)
				_arg_extra_args="${_key##-x}"
				;;
			--no-reset-config|--reset-config)
				_arg_reset_config="on"
				test "${1:0:5}" = "--no-" && _arg_reset_config="off"
				;;
			-v|--no-version|--version)
				_arg_version="on"
				test "${1:0:5}" = "--no-" && _arg_version="off"
				;;
			-v*)
				_arg_version="on"
				_next="${_key##-v}"
				if test -n "$_next" -a "$_next" != "$_key"
				then
					{ begins_with_short_option "$_next" && shift && set -- "-v" "-${_next}" "$@"; } || die "The short option '$_key' can't be decomposed to ${_key:0:2} and -${_key:2}, because ${_key:0:2} doesn't accept value and '-${_key:2:1}' doesn't correspond to a short option."
				fi
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
				_PRINT_HELP=yes die "FATAL ERROR: Got an unexpected argument '$1'" 1
				;;
		esac
		shift
	done
}

parse_commandline "$@"

# OTHER STUFF GENERATED BY Argbash

### END OF CODE GENERATED BY Argbash (sortof) ### ])
# [ <-- needed because of Argbash


main

# ] <-- needed because of Argbash
