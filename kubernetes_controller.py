#!/usr/bin/env python3

import os
import click
from kubernetes import client, config, utils
from kubernetes_controller_resources import cm_dockerfile, secret_registryconfig, get_pod_kaniko_manifest

config.load_kube_config()
k8s_client = client.ApiClient()
api_instance = client.CoreV1Api(k8s_client)


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
    try:
        utils.create_from_dict(k8s_client, secret_registryconfig, namespace=namespace)
    except utils.FailToCreateError as e:
        if e.api_exceptions[0].reason == "Conflict":
            api_instance.patch_namespaced_secret(
                name="vauban-registryconfig", body=secret_registryconfig, namespace=namespace
            )
        else:
            raise

NS = os.environ.get("KUBE_NAMESPACE", "vauban")

def create_pod(name, source, destination):
    kaniko_pod = get_pod_kaniko_manifest(name, source, destination)
    conflict, list_conflicts = check_if_pods_already_exists(NS, [name])
    if conflict:
        print(f"Conflict from {list_conflicts}")
    else:
        utils.create_from_dict(k8s_client, kaniko_pod, namespace=NS)

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
    "--destination",
    default=None,
    show_default=True,
    type=str,
    help="Destination image",
)
def main(action, name, source, destination):
    match action:
        case "init":
            return create_needed_resources(NS)
        case "create":
            return create_pod(name, source, destination)
        case _:
            print(f"Action not defined: {action}")

main()
