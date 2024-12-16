from flask import Flask
from flask import request
import os
from kubernetes import client, config, utils
from kubernetes.client.rest import ApiException
from kubernetes.stream import stream
from ulid import ULID
from .kube import get_vauban_job

app = Flask(__name__)

try:
    try:
        config.load_kube_config(config_file="/home/app/.kube/config")
    except:
        config.load_kube_config()
except:
    config.load_incluster_config()

k8s_client = client.ApiClient()
core_api_instance = client.CoreV1Api(k8s_client)
batch_api_instance = client.BatchV1Api(k8s_client)
namespace = os.environ.get("VAUBAN_NAMESPACE", "vauban")

@app.route("/build", methods=["POST"])
def build():
    try:
        args = request.get_json(force=True)
    except Exception as e:
        print(f"Exception in get_json: {e}")
        return "Need some arguments man\n", 400
    ulid = str(ULID())
    try:
        vauban_cli = [
            "./vauban.py",
            "--name",
            args['name'],
            "--stage",
            args['stage'],
            ]
    except KeyError as e:
        return f"Need some more arguments man\nmissing: {e}\n", 400
    for arg in ("build-parents", "branch", "conffs"):
        if arg in args:
            vauban_cli += [f"--{arg}", args[arg]]
    if "extra-args" in args:
        vauban_cli += [args["extra-args"]]
    # FIXME make it configurable
    manifest = get_vauban_job(ulid, args.get("vauban-image", "zarakailloux/vauban:latest"), vauban_cli)

    try:
        api_response = batch_api_instance.create_namespaced_job(namespace, manifest)
    except ApiException as e:
        return f"Failed to run a new job: {e}\n"
    return ulid

@app.route("/status/<ulid>")
def status(ulid):
    try:
        api_response = batch_api_instance.read_namespaced_job(f"vauban-{ulid.lower()}", namespace)
    except ApiException as e:
        return f"Error while trying to get jod: {e}"
    status = api_response.status
    if status.active is None and status.completion_time is None and status.failed > 0 and status.ready == 0:
        return "Job failed !"
        # FIXME pod logs
    return f"Job in an unknown state: {str(status)}"

@app.route("/delete/<ulid>", methods=["DELETE", "POST"])
def delete(ulid):
    try:
        api_response = batch_api_instance.delete_namespaced_job(f"vauban-{ulid.lower()}", namespace, propagation_policy="Background")
    except ApiException as e:
        if str(e.status) == "404":
            return "Already deleted !", 200
        return f"Error while trying to get jod: {e}", 400
    return "Deleted !", 201

@app.route("/readiness")
def readiness():
    return "ok"

@app.route("/health")
def health():
    return "ok"
