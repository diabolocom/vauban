#!/usr/bin/env bash

# set -eEuo pipefail

function kubernetes_init_build_engine() {
    python3 ./kubernetes_controller.py --action init
}

function kubernetes_prepare_stage_for_host() {
    local host="$1"
    local playbook="$2"
    local source="$3"
    local branch="$4"
    local in_conffs="$5"
    local destination="$6"
    local final_name="$7"
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

    if [[ -z "$final_name" ]]; then
        pod_ip="$(python3 kubernetes_controller.py --action create --name "$host" --source "$REGISTRY/$source" --destination "$REGISTRY/$destination:$current_date" --destination "$REGISTRY/$destination:latest" --conffs "$(to_boolean $in_conffs)" --imginfo "$imginfo_update")"
    else
        pod_ip="$(python3 kubernetes_controller.py --action create --name "$host" --source "$REGISTRY/$source" --destination "$REGISTRY/$destination:$current_date" --destination "$REGISTRY/$destination:latest" --destination "$REGISTRY/$final_name:latest" --destination "$REGISTRY/$final_name:$current_date" --conffs "$(to_boolean $in_conffs)" --imginfo "$imginfo_update")"
    fi
    echo -e "\n[all]\n$host ansible_host=$pod_ip\n" >> ansible/${ANSIBLE_ROOT_DIR:-.}/inventory
}

function kubernetes_end_stage_for_host() {
    local host="$1"

    python3 kubernetes_controller.py --name "$host" --action end > "$vauban_log_path/vauban-docker-logs-${vauban_start_time}/${host}.log" 2>&1
}

function kubernetes_check_lock_file() {
    if [[ -f "$1" ]]; then
        >&2 echo "$1 file detected. Is another Vauban instance using these files ?"
        end 1
    fi
}

function kubernetes_download_image() {
    local image_name="$1"
    local image_local_path="$(image_name_to_local_path "$image_name")"
    local image_remote_path="docker://$REGISTRY/$image_name"
    (
        mkdir -p "$KUBE_IMAGE_DOWNLOAD_PATH" && cd "$KUBE_IMAGE_DOWNLOAD_PATH"
        mkdir -p oci_shared layers
        kubernetes_check_lock_file "$image_local_path.vauban.lock"
        echo $$ > "$image_local_path.vauban.lock"
        local_digest="$([[ -d "$image_local_path" ]] && cat "$image_local_path"/Digest.vauban || true)"
        remote_digest="$(skopeo inspect "$image_remote_path" | jq .Digest -r)"
        if [[ "$local_digest" == "$remote_digest" ]]; then
            return
        else
            rm -rf "$image_local_path"
        fi
        skopeo copy --dest-shared-blob-dir oci_shared "$image_remote_path" "oci:$image_local_path"
        echo "$remote_digest" > "$image_local_path/Digest.vauban"

        i=0
        manifest_id_sha="$(cat $image_local_path/index.json | jq '.manifests[0].digest' -r)"
        manifest_id="${manifest_id_sha#sha256:}"
        (
        cd "oci_shared/sha256"
        echo "Extracting layers"
        cat "$manifest_id" | jq -r '.layers.[].digest' | while read -r digest_sha; do
            digest="${digest_sha#sha256:}"
            if [[ ! -f $digest.tar ]]; then
                gunzip < "$digest" > "$digest".tar
            fi
            extracted_dest="$KUBE_IMAGE_DOWNLOAD_PATH/layers/$digest"
            if [[ -f "$extracted_dest" ]]; then
                echo "Skipping extraction of $digest: already done"
                continue
            fi
            mkdir -p "$extracted_dest"
            tar_output="$(tar xf "$digest.tar" -C "$extracted_dest" 2>&1 || true)"
            while IFS= read -r line; do
                if [[ -z "$line" ]]; then continue; fi
                if echo "$line" | grep "Removing leading" 2>&1 >/dev/null; then continue; fi
                if echo "$line" | grep "can't create hardlink" 2>&1 >/dev/null; then
                    # FIXME create symlink instead
                    echo "$line"
                    end 1
                else
                    echo "tar error ! $line"
                    end 1
                fi
            done <<< "$tar_output"

            i="$((i+1))"
        done
        )
        rm "$image_local_path.vauban.lock"
    )
}

function kubernetes_assemble_layers() {
    local src_path="$1"
    local dst_path="$2"
    local start="$3"
    local stop="$4"
    local manifest_id_sha manifest_id layer_path

    kubernetes_check_lock_file "$src_path.vauban.lock"
    echo "$$" > "$src_path.vauban.lock"

    if [[ -n "$(find "$dst_path" -maxdepth 0 -empty)" ]]; then
        echo "$dst_path contains files. Can't continue"
        end 1
    fi
    mkdir -p "$dst_path"
    kubernetes_check_lock_file "$dst_path.vauban.lock"
    echo "$$" > "$dst_path.vauban.lock"

    manifest="$(kubernetes_get_manifest "$src_path")"
    for i in $(seq "$start" "$stop"); do
        layer_id="$(echo "$manifest" | jq -r '.layers.['"$i"'].digest')"
        layer_path="$KUBE_IMAGE_DOWNLOAD_PATH/layers/${layer_id#sha256:}"
        cp -f --remove-destination -r "$layer_path/." "$dst_path/"
    done
}

function kubernetes_get_manifest() {
    local src_path="${1:-.}"
    manifest_id_sha="$(cat $src_path/index.json | jq '.manifests[0].digest' -r)"
    manifest_id="${manifest_id_sha#sha256:}"
    cat "$KUBE_IMAGE_DOWNLOAD_PATH/oci_shared/sha256/$manifest_id"
}

function kubernetes_prepare_rootfs() {
    local image_name="$1"
    local dst_path="$2"
    local image_local_path="$(image_name_to_local_path "$image_name")"

    kubernetes_download_image "$image_name"
    (
    cd "$KUBE_IMAGE_DOWNLOAD_PATH/$image_local_path"
    layer_numbers="$(echo "$(kubernetes_get_manifest)" | jq '.layers | length')"
    kubernetes_assemble_layers . "$dst_path" 0 "$((layer_numbers  - 1))"
    )
}

function kubernetes_build_conffs_for_host() {
    local host="$1"
    local source_name="$2"
    local prefix_name="$3"
    echo deb fin
    echo $1
    echo $2
    echo $3
    echo fin

    printf "Building conffs for host=%s\n" "$host"
    local current_dir="$(pwd)"
    end 0


    mkdir -p overlayfs && cd overlayfs
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
    put_sshd_keys "$host" "overlayfs/overlayfs-$host/merged"
    (
    cd "overlayfs/overlayfs-${host}"
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
    if [[ -n "$overlayfs_args" ]]; then
        umount merged
    fi
    )
}
