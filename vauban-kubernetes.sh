#!/usr/bin/env bash

# set -eEuo pipefail

VAUBAN_KUBERNETES_UUID="$(uuidgen || echo $BASHPID)"
SRC_PATH="$(pwd)"

function kubernetes_init_build_engine() {
    export DEBIAN_APT_GET_PROXY="$DEBIAN_APT_GET_PROXY"
    python3 ./kubernetes_controller.py --action init
}

function kubernetes_cleanup_build_engine() {
    python3 $SRC_PATH/kubernetes_controller.py --action cleanup --uuid "$VAUBAN_KUBERNETES_UUID"
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

    vauban_log "      - Starting Pod for $host"
    if [[ -z "$final_name" ]]; then
        pod_ip="$(python3 kubernetes_controller.py --action create --name "$host" --source "$REGISTRY/$source" --destination "$REGISTRY/$destination:$current_date" --destination "$REGISTRY/$destination:latest" --conffs "$(to_boolean $in_conffs)" --imginfo "$imginfo_update" --uuid "$VAUBAN_KUBERNETES_UUID")"
    else
        pod_ip="$(python3 kubernetes_controller.py --action create --name "$host" --source "$REGISTRY/$source" --destination "$REGISTRY/$destination:$current_date" --destination "$REGISTRY/$destination:latest" --destination "$REGISTRY/$final_name:latest" --destination "$REGISTRY/$final_name:$current_date" --conffs "$(to_boolean $in_conffs)" --imginfo "$imginfo_update" --uuid "$VAUBAN_KUBERNETES_UUID")"
    fi
    vauban_log "      - Pod for $host started successfully"
    echo -e "\n[all]\n$host ansible_host=$pod_ip\n" >> ansible/${ANSIBLE_ROOT_DIR:-.}/inventory
}

function kubernetes_end_stage_for_host() {
    local host="$1"

    vauban_log "      - Waiting for Pod $host to finish"
    python3 kubernetes_controller.py --name "$host" --action end
    vauban_log "      - Pod $host finished successfully"
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
        (
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
            extracted_dest="$KUBE_IMAGE_DOWNLOAD_PATH/layers/$digest"
            if [[ -f "$extracted_dest" ]]; then
                echo "Skipping extraction of $digest: already done"
                continue
            fi
            if [[ ! -f $digest.tar ]]; then
                gunzip < "$digest" > "$digest".tar
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
            rm "$digest.tar"

            i="$((i+1))"
        done
        )
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

    if [[ -d "$dst_path" ]] && [[ -z "$(find "$dst_path" -maxdepth 0 -empty 2>/dev/null)" ]]; then
        find "$dst_path"
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
        rsync -a --force -r -l "$layer_path/" "$dst_path/"
    done

    rm "$src_path.vauban.lock"
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
    layers_number="$(echo "$(kubernetes_get_manifest)" | jq '.layers | length')"
    kubernetes_assemble_layers . "$dst_path" 0 "$((layers_number  - 1))"
    )
}

function kubernetes_build_conffs_for_host() {
    local host="$1"
    local root_image="$2"
    local conffs_image="$3"
    local root_image_local_path="$(image_name_to_local_path "$root_image")"
    local conffs_image_local_path="$(image_name_to_local_path "$conffs_image")"
    local host_local_path="$(image_name_to_local_path "$host")"
    local dst_path="$BUILD_PATH/$host_local_path"

    printf "Building conffs for host=%s\n" "$host"

    kubernetes_download_image "$conffs_image"
    kubernetes_download_image "$root_image"
    root_layers_number="$(cd "$KUBE_IMAGE_DOWNLOAD_PATH/$root_image_local_path" && echo "$(kubernetes_get_manifest)" | jq '.layers | length')"
    (
    cd "$KUBE_IMAGE_DOWNLOAD_PATH/$conffs_image_local_path"
    conffs_layers_number="$(echo "$(kubernetes_get_manifest)" | jq '.layers | length')"
    kubernetes_assemble_layers . "$dst_path" "$root_layers_number" "$((conffs_layers_number - 1))"
    )

    put_sshd_keys "$host" "$dst_path"
    (
    cd "$dst_path"
    if [[ -d toslash ]]; then cp -r toslash/* . && rm -rf toslash; fi
    rm -rf var/lib/apt/lists/*
    )
    (
    cd "$BUILD_PATH"
    tar cvfz "conffs-$host.tgz" \
        -C "$host_local_path" \
        --exclude "var/log" \
        --exclude "var/cache" \
        --exclude "root/ansible" \
        --exclude "root/.ansible" \
        . > /dev/null
    )
    upload_list="$upload_list $BUILD_PATH/conffs-$host.tgz"
    rm -rf "$dst_path"
}

function kubernetes_create_parent_rootfs() {
    local name="$1"
    shift
    local debian_release="$1"
    shift
    local stages=$*
    imginfo="$(echo -e "\n\
---\n\
\n\
debian_release: $debian_release\n\
vauban_branch: FIXME\n\
date: $current_date\n\
stages:\n" | base64 -w0)"
    init_build_engine  # FIXME
    vauban_log " - Creating Pod. Will take some time"
    if (( ${#stages} > 0 )); then
        python3 kubernetes_controller.py --action create --name "$name" --debian-release "$debian_release" --destination "$REGISTRY/debian-$debian_release/iso:$current_date" --destination "$REGISTRY/debian-$debian_release/iso:latest" --conffs "no" --imginfo "$imginfo" --uuid "$VAUBAN_KUBERNETES_UUID" > /dev/null
    else
        python3 kubernetes_controller.py --action create --name "$name" --debian-release "$debian_release" --destination "$REGISTRY/debian-$debian_release/iso:$current_date" --destination "$REGISTRY/debian-$debian_release/iso:latest" --destination $REGISTRY/$_arg_name:$current_date --destination $REGISTRY/$_arg_name:latest --conffs "no" --imginfo "$imginfo" --uuid "$VAUBAN_KUBERNETES_UUID" > /dev/null
    fi
    vauban_log " - Pod created. Waiting for it to finish"
    retry 2 python3 kubernetes_controller.py --name "$name" --action end
    vauban_log " - Pod ended successfully"
}
