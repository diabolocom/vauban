# How to use

## manual prerequisites

You need a live ISO to be around the local directory. You can download it from
[cdimage.debian.org](https://cdimage.debian.org/cdimage/archive/) or
[cloud.debian.org](https://cloud.debian.org/images/cloud/)
for example.
Be sure to pick amd64 and the standard (or minimal) ISO, without any graphical
packages installed.

You'll also need to configure vauban via vauban-config.sh

## Using CI/CD

CI/CD is only supported by gitlab right now.

You need to edit `config.yml` to reflect what you want, with the inheritance of
masters. A master under another one will be built on top of the previous one.

You also need to setup the `conffs` key in `config.yml` to a proper ansible-valid
expression to select hosts.

Once pushed, you can go to the pipelines tab to create your master.

# Ansible interaction

Please note a few things about ansible:
- systemd is _not_ running when building images, therefore some systemd commands
won't work. For example, `systemctl start` (used with the `systemd` ansible's
module) won't work. It is expected here to write some conditions with `when` to
avoid running those commands when it's a docker build.
`when: ansible_connection != "local"` for example
- `ansible_fqdn` will use docker build's container name, which can't be changed.
Use `inventory_hostname` instead

# PXE boot options

Recommended boot options for PXE looks like :
```
console=tty0 console=ttyS0,115200 net.ifnames=0 verbose rd.debug rd.shell rd.writable.fsimg=1 rd.luks=0 rd.lvm=0 rd.md=0 rd.dm=0 rd.neednet=1 rd.live.debug=1 rd.live.image rootflags=rw rootovl systemd.debug_shell
```
