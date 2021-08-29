#!/bin/bash

VERSION=1.2.0

# Additional ssh opts, another key location for example
#SSH_OPTS="-i /root/id_rsa_target"
SSH_OPTS=""

declare -a VEID_LIST
declare -a TARGET_VEID_LIST
declare -a PIDS_LIST
MIGRATION_STARTED=0
LOG_FILE="${LOG_FILE:-ovztransfer.log}"

VE_ROOT=`grep ^VE_ROOT= /etc/vz/vz.conf | sed 's/VE_ROOT=//' | sed 's#/$VEID##' | sed 's/"//g' | sed "s/'//g"`
VE_PRIVATE=`grep ^VE_PRIVATE= /etc/vz/vz.conf | sed 's/VE_PRIVATE=//' | sed 's#/$VEID##' | sed 's/"//g' | sed "s/'//g"`

if [ -z "$OVZTR_COMPRESS" ]; then
    compress_opt=""
else
    compress_opt="z"
fi

if [ "x$OVZTR_METHOD" == "xrsync" ]; then
    if  grep -q "release 7" /etc/virtuozzo-release 2>/dev/null; then
        echo "rsync is currently not supported when migrating from Vz7"
        exit 1
    else
        METHOD="rsync"
    fi
else
    METHOD="tar"
fi

function stop_scripts() {
	[ $MIGRATION_STARTED -eq 0 ] && return
	echo "Stopping all migration processes..." | tee -a ${LOG_FILE}
	kill -HUP -$$
}

trap stop_scripts EXIT

function error() {
    echo $$: $* | tee -a ${LOG_FILE}
    exit 1
}

function usage() {
    echo "$0 version $VERSION"
    echo "Usage: $0 HOSTNAME SOURCE_VEID0:[TARGET_VEID0] ... [SOURCE_VEIDn:[TARGET_VEIDn]]"
    exit 0
}

