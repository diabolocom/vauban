#!/usr/bin/env bash

# Configuration variables and secrets for vauban
# You can either edit this file directly, or put the variables in a secret
# not-commited file .secrets.env, or provide the values by the env directly
# (the best option for CI for example)

# optionnal. A way to fill-in the variables below
# File must contain things like `export REGISTRY_HOSTNAME='my_value'`
source .secrets.env || true

# You can also edit this directly. By default, its looks for the variable in the
# env, and put the default value (the string after `:-`) if it doesn't exist
REGISTRY_HOSTNAME="${REGISTRY_HOSTNAME:-}"
REGISTRY="${REGISTRY_HOSTNAME}/vauban"
REGISTRY_USERNAME="${REGISTRY_USERNAME:-}"
REGISTRY_PASSWORD=${REGISTRY_PASSWORD:-}

ANSIBLE_REPO="${ANSIBLE_REPO:-}"
ANSIBLE_ROOT_DIR="${ANSIBLE_ROOT_DIR:-}"  # Where is the root dir of ansible's repo (inventory, ansible.cfg, ...)
# Extra arguments that will be provided to ansible-playbook call
# Useful to add --extra-vars for example, or any kind of ansible-playbook flag
ANSIBLE_EXTRA_ARGS="${ANSIBLE_EXTRA_ARGS:-}"

# SSH access to upload
UPLOAD_CI_SSH_USERNAME="${UPLOAD_CI_SSH_USERNAME:-}"
UPLOAD_CI_SSH_KEY="${UPLOAD_CI_SSH_KEY:-}"  # Must be base64 encoded

UPLOAD_HOSTS_LIST="${UPLOAD_HOSTS_LIST:-}"
UPLOAD_DIR="${UPLOAD_DIR:-}"
# UNIX group to chown uploaded files to
UPLOAD_OWNER="${UPLOAD_OWNER:-}"

# Password to use to encrypt and decrypt the sshd keys that will be put per host
VAULTED_SSHD_KEYS_KEY="${VAULTED_SSHD_KEYS_KEY:-}"

# Git authentication details to automatically commit and push ssh keys generated
# in the CI
GIT_USERNAME="${GITLAB_USER_NAME:-}"
GIT_EMAIL="${GITLAB_USER_EMAIL:-}"
GIT_TOKEN_USERNAME="${GIT_TOKEN_USERNAME:-}"
GIT_TOKEN_PASSWORD="${GIT_TOKEN_PASSWORD:-}"

if [[ -z ${HOOK_PRE_ANSIBLE+x} ]]; then
    HOOK_PRE_ANSIBLE="$(cat <<- "EOV"
# Put some script here that will be executed before ansible-playbook
EOV
)"
fi

if [[ -z ${HOOK_POST_ANSIBLE+x} ]]; then
    HOOK_POST_ANSIBLE="$(cat <<- "EOV"
# Put some script here that will be executed after ansible-playbook
EOV
)"
fi

# Flag to give to `set`. Put a `x` to have `set -x` and enable bash debug/verbose
# mode. This flag may be disabled in specific sections
VAUBAN_SET_FLAGS="${VAUBAN_SET_FLAGS:-}"
