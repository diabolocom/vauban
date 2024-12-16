#!/usr/bin/env bash

set -eEuo pipefail

function kubernetes_prepare_stage_for_host() {
    local host="$1"
    local playbook="$2"
    local source="$3"
    local branch="$4"
    local in_conffs="$5"
    local destination="$6"
    local timeout=600

    ansible_sha1="$( (cd ansible; git rev-parse HEAD) )"
    vauban_sha1="$(git rev-parse HEAD)"
    imginfo_update="$(echo -e "\n\
    - date: $(date --iso-8601=seconds)\n\
      playbook: ${playbook}\n\
      hostname: ${host}\n\
      source: ${source}\n\
      git-sha1: ${ansible_sha1}\n\
      git-branch: ${branch}\n\
      build-engine: kubernetes\n\
      vauban-sha1: ${vauban_sha1}\n" | base64 -w0)"

    python3 kubernetes_controller.py --action create --name "$host" --source "$REGISTRY/$source" --destination "$REGISTRY/$destination"
    exit 1
}
