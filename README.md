# What is Vauban ? 🏗️

Vauban is an open-source image builder with Ansible and Docker integration,
focused on IaC. It allows you to build in a hierarchical approach master images
and their associated hosts-specific configuration to help you manage hundreds of
hosts in a similar fashion.

Vauban creates all the resources needed to boot via PXE or from local disk in a
way where, by default, everything is in live-mode. This means that a reboot
will erase all unwanted changes, helping you separate stateful data from
configuration and applications.

Starting from version 2.0, Vauban runs exclusively in Kubernetes, exposing an API to start build jobs.
It also comes with a scheduler, to auto-build images with a cronjob-style syntax.

# Why is Vauban needed ? 🚚

Vauban and the PXE/local live-image booting system is useful for many reasons:
- Have better control of the OS, applications and configuration deployed on your
  infra, even if there are thousands of hosts
- Group easily hosts in a category where they will all depend on a "master" that
  will hold all applications
- The possibility to easily create host-specific lighweight configuration that
  will be applied on top of the master at boot-time
- Saving disk space with this unique-for-many-hosts master approach
- Save yourself when a host is severly messed up by simply rebooting to a
  working version, erasing all undesired changes
- Better observe what changes were made
- Avoid Ansible's well know flaw where resources not explicitly removed are
  kept, like users or packages
- Keeping your different hosts aligned to the same OS/package version to ease
  out differences between similar servers and limit incompatibilities,
  discrepancies or the famous "but it worked there !"
- Have a better observability of differences between hosts
- Have a better observability on what has been deployed and how a running host
  has come to this state
- Clearly establish what is stateful (and must be kept and backed-up) and what
  is not
- Have an IaC approach and all its benefits
- Have the possibility to see what differences were made on a running host
  from what it booted on initially
- Use Ansible to manage the server configuration instead of custom bash scripts

However, Vauban introduces some drawbacks that must be kept in mind:
- Image build stage a bit harder that simply rolling out changes to already
  running hosts
- Being aware of this system and enforce a rebuild policy when changes are to be
  made and kept

# How to use 🔍

## Dependencies

In order to work, you need to setup:
- A docker registry for vauban to store its images. The images might contain
  secrets or configuration that must be kept private, so keep this in mind when
  choosing a registry.
- A distant server to upload created images. Vauban expects an HTTP API to upload some images and make a symlink between
  some resources. More information in vauban-backend.sh's upload function
- An ansible repository
- A working kubernetes cluster. Vauban provides an example Helm Chart to deploy it

- Optionally: vauban-client to interact easily with Vauban's http-server
- Optionally: A hashicorp vault to store server's SSH keys
- Optionally: A sentry instance to collect errors
- Optionally: A Slack channel and application to provide build information directly in Slack

## Setup

## Install vauban in Kubernetes

Follow the Helm chart instructions to install the server-side Vauban HTTP-api, and configure it.

### Install vauban-client

The recommended entrypoint to use with vauban is `vauban-client`. It has a few
dependencies, and they will be listed when running it if they are not installed.

### Configure jobs in config.yml

`config.yml` is the main file for Vauban build definition. Please modify it and provide it to your instance of vauban
running in Kubernetes.

## Day-to-day usage

A day-to-day usage is divided in multiple operations described down below

### config.yml

Vauban can be used directly via `vauban.sh` to start building, but its CLI
interface is a bit complex, a one does not want to remember inheritance between
masters, specific configuration, etc ...

Therefore, the `config.yml` file will describe the masters how would like to
build, and the given recipe.

