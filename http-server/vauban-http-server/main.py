from flask import Flask
from flask import request
from kubernetes import client, config, utils
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
api_instance = client.CoreV1Api(k8s_client)

@app.route("/build", methods=["POST"])
def build():
    try:
        args = request.get_json(force=True)
    except Exception as e:
        print(f"Exception in get_json: {e}")
        return "Need some arguments man\n", 400
    ulid = str(ULID())
    vauban_cli = [
        "vauban.py",
        "--name",
        args['name'],
        "--stage",
        args['stage'],
        ]
    for arg in ("build-parents", "branch", "conffs"):
        if arg in args:
            vauban_cli += [f"--{arg}", args[arg]]
    if "extra-args" in args:
        vauban_cli += args["extra-args"]
    # FIXME make it configurable
    return get_vauban_job(ulid, args.get("vauban-image", "zarakailloux/vauban:latest"), vauban_cli)

@app.route("/readiness")
def readiness():
    return "ok"
