#!/usr/bin/env python3

# pylint: disable=invalid-name

"""
Manage vauban with simple arguments
"""

from __future__ import annotations  # Requires python >= 3.7
import sys
import uuid
import os
import subprocess
import traceback
import hashlib
import json
from copy import deepcopy
from dataclasses import dataclass

import signal

try:
    import sentry_sdk

except (ImportError, ModuleNotFoundError) as e:
    if not os.environ.get("_VAUBAN_COMPLETE"):
        print(e)
        print("sentry_sdk not found in your environment. Please install sentry_sdk")


# Import external module and print an nice error message if module is not found
for module, module_name in [
    ("yaml", "pyyaml"),
    ("click", "click"),
    ("requests", "requests"),
    ("sentry_sdk", "sentry-sdk"),
]:
    try:
        globals()[module] = __import__(module)
    except ModuleNotFoundError:
        print(f"Unable to import module: {module_name}")
        print("Try to install it:")
        print("- With pip (and optionnal venv)")
        print("	[Setup your venv] python -m venv venv && source venv/bin/activate")
        print(f"	pip install --user {module_name}")
        print("- With your package manager:")
        print(f"	apt install -y python3-{module_name}")
        print(f"	pacman -S python-{module}")
        print(f"	apk add --no-cache py3-{module}")
        exit(1)
SENTRY_DSN = os.environ.get("SENTRY_DSN", None)
if SENTRY_DSN:
    sentry_sdk.init(
        dsn=SENTRY_DSN,
        # Set traces_sample_rate to 1.0 to capture 100%
        # of transactions for performance monitoring.
        traces_sample_rate=1.0,
    )


class NothingToDoException(Exception):
    """
    Dummy exception class
    """


@dataclass
class BuildConfig:
    """
    Store build configuration, the cli arguments, as an object
    """

    name: str
    stage: str
    branch: str
    debug: bool
    check: bool
    config_path: str
    build_parents: int
    conffs: str

    def copy(self):
        return deepcopy(self)

    def u_stage(self, stage, sub_build_parents=True):
        copy = self.copy()
        copy.stage = stage
        copy.build_parents -= 1
        return copy


class MasterNameType(click.ParamType):
    name = "mastername"

    def shell_complete(self, ctx, param, incomplete):
        try:
            config = VaubanConfiguration()
        except FileNotFoundError:
            return []
        return [
            click.shell_completion.CompletionItem(name)
            for name in config.list_masters()
            if name.startswith(incomplete)
        ]


class VaubanConfiguration:
    """
    Represent a vauban configuration from its config file
    """

    def __init__(self, path="config.yml", output=None):
        """
        Init the object
        """
        self.path = path
        self.output = output
        super().__init__()
        self.masters = []
        self._parse()

    def _parse(self):
        """
        Open and parse the configuration file to create VaubanMasters
        """
        with open(self.path, encoding="utf-8") as f:
            config_yml = yaml.safe_load(f.read())
        self.config = config_yml.get("configuration", {})
        self._check_config()

        for k, v in config_yml.items():
            if k == "configuration":
                continue
            self.masters.append(VaubanMaster(k, v, self))

    def _check_config(self):
        for k, default in [
            ("ignore_stage_in_conffs", []),
            ("never_upload", []),
        ]:
            if k not in self.config:
                self.config[k] = default

    def get_master(self, name) -> VaubanMaster:
        """
        Return a VaubanMaster instance from a name
        """
        for master in self.masters:
            m = master.get_master(name)
            if m is not None:
                return m
        return None

    def list_masters(self) -> [str]:
        """
        Return a list of master names
        """
        r = []
        for master in self.masters:
            r += master.list_masters()
        return r


class OutputHandler:
    def __init__(self):
        self.logs = ""

    def process(self, path):
        with open(path + "-stdout", "r") as f:
            lines = f.readlines()
        for line in lines:
            if "recap file: " in line:
                self.logs += open(line.split("recap file: ")[1].strip()).read()
                break
        os.remove(path + "-stdout")
        os.remove(path + "-stderr")


