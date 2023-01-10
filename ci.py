#!/usr/bin/env python3

import sys
import os
import subprocess
import yaml

class NothingToDoException(Exception):
    pass

def obj_remove_children(obj, keep_parent=True):
    p = {}
    for k, v in obj.items():
        if isinstance(v, dict) and (k != "parent" and keep_parent):
            continue
        p[k] = v
    return p

def find_obj(config, name, iso=None, parent=None):
    """
        Find the asked object definition in the config
    """
    sub_el = None
    for k, v in config.items():
        if isinstance(v, dict):
            tree_iso = iso if iso is not None else k
            obj = {**v, "iso": tree_iso, "is_iso": tree_iso == k, "parent": parent, "name": v.get('name', k)}
            if k == name or v.get('name', None) == name:
                return obj
            if sub_el is None:
                sub_el = find_obj(v, name, tree_iso, parent=obj_remove_children(obj))
    return sub_el

def get_config():
    """
        Load masters configuration
    """
    with open("config.yml") as f:
        return yaml.safe_load(f.read())

def print_obj(obj, print_parent=True):
    p = obj_remove_children(obj, print_parent)
    import json
    print(json.dumps(p, indent=4, sort_keys=True))

def rootfs(config, vauban_cli, obj, only=True):
    """
        Set options for the rootfs build stage
    """
    vauban_cli += [
        '--rootfs', 'yes',
    ]
    if only:
        vauban_cli += [
            '--conffs', 'no',
            '--initramfs', 'no',
            '--kernel', 'no',
        ]
    if not obj['is_iso']:
        vauban_cli += ['--source-image', obj['parent']['name']] + \
                        obj['stages']
    return vauban_cli

def conffs(config, vauban_cli, obj, only=True):
    """
        Set options for the conffs build stage
    """
    if obj.get('conffs', None) is None:
        print(f'No conffs key in {obj["name"]}. Nothing to be done !')
        raise NothingToDoException('Nothing to do !')
    stages = []
    tmp_obj = obj
    while tmp_obj is not None:
        stages = tmp_obj.get('stages', []) + stages
        tmp_obj = tmp_obj.get('parent', None)
    for stage in config.get('configuration', {}).get('ignore_stage_in_conffs', []):
        try:
            stages.remove(stage)
        except ValueError:
            pass

    vauban_cli += [
            '--conffs', 'yes',
            '--ansible-host', obj['conffs'],
            '--source-image', obj['name'],
        ] + stages
    if only:
        vauban_cli += [
            '--rootfs', 'no',
            '--initramfs', 'no',
            '--kernel', 'no',
        ]
    return vauban_cli

def initramfs(config, vauban_cli, obj, only=True):
    """
        Set options for the initramfs build stage
    """
    vauban_cli += [ '--initramfs', 'yes' ]
    if only:
        vauban_cli += [ '--rootfs', 'no' ]
        vauban_cli += [ '--conffs', 'no' ]
        vauban_cli += [ '--kernel', 'no' ]
    return vauban_cli

def kernel(config, vauban_cli, obj, only=True):
    """
        Set options for the kernel build stage
    """
    vauban_cli += [ '--kernel', 'yes' ]
    if only:
        vauban_cli += [ '--rootfs', 'no' ]
        vauban_cli += [ '--conffs', 'no' ]
        vauban_cli += [ '--initramfs', 'no' ]
    return vauban_cli

STAGES = {
        "rootfs": rootfs,
        "conffs": conffs,
        "initramfs": initramfs,
        "kernel": kernel,
        "all": False,
        "trueall": False,
    }

def build(config, obj, stage, branch, debug, target_name):
    if os.path.isfile(f"/srv/iso/{obj['iso']}"):
        iso_path = f"/srv/iso/{obj['iso']}"
    elif os.path.isfile(obj['iso']):
        iso_path = f"{obj['iso']}"
    else:
        raise Exception("ISO file not found")

    vauban_cli = ['./vauban.sh',
        '--iso', iso_path,
        '--name', obj['name'],
        '--upload', "no" if obj['is_iso'] or (obj.get('conffs', None) is None and obj.get('name', '') != target_name) else "yes",
        '--branch', branch]

    vauban_cli = STAGES[stage](config, vauban_cli, obj)  # Auto expand vauban CLI based on the current stage

    if debug:
        print(" ".join([ '"' + x + '"' for x in vauban_cli]))
        return
    process = subprocess.run(vauban_cli, check=True)
    assert process.returncode == 0

def recursive_build(config, obj, stage, branch, debug, target_name, parents_to_build):
    if branch is None or branch == "ansible-branch-name-here":
        branch = obj.get("branch", "master")

    if parents_to_build != 0:
        if stage in ["rootfs", "all", "trueall"]:
            if obj.get('parent', None) is not None:
                recursive_build(config, obj['parent'], stage, branch, debug, target_name, parents_to_build - 1)
        elif stage in ["conffs", "initramfs", "kernel"]:
            recursive_build(config, obj, 'rootfs', branch, debug, target_name, parents_to_build - 1)
    if stage in ["all", "trueall"]:
        build(config, obj, "rootfs", branch, debug, target_name)
        try:
            build(config, obj, "conffs", branch, debug, target_name)
        except NothingToDoException:
            pass
        build(config, obj, "initramfs", branch, debug, target_name)
        if stage == "trueall":
            build(config, obj, "kernel", branch, debug, target_name)
    else:
        build(config, obj, stage, branch, debug, target_name)

def main():
    name = os.environ.get("name", "debian-live-10.8.0-amd64-standard.iso")
    stage = os.environ.get("CI_JOB_STAGE", os.environ.get("stage", None))
    branch = os.environ.get("branch", None)
    debug = os.environ.get("debug", "no") in ["yes", "true"]
    build_parents = os.environ.get("build_parents", "no")

    if stage not in STAGES:
        print(f"Stage not handled {stage}.")
        print(f"Values supported: {','.join(STAGES.keys())}")
        return 1
    try:
        if build_parents == "yes":
            build_parents = -1
        else:
            build_parents = int(build_parents)
    except:
        build_parents = 0

    config = get_config()
    obj = find_obj(config, name)
    if obj is None:
        print(f'Cannot build {name}: not found in config.yml')
        return 1
    if debug:
        import json
        print(json.dumps(obj, indent=4, sort_keys=True))

    try:
        recursive_build(config, obj, stage, branch, debug, name, build_parents)
    except Exception as e:
        print('Building failed !')
        print(e)
        return 1

    if not debug:
        if stage in ["rootfs", "all", "trueall"]:
            print(f'Building successful ! {name} was built. Details:')
            subprocess.run(f'docker run --rm {name} cat /imginfo'.split(' '), check=False)
        if stage in ["conffs", "all", "trueall"]:
            print(f'Building successful ! conffs for {name} was/were built.')
        if stage in ["initramfs", "all", "trueall", "kernel"]:
            print(f'Building successful !')
    return 0

sys.exit(main())