function migrate() {
    local veid=$1
    local target_veid=$2
    local target=$3
    local ssh_opts=$4
    local tmpdir
    local quota_restore_command
    local dir
    local param
    local required_space
    local vefstype=5 #ploop
    local inodes_coeff=8 #1/8
    local total_reserve=$((160*1024)) # 160MiB In KiB
    local ostemplate_rpm
    local pid
    local mult
    local xattrs=""
    local block_pid

    REMOTE_VE_ROOT=`ssh $ssh_opts root@$target grep ^VE_ROOT= /etc/vz/vz.conf | sed 's/VE_ROOT=//' | sed 's#/$VEID##' | sed 's/"//g' | sed "s/'//g"`
    REMOTE_VE_PRIVATE=`ssh $ssh_opts root@$target grep ^VE_PRIVATE= /etc/vz/vz.conf | sed 's/VE_PRIVATE=//' | sed 's#/$VEID##' | sed 's/"//g' | sed "s/'//g"`

    # Check for target VEID
    ssh $ssh_opts root@$target [ -d ${REMOTE_VE_PRIVATE}/$target_veid ]
    [ $? -eq 0 ] && error "Container $target_veid already exists on $target"
    ssh $ssh_opts root@$target mkdir -p ${REMOTE_VE_PRIVATE}/$target_veid >> ${LOG_FILE} 2>&1
    [ $? -ne 0 ] && error "Failed to create Container $target_veid private on $target"
    ssh $ssh_opts root@$target mkdir -p ${REMOTE_VE_ROOT}/$target_veid >> ${LOG_FILE} 2>&1
    [ $? -ne 0 ] && error "Failed to create Container $target_veid root on $target"

    # Start Container
    vzctl start $veid --wait >> ${LOG_FILE} 2>&1
    [ $? -ne 0 ] && error "Failed to start Container $veid"

    echo "Container $veid: Shutting down all possible services..." | tee -a ${LOG_FILE}

    # Stop all possible processes inside Container
    PS_IGNORE_REGEX="kthread\|khelper\|/\|ps$"
    PS_TIMEOUT=90
    echo "Waiting for container processes to stop..." | tee -a ${LOG_FILE}
    for pid in `vzctl exec $veid ps | grep -v "${PS_IGNORE_REGEX}" | awk '!/^ *(PID|1) / {print $1}'`; do
        vzctl exec $veid kill $pid >> ${LOG_FILE} 2>&1
    done

    for i in `seq 1 $PS_TIMEOUT`; do
        remaining=`vzctl exec $veid ps | grep -v "${PS_IGNORE_REGEX}" | awk '!/^ *(PID|1) / {print $1}'`
        [ "x$remaining" == "x" ] && break
        sleep 1;
    done

    echo "Killing remaining processes" | tee -a ${LOG_FILE}
    for pid in `vzctl exec $veid ps | awk '!/^ *(PID|1) / {print $1}'`; do
        vzctl exec $veid kill -9 $pid >> ${LOG_FILE} 2>&1
    done

    # Dump old quota
    quota_restore_command=`/usr/sbin/vzdqdump $veid -f -G -U -T 2>/dev/null | awk '/^ugid:/ {
        if ($3 == "1")
                gparm="-g"
        else
                gparm="-u"
        printf("/usr/sbin/setquota %s %s %s %s %s %s -a; ", gparm, $2, $4, $5, $6, $7)
}'`

    # Bind mount
    tmpdir=`vzctl --quiet exec $veid mktemp -d /tmp/bindmnt_XXXXXX`
    vzctl exec $veid "mount -o bind / $tmpdir; tail -f /dev/null > $tmpdir/tmp/lock" >/dev/null 2>&1 &
    block_pid=$!

    echo "Container $veid: Copying data..." | tee -a ${LOG_FILE}

    # Calculate needed diskspace
    required_space=`grep "^DISKSPACE=" $VECONFDIR/$veid.conf | sed -e 's,^DISKSPACE=,,g' -e 's,\",,g' -e 's,.*:,,g'`
    # Parse suffix
    required_space_suffix=${required_space:$((${#required_space}-1))}
    case "$required_space_suffix" in
        T)
            required_space=`echo $required_space | sed "s,T$,,g"`
            mult=$((1024*1024*1024))
            ;;
        G)
            required_space=`echo $required_space | sed "s,G$,,g"`
            mult=$((1024*1024))
            ;;
        M)
            required_space=`echo $required_space | sed "s,M$,,g"`
            mult=1024
            ;;
        *)
            mult=1
            ;;
    esac
    # dots
    required_space=`echo $required_space | sed "s,\.,\,,g"`
    required_space=$((required_space*mult))

    # get exactly used space
    du_space=`/usr/bin/du -sk ${VE_ROOT}/$veid/$tmpdir/ 2>/dev/null | awk '{print $1}'`
    [ "x$du_space" != "x" -a $((du_space+total_reserve)) -gt $required_space ] && required_space=$((du_space+total_reserve))

    # Reserve inodes_coeff for inodes
    required_space=$((required_space + required_space/inodes_coeff))

    # Create destination ploop
    ssh $ssh_opts root@$target mkdir -p ${REMOTE_VE_PRIVATE}/$target_veid/root.hdd >> ${LOG_FILE} 2>&1
    [ $? -ne 0 ] && error "Failed to create root.hdd on $target"
    ssh $ssh_opts root@$target ploop init -t ext4 -s ${required_space}K ${REMOTE_VE_PRIVATE}/$target_veid/root.hdd/root.hds >> ${LOG_FILE} 2>&1
    [ $? -ne 0 ] && error "Failed to create ploop on $target"

    # Mount ploop
    ssh $ssh_opts root@$target ploop mount -m ${REMOTE_VE_ROOT}/$target_veid ${REMOTE_VE_PRIVATE}/$target_veid/root.hdd/DiskDescriptor.xml >> ${LOG_FILE} 2>&1
    [ $? -ne 0 ] && error "Failed to mount ploop on $target"

    # Copy data
    # Check for xattrs
    if [ "x$METHOD" == "xrsync" ]; then
        vzctl --quiet exec $veid rsync --help | grep "xattrs" > /dev/null 2>&1
        [ $? -eq 0 ] && xattrs="--xattrs"
        rsync -a$compress_opt -e ssh --numeric-ids $xattrs -H -S ${VE_ROOT}/$veid/$tmpdir/ root@$target:${REMOTE_VE_ROOT}/$target_veid >> ${LOG_FILE} 2>&1
        [ $? -ne 0 ] && error "Failed to copy data"
    else
        vzctl --quiet exec $veid tar --help | grep "no-xattrs" > /dev/null 2>&1
        [ $? -eq 0 ] && xattrs="--xattrs"
        vzctl --quiet exec $veid tar --numeric-owner $xattrs -c$compress_opt -C $tmpdir ./ 2>/dev/null | ssh $ssh_opts root@$target tar --numeric-owner $xattrs -x$compress_opt -C ${REMOTE_VE_ROOT}/$target_veid >> ${LOG_FILE} 2>&1
        [ $? -ne 0 ] && error "Failed to copy data"
    fi


    # Leave block
    kill $block_pid >> ${LOG_FILE} 2>&1

    # Umount target ploop
    ssh $ssh_opts root@$target ploop umount ${REMOTE_VE_PRIVATE}/$target_veid/root.hdd/DiskDescriptor.xml >> ${LOG_FILE} 2>&1
    [ $? -ne 0 ] && error "Failed to umount ploop on $target"

    # Fill private area
    ssh $ssh_opts root@$target ln -s $vefstype ${REMOTE_VE_PRIVATE}/$target_veid/.ve.layout
    [ $? -ne 0 ] && error "Failed to create layout on $target"
    for dir in scripts dump fs root.hdd/templates; do
        ssh $ssh_opts root@$target mkdir ${REMOTE_VE_PRIVATE}/$target_veid/$dir
        [ $? -ne 0 ] && error "Failed to create $dir dir on $target"
    done
    ssh $ssh_opts root@$target ln -s root.hdd/templates ${REMOTE_VE_PRIVATE}/$target_veid/templates
    [ $? -ne 0 ] && error "Failed to templates dir link on $target"
    ssh $ssh_opts root@$target 'echo -n `hostname` > ${REMOTE_VE_PRIVATE}/$target_veid/.owner' >> ${LOG_FILE} 2>&1
    [ $? -ne 0 ] && error "Failed to create owner file on $target"

    # Copy config
    scp $ssh_opts $VECONFDIR/$veid.conf root@$target:${REMOTE_VE_PRIVATE}/$target_veid/ve.conf >> ${LOG_FILE} 2>&1
    [ $? -ne 0 ] && error "Failed to copy Container config file"

    echo "Container $veid: Setting up destination Container..." | tee -a ${LOG_FILE}

    # Modify VEID inside config
    if [ $target_veid != $veid ]; then
        ssh $ssh_opts root@$target sed -e "s,^VEID=.*,VEID=\"$target_veid\",g" -i ${REMOTE_VE_PRIVATE}/$target_veid/ve.conf
        [ $? -ne 0 ] && error "Failed to modify Container config file"
    fi

    # Fix VE_ROOT - proxmox case
    ssh $ssh_opts root@$target sed -e "s,^VE_ROOT=.*,VE_ROOT=\"${REMOTE_VE_ROOT}/$target_veid\",g" -i ${REMOTE_VE_PRIVATE}/$target_veid/ve.conf
    [ $? -ne 0 ] && error "Failed to fix VE_ROOT in Container config file"

    # Adjust disk space on destination
    ssh $ssh_opts root@$target sed -e "s,^DISKSPACE=.*,DISKSPACE=\"$required_space:$required_space\",g" -i ${REMOTE_VE_PRIVATE}/$target_veid/ve.conf
    [ $? -ne 0 ] && error "Failed to fix destination Container diskspace"

    # Check for ostemplate on target
    eval `grep "^OSTEMPLATE=" $VECONFDIR/$veid.conf`
    ostemplate_rpm=`echo $OSTEMPLATE | sed "s,^\.,,g"`-ez
    ssh $ssh_opts root@$target rpm -q $ostemplate_rpm >> ${LOG_FILE}  2>&1
    if [ $? -ne 0 ]; then
        ssh $ssh_opts root@$target yum install -y $ostemplate_rpm >> ${LOG_FILE} 2>&1
        if [ $? -ne 0 ]; then
            # And disable template if not supported
            ssh $ssh_opts root@$target sed -e "s,^OSTEMPLATE=,#OSTEMPLATE=,g" -i ${REMOTE_VE_PRIVATE}/$target_veid/ve.conf
            [ $? -ne 0 ] && error "Failed to disable param OSTEMPLATE in Container config file"
        fi
    fi

    # Assign default name if not specified
    grep -q "^NAME=" $VECONFDIR/$veid.conf
    if [ $? -ne 0 ]; then
        eval `grep "^HOSTNAME=" $VECONFDIR/$veid.conf`
        ssh $ssh_opts root@$target "echo NAME=$target_veid-$HOSTNAME >> ${REMOTE_VE_PRIVATE}/$target_veid/ve.conf"
    fi

    # Stop source
    vzctl stop $veid >> ${LOG_FILE} 2>&1

    # Remove bind_mount
    vzctl exec $veid umount $tmpdir >> ${LOG_FILE} 2>&1
    vzctl exec $veid rm -rf $tmpdir >> ${LOG_FILE} 2>&1


    # Register Container on target
    ssh $ssh_opts root@$target vzctl register ${REMOTE_VE_PRIVATE}/$target_veid $target_veid >> ${LOG_FILE} 2>&1
    [ $? -ne 0 ] && error "Failed to register Container $target_veid"

    # Mount target
    ssh $ssh_opts root@$target vzctl mount $target_veid >> ${LOG_FILE} 2>&1
    [ $? -ne 0 ] && error "Failed to mount destination Container"

    # Remove
    ssh $ssh_opts root@$target rm -f ${REMOTE_VE_ROOT}/$target_veid/aquota.*
    ssh $ssh_opts root@$target "find ${REMOTE_VE_ROOT}/$target_veid/etc -name *vzquota* 2>/dev/null | xargs rm -f > /dev/null 2>&1"

    # Change
    ssh $ssh_opts root@$target rm -f ${REMOTE_VE_ROOT}/$target_veid/etc/mtab
    ssh $ssh_opts root@$target ln -s /proc/mounts ${REMOTE_VE_ROOT}/$target_veid/etc/mtab
    [ $? -ne 0 ] && error "Failed to fix /etc/mtab in destination Container"

    # Create devices
    ssh $ssh_opts root@$target "mknod ${REMOTE_VE_ROOT}/$target_veid/dev/ptmx c 5 2; chmod 666 ${REMOTE_VE_ROOT}/$target_veid/dev/ptmx" >> ${LOG_FILE} 2>&1
    ssh $ssh_opts root@$target mknod ${REMOTE_VE_ROOT}/$target_veid/etc/udev/devices/ptmx c 5 2 >> ${LOG_FILE} 2>&1

    for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        a=`awk -v num=$i 'BEGIN { printf("%x\n", num) }'`
        ssh $ssh_opts root@$target mknod ${REMOTE_VE_ROOT}/$target_veid/dev/ttyp$a c 3 $i >> ${LOG_FILE} 2>&1
        ssh $ssh_opts root@$target mknod ${REMOTE_VE_ROOT}/$target_veid/etc/udev/devices/ttyp$a c 3 $i >> ${LOG_FILE} 2>&1
        ssh $ssh_opts root@$target mknod ${REMOTE_VE_ROOT}/$target_veid/dev/ptyp$a c 2 $i >> ${LOG_FILE} 2>&1
        ssh $ssh_opts root@$target mknod ${REMOTE_VE_ROOT}/$target_veid/etc/udev/devices/ptyp$a c 2 $i >> ${LOG_FILE} 2>&1
    done

    # Try to restore quotas if any
    if [ "x$quota_restore_command" != "x" ]; then
        # Start target
        ssh $ssh_opts root@$target vzctl start $target_veid --wait >> ${LOG_FILE} 2>&1
        [ $? -ne 0 ] && error "Failed to start destination Container"

        # Restore quotas
        ssh $ssh_opts root@$target "vzctl exec $target_veid \"$quota_restore_command\"" >> ${LOG_FILE} 2>&1
        [ $? -ne 0 ] && error "Failed to restore quota"

        # Stop target
        ssh $ssh_opts root@$target vzctl stop $target_veid >> ${LOG_FILE} 2>&1
    else
        ssh $ssh_opts root@$target vzctl umount $target_veid >> ${LOG_FILE} 2>&1
    fi

    echo "Container $veid: Done, cleaning..." | tee -a ${LOG_FILE}
}

