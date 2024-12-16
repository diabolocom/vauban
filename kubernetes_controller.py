#!/usr/bin/env python3

import os
import sys
import click
import time
from datetime import datetime, UTC
from kubernetes import client, config, utils
from kubernetes_controller_resources import cm_dockerfile, get_pod_kaniko_manifest
from kubernetes.stream import stream

def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)

try:
    config.load_kube_config()
except:
    config.load_incluster_config()
k8s_client = client.ApiClient()
api_instance = client.CoreV1Api(k8s_client)
NS = os.environ.get("KUBE_NAMESPACE", "vauban")


def delete_finished_pod(namespace, pod):
    try:
        api_instance.delete_namespaced_pod(pod, namespace=namespace)
    except:
        pass

def check_if_pods_already_exists(namespace, pods):
    assert isinstance(pods, list)

    r = []

    ret = api_instance.list_namespaced_pod(namespace=namespace)
    for pod in ret.items:
        if pod.metadata.name in pods:
            if pod.status.phase in ["Pending", "Running"]:
                r.append(pod.metadata.name)
            else:
                delete_finished_pod(namespace, pod.metadata.name)

    return len(r) > 0, r


def wait_for_and_get_running_pod(namespace, name):
    log_els = ("Server listening on", "Debian release imported")
    start = datetime.now(UTC)
    while (datetime.now(UTC) - start).seconds < 600:
        pod = api_instance.read_namespaced_pod(name=name, namespace=namespace)
        if pod.status.phase == "Failed":
            raise RuntimeError("Pod is in Error/Failed status")
        if pod.status.phase == "Succeeded":
            raise RuntimeError("Pod finished before expectations")
        if pod.status.phase == "Running":
            logs = api_instance.read_namespaced_pod_log(name=name, namespace=namespace, tail_lines=100)
            for log_el in log_els:
                if log_el in logs:
                    return pod
        time.sleep(1)
    raise TimeoutError("Could not find the pod in time")

def create_needed_resources(namespace):
    try:
        utils.create_from_dict(k8s_client, cm_dockerfile, namespace=namespace)
    except utils.FailToCreateError as e:
        if e.api_exceptions[0].reason == "Conflict":
            api_instance.patch_namespaced_config_map(
                name="vauban-dockerfile", body=cm_dockerfile, namespace=namespace
            )
        else:
            raise

def exec_in_pod(name, namespace, exec_command):
    resp = stream(api_instance.connect_get_namespaced_pod_exec,
                  name,
                  namespace,
                  command=exec_command,
                  stderr=True, stdin=False,
                  stdout=True, tty=False)

def update_imginfo(name, namespace, imginfo):
    exec_command = [
        '/usr/bin/env',
        'bash',
        '-c',
        f'echo -e {imginfo} | base64 -d >> /imginfo;']
    exec_in_pod(name, namespace, exec_command)

def create_pod(name, source, debian_release, destination, in_conffs, imginfo):
    kaniko_pod = get_pod_kaniko_manifest(name, source, debian_release, destination, in_conffs)
    conflict, list_conflicts = check_if_pods_already_exists(NS, [name])
    if conflict:
        raise RuntimeError(f"Conflict from {list_conflicts}")
    else:
        utils.create_from_dict(k8s_client, kaniko_pod, namespace=NS)
    pod = wait_for_and_get_running_pod(NS, name)
    print(pod.status.pod_ip)
    if pod is None:
        raise RuntimeError("Pod was not well created")
    update_imginfo(name, NS, imginfo)
    return pod.status.pod_ip

def wait_for_completed_pod(namespace, name):
    start = datetime.now(UTC)
    while (datetime.now(UTC) - start).seconds < 600:
        pod = api_instance.read_namespaced_pod(name=name, namespace=namespace)
        if pod.status.phase == "Failed":
            raise RuntimeError("Pod is in Error/Failed status")
        if pod.status.phase == "Succeeded":
            return pod
        time.sleep(1)
    raise TimeoutError("Could not find the pod in time")

def end_pod(name):
    exec_in_pod(name, NS, ["/usr/bin/env", "bash", "-c", "touch /tmp/vauban_success;"])
    wait_for_completed_pod(NS, name)
    logs = api_instance.read_namespaced_pod_log(name=name, namespace=NS, tail_lines=8)
    print(f"Logs from Pod {name}:")
    print(logs)
    delete_finished_pod(NS, name)

@click.command()
@click.option(
    "--action",
    default="init",
    show_default=True,
    type=str,
    help="The action to execute",
)
@click.option(
    "--name",
    default=None,
    show_default=True,
    type=str,
    help="Name of the pod to operate",
)
@click.option(
    "--source",
    default=None,
    show_default=True,
    type=str,
    help="Source image",
)
@click.option(
    "--debian-release",
    default=None,
    show_default=True,
    type=str,
    help="Source debian release",
)
@click.option(
    "--destination",
    default=[],
    show_default=True,
    multiple=True,
    help="Destination images (allow multiple tags)",
)
@click.option(
    "--conffs",
    default="FALSE",
    show_default=True,
    type=str,
    help="Is a conffs being built ?",
)
@click.option(
    "--imginfo",
    default=None,
    show_default=True,
    type=str,
    help="The base64 encoded imginfo update snippet",
)
def main(action, name, source, debian_release, destination, conffs, imginfo):
    match action:
        case "init":
            return create_needed_resources(NS)
        case "create":
            return create_pod(name, source, debian_release, destination, conffs, imginfo)
        case "end":
            return end_pod(name)
        case _:
            eprint(f"Action not defined: {action}")

main()
