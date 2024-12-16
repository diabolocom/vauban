from flask import Flask
import os
import sentry_sdk
from sentry_sdk.integrations.flask import FlaskIntegration
from kubernetes import client, config, utils
from kubernetes.client.rest import ApiException
from kubernetes.stream import stream
import logging


SENTRY_DSN = os.environ.get("SENTRY_DSN", None)
if SENTRY_DSN and os.environ.get("SENTRY_DISABLE", "0") != "1":
    sentry_sdk.init(
        dsn=SENTRY_DSN,
        integrations=[
            FlaskIntegration(
                transaction_style="url",
            ),
        ],
        include_local_variables=True,
        enable_tracing=False,
    )
else:
    print("Sentry integration disabled")
logging.basicConfig(format="[%(asctime)s][%(levelname)-8s] %(name)s: %(message)s")
app = Flask(__name__)
app.logger.setLevel(logging.getLevelName(os.environ.get("LOG_LEVEL", "INFO").upper()))

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

from .main import *
