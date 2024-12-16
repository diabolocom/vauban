
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
        echo -e "PermitRootLogin yes\\nPasswordAuthentication no\\nPubkeyAuthentication yes" > /tmp/vauban_sshd && \
        mkdir /run/sshd && \
        timeout -k 1 3600 /usr/sbin/sshd -D -e -f /tmp/vauban_sshd || true ; \
        if [[ -f /tmp/vauban_success ]]; then \
            rm /tmp/vauban_* && \
            sed -i "/vauban_build/d" /root/.ssh/authorized_keys ;\
        else \
            false ;\
        fi'
"""

cm_dockerfile = {
    "apiVersion": "v1",
    "kind": "ConfigMap",
    "metadata": {"name": "vauban-dockerfile"},
    "data": {"Dockerfile": dockerfile_txt},
}


def get_pod_kaniko_manifest(name, source, tag):
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
                        "--destination=" + tag,
                        "--build-arg",
                        "SOURCE=" + source,
                    ],
                    "volumeMounts": [
                        {"name": "dockerfile", "mountPath": "/srv/vauban"},
                        {
                            "name": "registryconfig",
                            "mountPath": "/kaniko/.docker",
                        },
                    ],
                    "ports": [{"containerPort": 22}],
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
