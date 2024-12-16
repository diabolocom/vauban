
secret_registryconfig = {
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {"name": "vauban-registryconfig"},
    "data": {
        "config.json": "FIXME"
    },
}

dockerfile_txt = """ARG SOURCE
FROM $SOURCE
RUN bash -c 'mkdir -p /root/.ssh && \
        echo "FIXME" >> /root/.ssh/authorized_keys && \
        ssh-keygen -A && \
        echo -e "PermitRootLogin yes\\nPasswordAuthentication no\\nPubkeyAuthentication yes\\nSubsystem sftp /usr/lib/openssh/sftp-server" > /tmp/vauban_sshd && \
        mkdir /run/sshd && \
        { /usr/sbin/sshd -D -e -f /tmp/vauban_sshd ; } & \
        for i in $(seq 1 3600); do \
            if [[ -f /tmp/vauban_success ]]; then \
                rm /tmp/vauban_* && \
                sed -i "/vauban_build/d" /root/.ssh/authorized_keys ;\
                exit 0 ;\
            fi ;\
            sleep 1 ;\
        done ;\
        exit 1 \
        '
"""

cm_dockerfile = {
    "apiVersion": "v1",
    "kind": "ConfigMap",
    "metadata": {"name": "vauban-dockerfile"},
    "data": {"Dockerfile": dockerfile_txt},
}


def get_pod_kaniko_manifest(name, source, tags, in_conffs):
    pod_kaniko = {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {"name": name},
        "spec": {
            "containers": [
                {
                    "name": "kaniko",
                    "image": "gcr.io/kaniko-project/executor:latest",
                    "args": [
                        "--dockerfile=./Dockerfile",
                        "--context=dir:///srv/vauban",
                        "--build-arg",
                        "SOURCE=" + source,
                        ] + ["--destination=" + tag for tag in tags]
                    ,
                    "volumeMounts": [
                        {"name": "dockerfile", "mountPath": "/srv/vauban"},
                        {
                            "name": "registryconfig",
                            "mountPath": "/kaniko/.docker",
                        },
                    ],
                    "ports": [{"containerPort": 22}],
                    "env": [{"name": "IN_CONFFS", "value": in_conffs}, {"name": "PATH", "value": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"}]
                }
            ],
            "restartPolicy": "Never",
            "volumes": [
                {
                    "name": "dockerfile",
                    "configMap": {
                        "name": "vauban-dockerfile",
                        "items": [{"key": "Dockerfile", "path": "Dockerfile"}],
                    },
                },
                {
                    "name": "registryconfig",
                    "secret": {"secretName": "vauban-registryconfig"},
                },
            ],
        },
    }
    return pod_kaniko
