# Migrate containers from OpenVZ 6 to OpenVZ 7 host.

```
CT, VE - stand for Container, or Virtual Environment.
CTID, VEID - Container's ID.
```

## ovztransfer.sh - original script from Virtuozzo

## vswap.sh - change CT config to VSwap format
### Usage:
```
vswap.sh CTID [RAM] [--set]
Prints the output of "diff old-config new-config" command when called without "--set" option.
RAM should be in the form of "1024M" or "1G" or "1024000" in bytes.
If RAM is not set, PRIVVMPAGES*4096 value is used.

See https://wiki.openvz.org/VSwap for more details.
```

## ovz6to7.sh - simplified and optimized script for ALT Linux OVZ Containers
### Usage:
```
ovz6to7.sh HOST VEID1 [VEID2 ...]

Migrate containers VEID1,... to HOST.
HOST is from .ssh/config OR root@hostname
Additional variables:
LOG_FILE - path to log file, ./ovztransfer.log is default
NAMESERVER - the list of IPs for CT's /etc/resolv.conf
SSH_OPTS - additional options for ssh/rsync (i.e., "-i /root/id_rsa_target")
```

Convert CT config to VSwap format before migration (use `vswap.sh`)!

`ovz6to7.sh` script migrates simfs or ploop CT to ploop only.

## Examples

### Migration of stopped Containers
SRC - OpenVZ 6 source host

DST - OpenVZ 7 destination host

DST host should be described in .ssh/config file at SRC:
```
Host DST
    HostName 10.0.1.2
    User root
    Port 2222
```
On SRC:
```
SRC# vzctl stop 10001
SRC# LOG_FILE=/tmp/transfer.log NAMESERVER="1.1.1.1 9.9.9.9" ovz6to7.sh DST 10001
Checking target host parameters...
Migration of Container 10001 started at ...
...
Migration of Container 10001 completed successfully at ...
All done
```
On DST:
```
DST# vzctl start 10001
```
On SRC:
```
SRC# vzctl set 10001 --onboot no --save
```