class VaubanMaster:
    """
    Represent a vauban master, with its configuration, a link to its parent, and to its children
    """

    def __init__(
        self,
        name: str,
        value: dict,
        configuration: VaubanConfiguration,
        parent: VaubanMaster = None,
    ):
        assert name is not None
        assert name != ""
        assert isinstance(value, dict)
        super().__init__()
        self.children: [VaubanMaster] = []
        self.parent: VaubanMaster = parent
        self.stages = value.get("stages", [])
        self.conffs = value.get("conffs", None)
        self.branch = value.get("branch", None)
        self.is_release = parent is None
        self.release: str = name if self.is_release else parent.release
        self.name = value.get("name", name)
        self.configuration: VaubanConfiguration = configuration
        self.output = configuration.output
        for k, v in value.items():
            if isinstance(v, dict):
                self.children.append(VaubanMaster(k, v, self.configuration, self))

    def __repr__(self):
        return f"VaubanMaster(name={self.name}, branch={self.branch}, conffs={self.conffs}, parent={None if self.parent is None else self.parent.name}, children={[x.name for x in self.children]}, is_release={self.is_release}, release={self.release})"

    def __str__(self):
        return self.name

    def get_master(self, name) -> VaubanMaster:
        """
        Get a master by a name. Could be us, or one of our children
        """
        if self.name == name:
            return self
        for c in self.children:
            m = c.get_master(name)
            if m is not None:
                return m
        return None

    def list_masters(self) -> [str]:
        """
        List ourself and all our children and return the list
        """
        r = [str(self)]
        for c in self.children:
            r += c.list_masters()
        return r

    def _print_build_stage_header(self, stage):
        outer_len = int((53 - len(max(STAGES))) / 2 - 1)
        center_len = len(max(STAGES))
        print()
        print("=" * 53)
        print(f"{'.' * outer_len} {stage:^{center_len}} {'.' * outer_len}")
        print("=" * 53)
        print()

    def _build_stage(self, cc):
        """
        Internal build function. Actually performs the build if not in debug
        mode
        """

        assert cc.stage in ["rootfs", "initramfs", "conffs", "kernel"]

        if cc.branch is None or cc.branch == "ansible-branch-name-here":
            branch = self.branch or "master"
        else:
            branch = cc.branch

        vauban_cli = [
            "./vauban.sh",
            "--build-engine",
            "kubernetes",
            "--debian-release",
            self.release,
            "--name",
            self.name,
            "--upload",
            (
                "no"
                if self.is_release
                or self.name in self.configuration.config["never_upload"]
                else "yes"
            ),
            "--branch",
            branch,
        ]

        if cc.conffs is not None:
            # Override conffs from config.yml
            self.conffs = cc.conffs

        # Auto expand vauban CLI based on the current stage
        vauban_cli = STAGES[cc.stage](self.configuration.config, vauban_cli, self)

        if cc.debug:
            print(" ".join(['"' + x + '"' for x in vauban_cli]))
        if cc.check:
            return
        my_env = os.environ.copy()
        if cc.debug:
            my_env["VAUBAN_SET_FLAGS"] = my_env.get("VAUBAN_SET_FLAGS", "") + "x"

        tmp_path = f"/tmp/vauban-logs-{str(uuid.uuid4())}"
        exec_cmd = ""
        for el in vauban_cli:
            exec_cmd += "'" + el + "' "
        exec_cmd += f" > >(tee {tmp_path}-stdout) 2> >(tee {tmp_path}-stderr >&2)"
        print(exec_cmd)
        process = subprocess.run(
            exec_cmd, check=True, env=my_env, start_new_session=True, shell=True
        )
        self.output.process(tmp_path)
        assert process.returncode == 0

    def build(self, cc):
        """
        Build this master with the given parameters. "Recursive" function,
        it handles the cases where stage=[all, trueall] and build_parents
        option
        """
        if cc.build_parents != 0:
            if cc.stage in ["rootfs", "all", "trueall"]:
                if self.parent is not None:
                    self.parent.build(cc.u_stage("rootfs"))
            else:
                self.build(cc.u_stage("rootfs"))
        if cc.stage in ["all", "trueall"]:
            self._build_stage(cc.u_stage("rootfs"))
            try:
                self._build_stage(cc.u_stage("conffs"))
            except NothingToDoException:
                pass
            self._build_stage(cc.u_stage("initramfs"))
            if cc.stage == "trueall":
                self._build_stage(cc.u_stage("kernel"))
        else:
            self._build_stage(cc)


def rootfs(config, vauban_cli, master, only=True):  # pylint: disable=unused-argument
    """
    Set options for the rootfs build stage
    """
    vauban_cli += [
        "--rootfs",
        "yes",
    ]
    if only:
        vauban_cli += [
            "--conffs",
            "no",
            "--initramfs",
            "no",
            "--kernel",
            "no",
        ]
    if not master.is_release:
        vauban_cli += ["--source-image", str(master.parent)] + master.stages
    return vauban_cli


