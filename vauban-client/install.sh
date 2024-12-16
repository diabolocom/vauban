#!/usr/bin/env bash

set -Eeuo pipefail

if [[ "$EUID" -ne 0 ]]
  then echo "Please run as root"
  exit 1
fi

source .env 2> /dev/null || true
DEST_PATH="${DEST_PATH:-/usr/local/bin/vauban-client}"
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cp client.sh "$DEST_PATH"
unamed="$(uname)"
i_arg=""
if [[ "$unamed" != "Linux" ]]; then
    i_arg=".backup"
fi
sed -e "s,VAUBAN_CLIENT_SOURCE_PATH=FIXME_DURING_INSTALL,VAUBAN_CLIENT_SOURCE_PATH=$SCRIPT_DIR," -i"$i_arg" "$DEST_PATH"
echo "Script successfully installed in $DEST_PATH"