# Check for parameters
TARGET=$1
shift
COUNT=0

while [ ! -z $1 ]; do
	VEID_LIST[$COUNT]=${1%:*}
	[ -z ${VEID_LIST[$COUNT]} ] && usage
	TARGET_VEID_LIST[$COUNT]=${1#*:}
	[ -z ${TARGET_VEID_LIST[$COUNT]} ] && TARGET_VEID_LIST[$COUNT]=${VEID_LIST[$COUNT]}
	shift
	COUNT=$((COUNT+1))
done

[ -z "$TARGET" -o ${#VEID_LIST[@]} -eq 0 ] && usage

echo "Checking target host parameters..." | tee -a ${LOG_FILE}

# Check for ssh $SSH_OPTS key
ssh $SSH_OPTS -o PasswordAuthentication="no" root@$TARGET exit
[ $? -ne 0 ] && error "ssh $SSH_OPTS key was not configured for $TARGET"

MIGRATION_STARTED=1

# Get path to config dir
if [ -d /etc/sysconfig/vz-scripts ]; then
	VECONFDIR=/etc/sysconfig/vz-scripts
elif [ -d /etc/vz/conf ]; then
	VECONFDIR=/etc/vz/conf
else
	error "Failed to detect Containers config dir"
fi

# Start migration in parallel
while [ $COUNT -gt 0 ]; do
	COUNT=$((COUNT-1))
	(migrate ${VEID_LIST[$COUNT]} ${TARGET_VEID_LIST[$COUNT]} $TARGET "$SSH_OPTS" ;) &
	PIDS_LIST[$!]=${VEID_LIST[$COUNT]}
	echo "Migration of Container ${VEID_LIST[$COUNT]} started" | tee -a ${LOG_FILE}
done

PIDS=`jobs -p`
RC=0

while [ ! -z "$PIDS" ]; do
	for pid in $PIDS; do
		sleep 1
		kill -0 $pid >> ${LOG_FILE} 2>&1
		[ $? -eq 0 ] && continue
		wait $pid
		err=$?
		if [ $err -ne 0 ]; then
			echo "Migraton of Container ${PIDS_LIST[$pid]} failed with error $err" | tee -a ${LOG_FILE}
			RC=1
		else
			echo "Migration of Container ${PIDS_LIST[$pid]} completed successfully" | tee -a ${LOG_FILE}
		fi
		PIDS=`echo $PIDS | sed "s,$pid,,g"`
	done
done

echo "All done" | tee -a ${LOG_FILE}

exit $RC