def conffs(config, vauban_cli, master, only=True):
    """
    Set options for the conffs build stage
    """
    if master.conffs is None:
        print(f"No conffs key in {str(master)}. Nothing to be done !")
        raise NothingToDoException("Nothing to do !")
    stages = []
    tmp_master = master
    while tmp_master is not None:
        stages = tmp_master.stages + stages
        tmp_master = tmp_master.parent
    for stage in config["ignore_stage_in_conffs"]:
        try:
            stages.remove(stage)
        except ValueError:
            pass

    stages = config["always_apply_stage_in_conffs"] + stages

    vauban_cli += [
        "--conffs",
        "yes",
        "--ansible-host",
        master.conffs,
        "--source-image",
        master.name,
    ] + stages
    if only:
        vauban_cli += [
            "--rootfs",
            "no",
            "--initramfs",
            "no",
            "--kernel",
            "no",
        ]
    return vauban_cli


def initramfs(config, vauban_cli, master, only=True):  # pylint: disable=unused-argument
    """
    Set options for the initramfs build stage
    """
    vauban_cli += ["--initramfs", "yes"]
    if only:
        vauban_cli += ["--rootfs", "no"]
        vauban_cli += ["--conffs", "no"]
        vauban_cli += ["--kernel", "no"]
    return vauban_cli


def kernel(config, vauban_cli, master, only=True):  # pylint: disable=unused-argument
    """
    Set options for the kernel build stage
    """
    vauban_cli += ["--kernel", "yes"]
    if only:
        vauban_cli += ["--rootfs", "no"]
        vauban_cli += ["--conffs", "no"]
        vauban_cli += ["--initramfs", "no"]
    return vauban_cli


STAGES = {
    "rootfs": rootfs,
    "conffs": conffs,
    "initramfs": initramfs,
    "kernel": kernel,
    "all": False,
    "trueall": False,
}


signal.signal(signal.SIGUSR1, lambda a, b: None)


@click.command()
@click.option(
    "--name",
    default="master-11-netdata",
    show_default=True,
    type=MasterNameType(),
    help="Name of the master to build",
)
@click.option(
    "--stage",
    type=click.Choice(
        ["rootfs", "conffs", "initramfs", "kernel", "all", "trueall"],
        case_sensitive=True,
    ),
    default="all",
    show_default=True,
    help="What stages to build",
)
@click.option(
    "--branch",
    default=None,
    show_default=True,
    help="Specify a specific branch to override default configuration",
)
@click.option(
    "--debug",
    is_flag=True,
    default=False,
    show_default=True,
    help="Debug mode: more verbose, print vauban.sh commands",
)
@click.option(
    "--check",
    is_flag=True,
    default=False,
    show_default=True,
    help="Check mode, don't actually run vauban",
)
@click.option(
    "--config-path",
    type=click.Path(exists=True, dir_okay=False),
    default="config.yml",
    show_default=True,
    help="Vauban config file",
)
@click.option(
    "--build-parents",
    type=click.INT,
    default=0,
    show_default=True,
    help="How many parent objects to build",
)
@click.option(
    "--conffs",
    default=None,
    show_default=True,
    help="Override config's conffs for the master to build. Useful to build the conffs for one host or hosts only while keeping a proper config file",
)
def vauban(**kwargs):
    """
    Wrapper around vauban.sh for ease of use. Uses a config file to generate
    vauban.sh commands
    """
    cc = BuildConfig(**kwargs)
    if cc.check:
        cc.debug = True

    output = OutputHandler()
    config = VaubanConfiguration(cc.config_path, output)
    master = config.get_master(cc.name)

    if master is None:
        print(f"Cannot build {cc.name}: not found in {cc.config_path}")
        sys.exit(1)
    if cc.debug:
        print("Available masters:")
        print(json.dumps(config.list_masters(), indent=4))
        print("Selected master:")
        print(repr(master))

    try:
        master.build(cc)
    except NothingToDoException as e:
        if os.environ.get("CI", None) is None:
            traceback.print_exception(e)
            print(output.logs)
            sys.exit(1)
    except subprocess.CalledProcessError as e:
        print("Building failed !")
        print(output.logs)
        sys.exit(1)
    except Exception as e:
        exc_info = sys.exc_info()
        traceback.print_exception(*exc_info)
        print(output.logs)
        print()
        print("Building failed !")
        sys.exit(1)
    print(output.logs)

    if not cc.debug:
        if cc.stage in ["rootfs", "all", "trueall"]:
            print(f"Building successful ! {cc.name} was built")
        if cc.stage in ["conffs", "all", "trueall"]:
            print(f"Building successful ! conffs for {cc.name} was/were built.")
        if cc.stage in ["initramfs", "all", "trueall", "kernel"]:
            print("Building successful !")
    return 0


if __name__ == "__main__":
    vauban(auto_envvar_prefix="VAUBAN")
