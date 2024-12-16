#!/usr/bin/env python3

from slack_sdk import WebClient
import os
from sentry_sdk import capture_exception
from slack_sdk.errors import SlackApiError
from jinja2 import Environment, BaseLoader
from datetime import datetime
import json
from flask import request
import yaml

blocks_tpl = """
- type: header
  text:
    type: plain_text
    text: Vauban job info display
- type: section
  text:
    type: mrkdwn
    text: "{{ job_tracking_msg }}"
- type: section
  fields:
{% for info in job_infos %}
  - type: mrkdwn
    text: "*{{ info.key }}*\\n{{ info.value }}"
{% endfor %}
- type: divider
- type: section
  text:
    type: mrkdwn
    text: "{{ job_tracking_progress }}"
{% if job_logs_raw %}
- type: section
  text:
    type: mrkdwn
    text: |
        {{ job_logs_raw }}
{% endif %}
{% if job_logs %}
- type: section
  text:
    type: mrkdwn
    text: |
        ```
        {%- for log_line in job_logs %}
        > {{ log_line }}
        {%- endfor %}
        ```
{% endif %}
- type: divider
- type: context
  elements:
{% for context in job_context %}
  - type: mrkdwn
    text: "*{{ context.key }}*: {{ context.value }}"
{% endfor %}
"""


