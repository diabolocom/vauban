#!/usr/bin/env bash

set -e
source vauban-config.sh

function process_file() {
    host="$1"
    if [[ ! -f "$host".tar.gpg ]]; then
        echo error, $host.tar.gpg not found for some reason
        exit 1
    else
        echo "$VAULTED_SSHD_KEYS_KEY" | gpg -d --no-symkey-cache --pinentry-mode loopback --passphrase-fd 0 "$host.tar.gpg" 2>/dev/null > "$host.tar"
        tar xf "$host.tar"
        rm "$host.tar"
    fi
    (
    cd $host/etc/ssh/
    keys_algos="$(jo -a $(jo type=ed25519 size=256) $(jo type=rsa size=4096) $(jo type=ecdsa size=384))"
    echo $keys_algos | jq -c '.[]' | while read keys_algo; do
        type="$(echo "$keys_algo" | jq -r .type)"
        size="$(echo "$keys_algo" | jq -r .size)"
        kv_out="$(vault kv get -format json "$VAULT_PATH"sshd/"$host"/"$type" 2>/dev/null | jq .data.data || true)"
        key_name="ssh_host_${type}_key"
        if [[ ! -f "$key_name" ]]; then
            echo generating key
            ssh-keygen -t "$type" -f "$key_name" -q -N "" -b "$size"
        fi
        echo pushing $key_name to $host/$type
        vault kv put "$VAULT_PATH"sshd/"$host"/"$type" @<(jo "$type=@$key_name" "$type.pub=@$key_name.pub") > /dev/null
    done
    )

    rm -rf "$host"
}

function main() {
    (
    cd vault
    for file in $(find -name '*.gpg'); do
        host="${file//.tar.gpg/}"
        host="${host//.\/}"
        process_file "$host"
    done
    )
}
main
