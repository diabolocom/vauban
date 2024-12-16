#!/usr/bin/env bash

set -eEuo pipefail

function get_http_code() {
    cat <<EOF
import http.server
server_address = ('', 8000)

class answer(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args, **kwargs):
        print(self.path)
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"$1\n")
httpd = http.server.HTTPServer(server_address, answer)
httpd.handle_request()

EOF

}

function update_linux() {
    echo "Updating linux"
    apt-get update
    apt list --installed 2> /dev/null | grep -E 'linux-(header|image)' | cut -d/ -f1 | xargs apt-mark unhold
    apt-get install -y linux-headers-amd64 linux-image-amd64
    apt-get autoremove -y
    apt-get purge -y $(apt list --installed 2> /dev/null | grep linux-head | grep -v linux-headers-amd64/ | head -n-2 | cut -f1 -d'/')
    apt-get purge -y $(apt list --installed 2> /dev/null | grep linux-image | grep -v linux-image-amd64/ | head -n-1 | cut -f1 -d'/')
}

apt list --installed | sed -e 's/stable,stable/stable/g' > /tmp/apt-before
printf 'Package: linux-*-rt-*\nPin: release *\nPin-Priority: -1\n' > /etc/apt/preferences.d/block-kernel-rt
[[ "${IN_CONFFS:-no}" != "yes" ]] && update_linux
apt list --installed 2> /dev/null | grep -E 'linux-(header|image)' | cut -d/ -f1 | xargs apt-mark hold
echo "Ready ! Waiting for the stage to begin"
while true; do
    status="$(timeout 120 python3 <(get_http_code "ready"))"
    if [[ "$status" == "/failed" ]]; then
        echo "failed signaled to us. exiting ..."
        exit 1
    elif [[ "$status" == "/ready" ]]; then
        break
    else
        echo "Unknown status sent: $status"
    fi
done
echo "Began ! Waiting for the stage to end"
status="$(timeout 3600 python3 <(get_http_code "ok"))"
if [[ $status == "/failed" ]]; then
    echo "failed signaled to us. exiting ..."
    exit 1
fi
echo "Stage ended with status=$status"
echo -e "\n\
- playbook: ${PLAYBOOK}\n\
  hostname: ${HOST_NAME}\n\
  packages: |" >> /packages
apt list --installed | sed -e 's/stable,stable/stable/g' > /tmp/apt-after
diff /tmp/apt-before /tmp/apt-after | grep '^[<>]' | sed 's/</          -/g' | sed 's/>/          +/g' >> /packages
rm -rf /root/.ansible /tmp/*