class SlackNotif:
    def _get_channel_id(self):
        if (channel_id := os.environ.get("SLACK_CHANNEL_ID", "")) != "":
            print("Got channel id from env")
            return channel_id
        for result in self.client.conversations_list():
            for channel in result["channels"]:
                if channel["name"] == self.channel:
                    print(
                        f"Slack channel ID found : {channel['id']}. You may want to add it to the env var SLACK_CHANNEL_ID"
                    )
                    return channel["id"]
        raise ValueError(f"Channel {self.channel} not found")

    def __init__(self, *args, **kwargs):
        self.client = WebClient(token=os.environ.get("SLACK_TOKEN"))
        self.channel = os.environ.get("SLACK_CHANNEL", "vauban")
        self.username = os.environ.get("SLACK_USERNAME", "Vauban build manager")
        self.icon_emoji = os.environ.get("SLACK_ICON_EMOJI", ":robot_head:")
        self.channel_id = self._get_channel_id()

    def _get_blocks(
        self,
        event_type,
        ulid,
        infos,
        logs,
        context,
        previous_event_type=None,
        logs_raw=None,
    ):
        def get_tracking_msg(event_type, ulid):
            match event_type:
                case "creation":
                    return f"A vauban job has been submitted !\\n*ULID*: `{ulid}`"
                case "update-in-progress":
                    return f"A vauban job is running !\\n*ULID*: `{ulid}`"
                case "update-error":
                    return f"The vauban job failed !\\n*ULID*: `{ulid}`"
                case "update-done":
                    return f"The vauban job was successfully built !\\n*ULID*: `{ulid}`"
                case "update-broken":
                    return f"The vauban job went to an unknown state !\\nSome further investigation is required, and modification to VaubanHTTPServer are needed to handle this new case\\”*ULID*: `{ulid}`"
                case "update-garbage-collected":
                    return f"The vauban job was garbage collected :recycle:"
                case _:
                    raise NotImplementedError("Should not be reached")

        def get_tracking_progress(event_type):
            progresses = {
                "creation": ":large_yellow_circle: Waiting for the Kubernetes resources to be created ... :pepehmmm:",
                "update-in-progress": ":large_blue_circle: Job is running ... :elpepehacker:",
                "update-error": ":large_red_circle: Job failed :pepebad:",
                "update-done": ":large_green_circle: Job built ! :pepeok::pepeelnosabe:",
                "update-broken": ":large_purple_cirle: Job in unknown state :pepe_rage:",
            }
            return progresses[event_type]

        rtemplate = Environment(loader=BaseLoader).from_string(blocks_tpl)
        context |= {"last update": datetime.now().replace(microsecond=0).isoformat(" ")}
        context |= {
            "last update user": request.headers.get("X-authentik-username", "undefined")
        }
        if logs_raw is not None:
            logs_raw = logs_raw.replace("\n", "\n" + (" " * 8))
        values = {
            "job_tracking_msg": get_tracking_msg(event_type, ulid),
            "job_infos": [{"key": k, "value": v} for k, v in infos.items()],
            "job_tracking_progress": (
                get_tracking_progress(event_type)
                if event_type != "update-garbage-collected"
                else get_tracking_progress(previous_event_type)
            ),
            "job_logs": logs[-5:] if logs is not None else logs,
            "job_context": [{"key": k, "value": v} for k, v in context.items()],
            "job_logs_raw": logs_raw if logs_raw is None else logs_raw,
        }
        assert values["job_infos"] is not None
        assert values["job_infos"] != {}
        data = rtemplate.render(**values)
        return yaml.safe_load(data)

    def create_notification(self, ulid, infos, context):
        user_creation = request.headers.get("X-authentik-username", "undefined")
        infos |= {"user": user_creation}
        context |= {
            "creation date": datetime.now().replace(microsecond=0).isoformat(" "),
            "client": request.headers.get("User-Agent", "undefined"),
        }
        try:
            self.client.chat_postMessage(
                text=f"New Vauban job created: {ulid}",
                channel=self.channel_id,
                metadata={
                    "event_type": "vauban_job",
                    "event_payload": {
                        "vauban_ulid": ulid,
                        "vauban_infos": json.dumps(infos),
                        "vauban_context": json.dumps(context),
                        "vauban_event_type": "creation",
                    },
                },
                username=self.username,
                icon_emoji=self.icon_emoji,
                blocks=self._get_blocks("creation", ulid, infos, None, context),
            )
        except SlackApiError as e:
            print(blocks)
            print(e)
            capture_exception(e)

    def _get_previous_message(self, ulid):
        try:
            messages = self.client.conversations_history(
                channel=self.channel_id,
                include_all_metadata=True,
                limit=os.environ.get("SLACK_MAX_HISTORY_FETCH", 150),
            )["messages"]
            for message in messages:
                if (
                    (metadata := message.get("metadata", None)) is not None
                    and metadata.get("event_type", None) == "vauban_job"
                    and metadata["event_payload"].get("vauban_ulid", None) == ulid
                ):
                    original_message = message
                    slack_msg_infos = json.loads(
                        metadata["event_payload"].get("vauban_infos", "{}")
                    )
                    slack_msg_context = json.loads(
                        metadata["event_payload"].get("vauban_context", "{}")
                    )
                    slack_msg_event_type = metadata["event_payload"].get(
                        "vauban_event_type", "undefined"
                    )
                    return (
                        original_message,
                        slack_msg_infos,
                        slack_msg_context,
                        slack_msg_event_type,
                    )
        except SlackApiError as e:
            print(e)
            capture_exception(e)
        return None, None, None, None

    def _update_notification(self, event_type, ulid, infos, context, logs):
        message, slack_msg_infos, slack_msg_context, slack_msg_event_type = (
            self._get_previous_message(ulid)
        )
        if message is None:
            capture_exception(
                ValueError(
                    f"Asking to update an event {ulid} but this event was not found"
                )
            )
            return
        message_ts = message["ts"]

        slack_msg_infos |= infos
        slack_msg_context |= context

        print(message)
        print(message["blocks"][5])
        logs_raw = None
        if event_type == "update-garbage-collected":
            fifth_block = message["blocks"][5]
            if fifth_block["type"] != "divider":
                logs_raw = fifth_block["text"]["text"]

        try:
            blocks = self._get_blocks(
                event_type,
                ulid,
                slack_msg_infos,
                logs,
                slack_msg_context,
                slack_msg_event_type,
                logs_raw,
            )
            self.client.chat_update(
                text=f"New Vauban job created: {ulid}",
                channel=self.channel_id,
                username=self.username,
                icon_emoji=self.icon_emoji,
                blocks=blocks,
                ts=message_ts,
                metadata={
                    "event_type": "vauban_job",
                    "event_payload": {
                        "vauban_ulid": ulid,
                        "vauban_infos": json.dumps(slack_msg_infos),
                        "vauban_context": json.dumps(slack_msg_context),
                        "vauban_event_type": (
                            event_type
                            if event_type != "update-garbage-collected"
                            else slack_msg_event_type
                        ),
                    },
                },
            )
        except SlackApiError as e:
            print(blocks)
            print(e)
            capture_exception(e)

    def update_in_progress(self, ulid, infos, context, logs):
        return self._update_notification(
            "update-in-progress", ulid, infos, context, logs
        )

    def update_error(self, ulid, infos, context, logs):
        return self._update_notification("update-error", ulid, infos, context, logs)

    def update_done(self, ulid, infos, context, logs):
        return self._update_notification("update-done", ulid, infos, context, logs)

    def update_broken(self, ulid, infos, context, logs):
        return self._update_notification("update-broken", ulid, infos, context, logs)

    def update_garbage_collected(self, ulid, infos, context, logs):
        return self._update_notification(
            "update-garbage-collected", ulid, infos, context, logs
        )
