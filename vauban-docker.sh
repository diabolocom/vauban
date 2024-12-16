#!/usr/bin/env bash

set -eEuo pipefail

function docker_init_build_engine() {
    :
}

function docker_cleanup_build_engine() {
    :
}

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

function docker_end_stage_for_host() {
    local host="$1"
    local destination="$2"
    local final_name="$3"
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
    docker commit "$host" "$destination"
    if [[ ! -z "$final_name" ]]; then
        docker tag "$destination" "$final_name"
        docker_push "$final_name"
    fi
    docker_push "${local_prefix}/${local_pb}"
    docker logs "$host" 
    docker container rm "$host"
    echo "Docker container commited and pushed. Success !"
}

function docker_build_conffs_for_host() {
    local host="$1"
    local source_name="$2"
    local prefix_name="$3"

    printf "Building conffs for host=%s\n" "$host"
    local current_dir="$(pwd)"
    mkdir -p ${BUILD_DIR} && cd ${BUILD_DIR}
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
    put_sshd_keys "$host" "${BUILD_DIR}/overlayfs-$host/merged"
    (
    cd "${BUILD_DIR}/overlayfs-${host}"
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
    mv "conffs-$host.tgz" "$BUILD_DIR"
    upload_list="$upload_list $BUILD_DIR/conffs-$host.tgz"
    if [[ -n "$overlayfs_args" ]]; then
        umount merged
    fi
    )
}

function docker_prepare_rootfs() {
    local image_name="$1"
    local dest_path="$2"
    docker create --name $$ "$image_name" --entrypoint bash
    (
    cd $dest_path && docker export $$ | tar x
    docker rm $$
    )
}

function docker_create_parent_rootfs() {
    end 1 # FIXME This was broken during the kubernetes engine addition and its various improvements and changes, and
          #       needs some fixing
    mount_iso
    prefix_name="$(get_os_name)"
    import_iso "$prefix_name"
    source_name="${prefix_name}/iso"
}
