from flask import Flask, session
from flask import request, jsonify
import os
from kubernetes import client, config, utils
from kubernetes.client.rest import ApiException
from kubernetes.stream import stream
from ulid import ULID
from .kube import get_vauban_job
import sentry_sdk
from sentry_sdk import capture_exception
from sentry_sdk.integrations.flask import FlaskIntegration

SENTRY_DSN = os.environ.get("SENTRY_DSN", None)
if SENTRY_DSN:
    sentry_sdk.init(
        dsn=SENTRY_DSN,
        integrations=[
            FlaskIntegration(
                transaction_style="url",
            ),
        ],
        enable_tracing=False,
    )


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
        return (
            jsonify({"status": "error", "message": "Need some JSON arguments man"}),
            400,
        )
    ulid = str(ULID())
    try:
        vauban_cli = [
            "./vauban.py",
            "--name",
            args["name"],
            "--stage",
            args["stage"],
        ]
    except KeyError as e:
        return (
            jsonify(
                {
                    "status": "error",
                    "message": f"Need some more arguments. missing: {e}\n",
                }
            ),
            400,
        )
    for arg in ("build-parents", "branch", "conffs"):
        if arg in args:
            vauban_cli += [f"--{arg}", args[arg]]
    if "extra-args" in args:
        vauban_cli += [args["extra-args"]]
    # FIXME make it configurable
    manifest = get_vauban_job(
        ulid,
        args.get("vauban-image", "zarakailloux/vauban:latest"),
        vauban_cli,
    )

    try:
        api_response = batch_api_instance.create_namespaced_job(namespace, manifest)
    except ApiException as e:
        capture_exception(e)
        return (
            jsonify({"status": "error", "message": f"Failed to run a new job: {e}\n"}),
            500,
        )
    return jsonify({"status": "ok", "job_ulid": ulid})


def _get_logs(ulid):
    try:
        pods_response = core_api_instance.list_namespaced_pod(
            namespace,
            label_selector=f"vauban.corp.dblc.io/vauban-job-id={ulid.upper()}",
        )
    except ApiException as e:
        pods_response = None
    pods = {}
    if pods_response is not None:
        for pod in pods_response.items:
            pods[pod.metadata.creation_timestamp] = {
                "name": pod.metadata.name,
                "status": pod.status.container_statuses[0].state,
            }
    log_list = []
    for key in sorted(pods.keys()):
        pod = pods[key]
        try:
            pod_log = core_api_instance.read_namespaced_pod_log(
                pod["name"], namespace, tail_lines=150
            )
            log_obj = {"status": "ok", "logs": pod_log}
        except ApiException as e:
            error_msg = f"Error while getting pod logs: {e}"
            log_obj = {"status": "error", "message": error_msg}
        log_list.append(log_obj)
    return {"logs": log_list[-1], "previous_pods_logs": log_list[:-1]}


@app.route("/status/<ulid>")
def status(ulid):
    try:
        api_response = batch_api_instance.read_namespaced_job(
            f"vauban-{ulid.lower()}", namespace
        )
    except ApiException as e:
        return (
            jsonify(
                {"status": "error", "message": f"Error while trying to get jod: {e}"}
            ),
            500,
        )
    log_objs = _get_logs(ulid)
    status = api_response.status
    if (
        status.active is None
        and status.completion_time is None
        and status.failed > 0
        and status.ready == 0
    ):
        return jsonify({"status": "error", "message": "Job failed !"} | log_objs), 500
    if status.active is not None:
        return (
            jsonify(
                {"status": "in-progress", "message": "Job is currently running"}
                | log_objs
            ),
            202,
        )
    if status.active is None and status.completion_time is not None:
        return jsonify(
            {"status": "ok", "message": "Job is done ! Build successful"} | log_objs
        )

    capture_exception(Exception(status))
    return (
        jsonify(
            {"status": "unknown", "message": f"Job in an unknown state: {str(status)}"}
        ),
        500,
    )


@app.route("/delete/<ulid>", methods=["DELETE", "POST"])
def delete(ulid):
    try:
        api_response = batch_api_instance.delete_namespaced_job(
            f"vauban-{ulid.lower()}", namespace, propagation_policy="Background"
        )
    except ApiException as e:
        if str(e.status) == "404":
            return jsonify({"status": "ok", "message": "Already deleted !"}), 200
        return (
            jsonify(
                {"status": "error", "message": f"Error while trying to get jod: {e}"}
            ),
            500,
        )
    return jsonify({"status": "ok", "message": "Deleted !"}), 201


@app.route("/readiness")
def readiness():
    return "ok"


@app.route("/health")
def health():
    return "ok"