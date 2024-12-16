import base64
import os

first_rootfs_script = f"DEBIAN_APT_GET_PROXY={os.environ.get('DEBIAN_APT_GET_PROXY', '')}" + """
set -exo pipefail

if [[ -n "$DEBIAN_APT_GET_PROXY" ]]; then
    echo 'Acquire::HTTP::Proxy "'"$DEBIAN_APT_GET_PROXY"'";' > /etc/apt/apt.conf.d/99-build-proxy
fi
apt-get update
apt-get install -y debootstrap tar
http_proxy=$DEBIAN_APT_GET_PROXY https_proxy=$DEBIAN_APT_GET_PROXY debootstrap --include=debconf-utils,openssh-client,openssl,openssh-server,sudo,python3,bash-completion,unattended-upgrades,xz-utils,file,curl,ca-certificates --exclude apparmor,ifupdown --merged-usr "$DEBIAN_RELEASE" "/mnt"
mkdir -p /mnt/proc /mnt/dev /mnt/sys
rm -rf /mnt/var/cache/apt/archives/*deb
tar cf /srv/vauban/rootfs/rootfs.tar -C /mnt .
"""

bash_script = f"DEBIAN_APT_GET_PROXY={os.environ.get('DEBIAN_APT_GET_PROXY', '')}" + """
set -exo pipefail
FROM_SCRATCH=${FROM_SCRATCH:-false}

function update_linux() {
    echo "Updating linux"
    echo "true" > /usr/bin/linux-check-removal
    apt-get update
    apt list --installed 2> /dev/null | grep -E 'linux-(header|image)' | cut -d/ -f1 | xargs apt-mark unhold || true
    apt-get install -y linux-headers-amd64 linux-image-amd64
    apt-get autoremove -y
    apt-get purge -y $(apt list --installed 2> /dev/null | grep linux-head | grep -v linux-headers-amd64/ | head -n-2 | cut -f1 -d'/')
    apt-get purge -y $(apt list --installed 2> /dev/null | grep linux-image | grep -v linux-image-amd64/ | head -n-1 | cut -f1 -d'/')
}

function run_sshd() {
    mkdir -p /root/.ssh
    echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILr4hFLwCjbQmC45rZm+1GO/HMmnc2nrlzCaBjNN/hZX root@vauban" >> /root/.ssh/authorized_keys
    ssh-keygen -A
    echo -e "PermitRootLogin yes\\nPasswordAuthentication no\\nPubkeyAuthentication yes\\nSubsystem sftp /usr/lib/openssh/sftp-server" > /tmp/vauban_sshd
    mkdir -p /run/sshd
    { /usr/sbin/sshd -D -e -f /tmp/vauban_sshd ; } &
}

function from_scratch_metadata_and_leave() {
    echo "Debian release imported"  # Important log line as it will be used as a marker of success
    # FIXME: add /imginfo and /packages files
    :
    exit 0
}

export INITRD=No
rm -rf /tmp/vauban_success

apt list --installed | sed -e 's/stable,stable/stable/g' > /tmp/apt-before
printf 'Package: linux-*-rt-*\nPin: release *\nPin-Priority: -1\n' > /etc/apt/preferences.d/block-kernel-rt
if [[ -n "$DEBIAN_APT_GET_PROXY" ]]; then
    echo 'Acquire::HTTP::Proxy "'"$DEBIAN_APT_GET_PROXY"'";' > /etc/apt/apt.conf.d/99-build-proxy
fi
[[ "${IN_CONFFS:-no}" != "yes" ]] && update_linux
apt list --installed 2> /dev/null | grep -E 'linux-(header|image)' | cut -d/ -f1 | xargs apt-mark hold
rm -f /etc/apt/apt.conf.d/99-build-proxy || true

[[ $FROM_SCRATCH == "false" ]] && run_sshd
[[ $FROM_SCRATCH == "true" ]] && from_scratch_metadata_and_leave

for i in $(seq 1 3600); do
    if [[ -f /tmp/vauban_success ]]; then
        set +e
        rm /tmp/vauban_*
        sed -i "/vauban_build/d" /root/.ssh/authorized_keys ;
        echo -e "\n\
- playbook: ${PLAYBOOK:-fixme}\n\
  hostname: ${HOST_NAME}\n\
  packages: |" >> /packages
        apt list --installed | sed -e 's/stable,stable/stable/g' > /tmp/apt-after
        diff /tmp/apt-before /tmp/apt-after | grep '^[<>]' | sed 's/</          -/g' | sed 's/>/          +/g' >> /packages
        rm -rf /root/.ansible /tmp/* /etc/apt/apt.conf.d/99-build-proxy
        exit 0 ;
    fi ;
    sleep 1 ;
done ;
exit 1
"""

