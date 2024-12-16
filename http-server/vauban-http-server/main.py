"""
    Main entrypoint for VaubanHTTPServer
"""

import os
import time
from .kube import get_vauban_job
from .slack import SlackNotif
from . import app, batch_api_instance, core_api_instance, namespace
from flask import request, jsonify
from kubernetes.client.rest import ApiException
from ulid import ULID
from sentry_sdk import capture_exception

slack_notif = SlackNotif()


@app.route("/")
def _help():
    """
    Return some help
    """

    return """
    Available routes:
        /build
            method: POST
            description: Starts a build job
            arguments:
                name (mandatory): name of the master to build
                stage (mandatory): stage to run (rootfs, conffs, initramfs)
                build-parents: Number of parent stages to run
                branch: Override config.yml's branch argument
                conffs: Override config.yml's conffs argument
                extra-args: Extra arguments to give to vauban.py, as a str
                vauban-image: Docker image to use for Vauban. Impacts config.yml
                no-cleanup: Don't cleanup Kubernetes resources automatically (/delete API route still works)
            returns: Object containing `status` and possibly a `job_ulid` if job got accepted
        /status/<ulid>
            method: GET
            description: returns information about the build job specified by the ULID
            returns: Object containing at least `status`, `message` and `logs`
        /delete/<ulid>
            method: DELETE POST
            description: delete a build job and its resources allocated. Will interrupt vauban if it's running
    """


@app.route("/build", methods=["POST"])
def build():
    """
    Starts a build job. Returns json
    """
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
        stage = args["stage"]
        name = args["name"]
        vauban_cli = ["./vauban.py", "--name", name, "--stage", stage]
        notif_infos = {"stage": stage, "name": name}
    except KeyError as e:
        return (
            jsonify(
                {
                    "status": "error",
                    "message": f"Need some more arguments. missing: {e}",
                }
            ),
            400,
        )
    for arg in ("build-parents", "branch", "conffs"):
        if arg in args:
            vauban_cli += [f"--{arg}", args[arg]]
            notif_infos |= {arg: args[arg]}
    if "extra-args" in args:
        vauban_cli += [args["extra-args"]]
        notif_infos |= {"extra-args": args["extra-args"]}
    if "no-cleanup" in args and args["no-cleanup"].lower() in [
        "true",
        "yes",
        "on",
        "1",
    ]:
        vauban_cli += ["--kubernetes-no-cleanup"]
        notif_infos |= {"kubernetes no cleanup": "yes"}
    # FIXME make it configurable
    manifest = get_vauban_job(
        ulid,
        args.get("vauban-image", "zarakailloux/vauban:latest"),
        [str(e) for e in vauban_cli],
    )
    for _ in range(10):
        ex = None
        try:
            batch_api_instance.create_namespaced_job(namespace, manifest)
            break
        except ApiException as e:
            ex = e
            time.sleep(0.2)
    else:
        capture_exception(ex)
        return (
            jsonify({"status": "error", "message": f"Failed to run a new job: {ex}\n"}),
            500,
        )
    slack_notif.create_notification(
        ulid, notif_infos, {"source": os.environ.get("HOSTNAME", "undefined")}
    )

    err_count = 0
    ex = None
    while i < 100 and err_count < 3:
        i += 1
        try:
            batch_api_instance.read_namespaced_job(f"vauban-{ulid.lower()}", namespace)
            break
        except ApiException as e:
            ex = e
            if str(e.status) == "404":
                time.sleep(0.2)
                continue
            err_count += 1
            if err_count != 3:
                time.sleep(0.2)

    if (err_count == 3 or i >= 99) and ex is not None:
        capture_exception(ex)
        return (
            jsonify(
                {"status": "error", "message": f"Failed to get the new job: {ex}\n"}
            ),
            500,
        )

    return jsonify({"status": "ok", "job_ulid": ulid})


