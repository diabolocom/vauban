#!/usr/bin/env bash

set -eEuo pipefail

function docker_prepare_stage_for_host() {
    local host="$1"
    local playbook="$2"
    local source="$3"
    local branch="$4"
    local in_conffs="$5"
    local container_id
    local timeout=600

    docker image inspect "$source" > /dev/null 2>&1 || pull_image "$source"

    # Let's make sure we work on the new container
    docker container stop "$host" > /dev/null 2>&1 || true
    docker container rm "$host" > /dev/null 2>&1 && echo "!! removed existing container for $host" || true
    docker run \
        --name "$host" \
        --hostname "$host" \
        --add-host "$host:127.0.0.1" \
        --add-host "$host:::1" \
        --env SOURCE="${source}" \
        --env PLAYBOOK="${playbook}" \
        --env HOST_NAME="$host" \
        --env IN_CONFFS="$in_conffs" \
        --volume "$(pwd)"/docker-entrypoint.sh:/docker-entrypoint.sh \
        --entrypoint /docker-entrypoint.sh \
        --user root \
        --detach \
        --workdir /root \
        --tty \
        --tmpfs /tmp \
        ${source}

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
      build-engine: docker\n\
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