dockerfile_txt = """ARG SOURCE
FROM $SOURCE
ARG HOST_NAME
ARG IN_CONFFS
RUN bash /srv/vauban/entrypoint.sh
"""

dockerfile_scratch_txt = """
FROM scratch
ARG HOST_NAME
WORKDIR /srv/vauban/
ADD ./rootfs/rootfs.tar /
RUN bash -c "FROM_SCRATCH=true bash /srv/vauban/entrypoint.sh"
"""

cm_dockerfile = {
    "apiVersion": "v1",
    "kind": "ConfigMap",
    "metadata": {"name": "vauban-dockerfile"},
    "data": {"Dockerfile": dockerfile_txt, "Dockerfile_scratch": dockerfile_scratch_txt, "entrypoint.sh": bash_script, "first_rootfs.sh": first_rootfs_script},
}


def get_pod_kaniko_manifest(name, source, debian_release, tags, in_conffs, uuid):
    pod_kaniko = {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {"name": name, "labels": {"vauban.corp.dblc.io/uuid": str(uuid)}},
        "spec": {
            "containers": [
                {
                    "name": "kaniko",
                    "image": "gcr.io/kaniko-project/executor:latest",
                    "args": [
                        "--dockerfile=./Dockerfile",
                        "--single-snapshot",
                        "--context=dir:///srv/vauban",
                        ] + ([
                        "--build-arg",
                        "SOURCE=" + source ] if source is not None else []) + [
                        "--build-arg",
                        "IN_CONFFS=" + in_conffs,
                        "--build-arg",
                        "HOST_NAME=" + name,
                        ] + ["--destination=" + tag for tag in tags]
                    ,
                    "volumeMounts": [
                        {"name": "root", "mountPath": "/srv/vauban/rootfs"},
                        {"name": "dockerfile", "mountPath": "/srv/vauban"},
                        {
                            "name": "registryconfig",
                            "mountPath": "/kaniko/.docker",
                        },
                    ],
                    "ports": [{"containerPort": 22}],
                    "env": [{"name": "PATH", "value": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"}]
                }
            ],
            "restartPolicy": "Never",
            "volumes": [
                {
                    "name": "dockerfile",
                    "configMap": {
                        "name": "vauban-dockerfile",
                        "items": [{"key": "Dockerfile" if debian_release is None else "Dockerfile_scratch", "path": "Dockerfile"}, {"key": "entrypoint.sh", "path": "entrypoint.sh"}, {"key": "first_rootfs.sh", "path": "first_rootfs.sh"}],
                    },
                },
                {
                    "name": "registryconfig",
                    "secret": {"secretName": "vauban-registryconfig"},
                },
                {
                    "name": "root",
                    "emptyDir": {},
                },
            ],
        },
    }
    if debian_release is not None:
        init_container = {
                        "name": "init",
                        "image": "debian:12-slim",
                        "args": [
                            "bash", "-c",
                            f"DEBIAN_RELEASE={debian_release} bash /srv/vauban/first_rootfs.sh"
                        ],
                        "volumeMounts": [
                            {"name": "dockerfile", "mountPath": "/srv/vauban"},
                            {"name": "root", "mountPath": "/srv/vauban/rootfs"},
                        ]
                    }
        pod_kaniko['spec']['initContainers'] = [init_container]
    return pod_kaniko
