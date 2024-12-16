#!/usr/bin/env python3

from typing import Optional
import subprocess
import os
import base64
from dataclasses import dataclass
import hashlib
import yaml
import requests
import logging
from apscheduler.schedulers.blocking import BlockingScheduler
from apscheduler.executors.pool import ThreadPoolExecutor
from apscheduler.triggers.cron import CronTrigger
import sentry_sdk

SENTRY_DSN = os.environ.get("SENTRY_DSN", None)
if os.environ.get("DEV", "0") != "1" and SENTRY_DSN:
    sentry_sdk.init(
        dsn=SENTRY_DSN
    )

config_hash = None
job_defaults = {"coalesce": True, "max_instances": 1, "misfire_grace_time": None}
executors = {"default": ThreadPoolExecutor(20)}
scheduler = BlockingScheduler(job_defaults=job_defaults, executors=executors)
logging.basicConfig(
    level=logging.INFO, format="[%(asctime)s][%(levelname)-8s] %(message)s"
)
logger = logging.getLogger()


@dataclass
class ScheduleOptions:
    stage: str = "all"
    build_parents: int = 0


@dataclass
class Master:
    name: str
    schedule: str
    schedule_options: Optional[ScheduleOptions]


def get_all_masters_with_schedule(raw_txt=None, config_yml=None):
    masters = []
    if config_yml is None:
        assert raw_txt is not None
        config_yml = yaml.safe_load(raw_txt)

    for master_name, v in config_yml.items():
        if not isinstance(v, dict):
            continue
        if master_name in ["configuration", "name", "conffs"]:
            continue

        if "name" in v:
            master_name = v["name"]
        if "schedule" in v:
            schedule_options = ScheduleOptions(**v.get("schedule_options", {}))
            masters.append(Master(master_name, v["schedule"], schedule_options))
        masters += get_all_masters_with_schedule(config_yml=v)

    return masters


def watch_change(first_call=False):
    global config_hash
    gitlab_endpoint = os.environ["GITLAB_ENDPOINT"]
    gitlab_project_id = os.environ["GITLAB_PROJECT_ID"]
    gitlab_token = os.environ["GITLAB_TOKEN"]
    try:
        answer = requests.get(
            f"{gitlab_endpoint}/api/v4/projects/{gitlab_project_id}/repository/files/config.yml?ref=master",
            headers={"PRIVATE-TOKEN": gitlab_token},
        ).json()
        new_hash = answer["content_sha256"]
        content = base64.b64decode(answer["content"]).decode()
    except Exception as e:
        if first_call:
            raise
        logger.error(f"Error while trying to get updates: {e}", extra=dict(exception=e))
        return
    logger.info(f"Configuration hash {new_hash}")
    if config_hash is None:
        config_hash = new_hash
    if config_hash != new_hash or first_call:
        logger.info("Configuration changed, changing the jobs")
        build_list = get_all_masters_with_schedule(raw_txt=content)
        for job in scheduler.get_jobs():
            job.remove()
        schedule_all(scheduler, build_list)
        config_hash = new_hash


def parse_cron(cron_str):
    minute, hour, day, month, day_of_week = cron_str.split()
    try:
        day_of_week = str(int(day_of_week) % 7)
    except ValueError:
        pass
    return {
        "minute": minute,
        "hour": hour,
        "day": day,
        "month": month,
        "day_of_week": day_of_week,
    }


def schedule_builds(scheduler, build_list):
    max_master_len, max_cron_len = 0, 0
    for build_info in build_list:
        max_master_len = max(max_master_len, len(build_info.name))
        max_cron_len = max(max_cron_len, len(build_info.schedule))
    for build_info in build_list:
        cron_expression = parse_cron(build_info.schedule)
        logger.info(
            f"Add cron job to build {build_info.name : >{max_master_len}} on {build_info.schedule : >{max_cron_len}} (args: {build_info.schedule_options})"
        )
        scheduler.add_job(
            build,
            CronTrigger(**cron_expression),
            args=[build_info.name, build_info.schedule_options],
        )


def schedule_all(scheduler, build_list):
    scheduler.add_job(watch_change, CronTrigger(**parse_cron("* * * * *")))
    schedule_builds(scheduler, build_list)


def build(master, schedule_options):
    logger.info(f"building master {master}")
    env = os.environ | {
        "VAUBAN_CLIENT_USER_AGENT": "vauban scheduler via vauban-client"
    }
    try:
        subprocess.run(
            [
                "/usr/local/bin/vauban-client",
                "--name",
                master,
                "--stage",
                schedule_options.stage,
                "--build-parents",
                str(schedule_options.build_parents),
            ],
            env=env,
            check=True,
        )
        logger.info(f"finished building master {master}")
    except subprocess.CalledProcessError as e:
        sentry_sdk.capture_exception(e)
        logger.warning(f"failed to build master {master}")


def main():
    watch_change(first_call=True)
    try:
        scheduler.start()
    except KeyboardInterrupt:
        pass


main()
