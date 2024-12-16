#!/usr/bin/env python3

from typing import Optional
import subprocess
import sys
import os
from dataclasses import dataclass
import hashlib
import yaml
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


@dataclass
class ScheduleOptions:
    stage: str = "all"
    build_parents: int = 0


@dataclass
class Master:
    name: str
    schedule: str
    schedule_options: Optional[ScheduleOptions]


def get_all_masters_with_schedule(config_yml=None):
    masters = []
    if config_yml is None:
        with open(sys.argv[1]) as f:
            config_yml = yaml.safe_load(f.read())

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
        masters += get_all_masters_with_schedule(v)

    return masters


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
        print(
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
    print(f"building master {master}")
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
        print(f"finished building master {master}")
    except subprocess.CalledProcessError as e:
        sentry_sdk.capture_exception(e)
        print(f"failed to build master {master}")


def watch_change():
    global config_hash
    with open(sys.argv[1], "rb") as f:
        new_hash = hashlib.blake2s(f.read()).hexdigest()
    print(f"Configuration hash {new_hash}")
    if config_hash is None:
        config_hash = new_hash
    if config_hash != new_hash:
        print("Configuration changed, changing the jobs")
        build_list = get_all_masters_with_schedule()
        for job in scheduler.get_jobs():
            job.remove()
        schedule_all(scheduler, build_list)
        config_hash = new_hash


def main():
    build_list = get_all_masters_with_schedule()
    schedule_all(scheduler, build_list)
    try:
        scheduler.start()
    except KeyboardInterrupt:
        pass


main()