def _get_logs(ulid):
    """
    Get a log object from an ulid, logs coming from one or multiple pods
    """
    try:
        pods_response = core_api_instance.list_namespaced_pod(
            namespace,
            label_selector=f"vauban.corp.dblc.io/vauban-job-id={ulid.upper()},vauban.corp.dblc.io/vauban-type=controller",
        )
    except ApiException as e:
        pods_response = None
    pods = {}
    if pods_response is not None:
        for pod in pods_response.items:
            if pod.status.container_statuses is not None:
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
    if log_list is None or len(log_list) == 0:
        return {"logs": None, "previous_pods_logs": []}
    return {"logs": log_list[-1], "previous_pods_logs": log_list[:-1]}


def get_last_n_log_lines(log_objs, n=5):
    """
    Filter a log object to return only n lines of logs
    """
    if log_objs is None or log_objs["logs"] is None:
        return None
    if log_objs["logs"]["status"] == "error":
        return []
    if log_objs["logs"]["status"] == "ok":
        return log_objs["logs"]["logs"].strip().split("\n")[-n:]
    raise Exception("Code shouldn't be reached")


@app.route("/status/<ulid>")
def _status(ulid):
    """
    Returns the current status of a build job, and update slack's message
    """
    for _ in range(10):
        ex = None
        try:
            api_response = batch_api_instance.read_namespaced_job(
                f"vauban-{ulid.lower()}", namespace
            )
        except ApiException as e:
            ex = e
            if str(e.status) == "404":
                return (
                    jsonify({"status": "error", "message": "Cannot find such job"}),
                    404,
                )
            time.sleep(0.2)
    else:
        capture_exception(ex)
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
        and status.failed is not None
        and status.failed > 0
        and status.ready == 0
    ):
        slack_notif.update_error(
            ulid,
            {"status": "failed"},
            {},
            get_last_n_log_lines(log_objs),
            lengthy_log_trace=get_last_n_log_lines(log_objs, 150),
        )
        return jsonify({"status": "error", "message": "Job failed !"} | log_objs), 500
    if status.active is not None:
        slack_notif.update_in_progress(ulid, {}, {}, get_last_n_log_lines(log_objs))
        return (
            jsonify(
                {"status": "in-progress", "message": "Job is currently running"}
                | log_objs
            ),
            202,
        )
    if status.active is None and status.completion_time is not None:
        slack_notif.update_done(
            ulid, {"status": "built"}, {}, get_last_n_log_lines(log_objs)
        )
        return jsonify(
            {"status": "ok", "message": "Job is done ! Build successful"} | log_objs
        )
    if (
        status.active is None
        and status.completion_time is None
        and status.terminating is None
        and status.failed is None
    ):
        slack_notif.update_creation(ulid, {}, {})
        return (
            jsonify(
                {
                    "status": "in-progress",
                    "message": "Job is waiting on Kubernetes resources to be created",
                }
            ),
            202,
        )

    capture_exception(Exception(status))
    slack_notif.update_broken(ulid, {}, {}, get_last_n_log_lines(log_objs))
    return (
        jsonify(
            {"status": "unknown", "message": f"Job in an unknown state: {str(status)}"}
        ),
        500,
    )


@app.route("/delete/<ulid>", methods=["DELETE", "POST"])
def delete(ulid):
    """
    Delete a build job and its associated resources
    """
    try:
        pods_response = core_api_instance.list_namespaced_pod(
            namespace,
            label_selector=f"vauban.corp.dblc.io/vauban-job-id={ulid.upper()}",
        )
        if pods_response is not None:
            for pod in pods_response.items:
                core_api_instance.delete_namespaced_pod(
                    pod.metadata.name, namespace, propagation_policy="Background"
                )

        jobs_response = batch_api_instance.list_namespaced_job(
            namespace,
            label_selector=f"vauban.corp.dblc.io/vauban-job-id={ulid.upper()}",
        )
        if jobs_response is not None:
            for job in jobs_response.items:
                batch_api_instance.delete_namespaced_job(
                    job.metadata.name, namespace, propagation_policy="Background"
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
    finally:
        try:
            slack_notif.update_garbage_collected(ulid, {}, {}, None)
        except Exception as e:
            capture_exception(e)
    return jsonify({"status": "ok", "message": "Deleted !"}), 201


@app.route("/readiness")
def readiness():
    """
    is ready ?
    """
    return "ok"


@app.route("/health")
def health():
    """
    is alive ?
    """
    return "ok"