The syntax is defined in the file itself, and you should see the hierachical approach
used to create masters (or dependencies if you'd like).

Every top-level objects represents a master created from an ISO/RAW file.

Each child of a master will depend on the previous one, like `FROM` statement
in a Dockerfile for example.

Each master will also have a configuration for each of its hosts derived from
the master, called `conffs`. The conffs inherit from its master, but there is
no inheritance from another conffs.

The select the list of conffs to create, you can use the `conffs` key for a
master to list the hosts to select in the Ansible inventory, like ansible's
`--limit` argument does.

You can also choose the list of playbook(s) to use to build a master (`stages`),
and optionnally provide an ansible branch to use (`branch`)

`config.yml` file is not read by `vauban.sh`, but by the higher level interface
`vauban.py`. It is recommended anyway to not use `vauban.sh` directly

### vauban-client

To start building things, first checkout `vauban-client --help`.

The main argument is `--name`, to choose one of the masters to build from the
config file.

All options shall be self-explanatory with the `--help`, but `--build-parents`
can use some more details.

#### --build-parents

This option allow to rebuild the parent of an object automatically.

If you're building a conffs or an initramfs, its parent is its master's rootfs.
If you're building a rootfs, its parent is its master's parent's rootfs.
If you're building with `--stage all`, you're building a whole master, and its
parent is the parent from `config.yml`

This concept is useful when you want to rebuild multiple elements from a chain.

# Theory 🧑‍🏫

The project is explained if further details on [zarak.fr](https://zarak.fr/linux/sre/vauban-en/),
especially how it works and the rationals behind the project.

However, it is interesting to understand at least those concepts to use vauban:
- rootfs
- conffs
- initramfs
- Hierarchical approach
- What and when to build

## Rootfs

The rootfs is the main component of a host. It's the full OS, its basic
configuration, its packages, etc.

It is expected that the rootfs will take few hundreds of MiB when compressed, and
few GiB as a docker image.

To build a master, you start with the rootfs from its parent (in `config.yml`),
and you run ansible playbook(s) on it to add new things.

## Conffs

Hosts need specific configuration. For example, for a master "postgreSQL" that
contains your basic debian OS with its configuration and postgreSQL installed,
you still want to have postgresql-specific configuration for each host (password,
access rules, etc).

This host-specific configuration should be small. Everything that is common from
a host to another shall be put in the rootfs. In the conffs, you only have the
specifics for a host, the 2-3 config files essentially.

The conffs shall be sized between few KiB to few MiB when exported.

The docker image of a conffs will be few GiB, but note that most of the docker
layers of the conffs will be shared with its rootfs.

## Initramfs

The initramfs is just the small brick that allows the PXE boot process. You
usually don't really care about it, and it's common for all hosts, but it
still needs to be there. It's also tightly coupled to a kernel version, so
everytime a new kernel is released, the initramfs must be rebuilt.

If no kernel is released for a week of vauban build (as an example), it's
useless to rebuild it everytime, and building it once for the whole week will
be enough.

As a side note, the initramfs stage also provide a kernel, the common kernel
shipped with the OS.

## Hierarchical approach

Every master depends from another master. This is the same concept as docker's
link between images. This concept is quite useful to bear in mind when designing
config.yml and the masters, to avoid wasting space.

This also means that for a change to be applied, all downstream images needs
to be (re)generated.

## What and when to build

Let's study a few scenarios:

### I want to create a new master

1. Add the master and its configuration in `config.yml`
2. You will need to build everything the first time. Simple run with `--stage all`
   (which is the default option)
3. Pay attention to which stages succeeded. If only `initramfs` failed for example,
   you can retry only this one with `--stage initramfs`

### I made a small modification in ansible and want to rebuild

3 possibilities here:
1. Is the modification for all hosts of a master, like adding a package, or changing common configuration ?
2. Is the modification for a specific host(s) only ?
3. Is the modification both 1. and 2. ?

If option n°1:
1. You will likely need to rebuild only the rootfs. If you believe the conffs
   won't change based on the change (because your change doesn't interact with
   the conffs host-specific configuration in any way), it's not necessary to
   rebuild them. Run `vauban.py` with `--stage rootfs`
2. Also note that maybe the kernel was updated in between. In such case, also
   build the initramfs with `--stage initramfs`

If option n°2:
1. Only a conffs, or some conffs needs to be rebuilt. You can used `--stage conffs`,
   and if it's only for a single host (or a subset of the hosts defined in `config.yml`),
   you may want to not waste time by building unaffected hosts. You can select
   your hosts more precisely with `--conffs` option.
2. Also note that maybe the kernel was updated in between. In such case, also
   build the initramfs with `--stage initramfs`

If option n°3:
1. In such case, you will need to rebuild both the rootfs and conffs.
   You can use `vauban.py --stage conffs --build-parents 1` to do so. This will
   try to build the conffs, and 1 parent of the conffs. The parent of a conffs
   is its rootfs, effectively doing what you're interested in.
2. Also note that maybe the kernel was updated in between. In such case, also
   build the initramfs with `--stage initramfs`, or do the 3-in-1 with `--stage all`

### My conffs/rootfs build failed

You will need to identify the reason for this. Is it vauban ? A fluke ? An
ansible mistake ?

Vauban logs shall help you. If you suspect it's a vauban problem, you can retry
with `--debug` for extra verbosity.

If it's an ansible problem, as shown on the logs, fix the ansible mistake, push
to remote git and re-start the build. Make sure that the vauban build you're
running is targetting the appropriate ansible's branch. Vauban will git pull
the change before every run.

### I want to update a master

To update a master, you also want its parent(s) to be up-to-date (most likely).
To rebuild a master, you can use `--stage all` to build all 3 components (if
the initramfs wasn't rebuilt in a long time. If you built an initramfs recently,
you can use the second option), or you can use `--stage conffs` with
`--build-parents` option. You can increase the `--build-parents` option until
you reach the number of parent objects you want to update.

To rebuild the whole chain, you can set `--build-parents` to `-1`

# Limitations 🤕

## Ansible interaction

When running ansible, vauban sets a variable `in_vauban` to true, to help you
make decisions in ansible workflow.

Please note a few things about ansible:
- systemd is _not_ running when building images, therefore some systemd commands
  won't work. For example, `systemctl start` (used with the `systemd` ansible's
  module) won't work. It is expected here to write some conditions with `when` to
  avoid running those commands when it's a docker build.
  `when: not in_vauban` for example.
  However, systemd enable=true works and shall be used to enable a systemd service

- The kernel running is not the one that will be used in the end (it's your build
  machine's one). Any operations that needs to interact directly with the kernel
  won't work (sysctl, some build). You will have to find ways to overcome this.

## docker interactions

- As a container engine is used to build the image, `/etc/hosts`, `/etc/hostname` and
  `/etc/resolv.conf` are automatically mounted in the container, and it cannot be
  prevented. To overcome this, vauban automatically transfer the content of `/toslash`
  in `/`. One can therefore write into /toslash/etc/hostname for example for it to
  be taken into account once exported.

## DHCP options

boot options for PXE booting could be looking like this:
```
console=tty0 console=ttyS0,115200 net.ifnames=0 verbose rd.writable.fsimg=1 rd.luks=0 rd.lvm=0 rd.md=0 rd.dm=0 rd.neednet=1 rd.live.debug=1 rd.live.image rootflags=rw rootovl ip=eth0:dhcp:01:23:45:67:89:ab pxemac=01:23:45:67:89:ab boot=tmpfs live.updates=http://path/to/conffs root=live:http://path/to/rootfs
```

To help debugging the boot process, one can use:

```
rd.shell systemd.log_target=ksm systemd.log_level=debug debug systemd.show_status=true systemd.crash_shell=true systemd.debug_shell
```
