#!/bin/bash

VERSION=2.0

# Additional ssh opts, another key location for example
#SSH_OPTS="-i /root/id_rsa_target"
SSH_OPTS="${SSH_OPTS:-}"
NAMESERVER="${NAMESERVER:-8.8.4.4 8.8.8.8}"
DISTRIBUTION="${DISTRIBUTION:-alt}"

declare -a VEID_LIST
declare -a TARGET_VEID_LIST
LOG_FILE="${LOG_FILE:-ovztransfer.log}"

VE_ROOT=`grep ^VE_ROOT= /etc/vz/vz.conf | sed 's/VE_ROOT=//' | sed 's#/$VEID##' | sed 's/"//g' | sed "s/'//g"`
VE_PRIVATE=`grep ^VE_PRIVATE= /etc/vz/vz.conf | sed 's/VE_PRIVATE=//' | sed 's#/$VEID##' | sed 's/"//g' | sed "s/'//g"`

if [ -z "$OVZTR_COMPRESS" ]; then
    compress_opt=""
else
    compress_opt="z"
fi

function error() {
    echo $$: $* | tee -a ${LOG_FILE}
    exit 1
}

function usage() {
    echo "$0 version $VERSION"
    echo "Usage: $0 [root@]HOSTNAME SOURCE_VEID0[:TARGET_VEID0] ... [SOURCE_VEIDn[:TARGET_VEIDn]]"
    exit 0
}

function migrate() {
    local veid=$1
    local target_veid=$2
    local target=$3
    local ssh_opts=$4
    local dir
    local required_space
    local vefstype=5 #ploop
    local mult
    local CMD="ssh $ssh_opts $target"
    local need_umount=0

    REMOTE_VE_ROOT=`$CMD grep ^VE_ROOT= /etc/vz/vz.conf | sed 's/VE_ROOT=//' | sed 's#/$VEID##' | sed 's/"//g' | sed "s/'//g"`
    REMOTE_VE_PRIVATE=`$CMD grep ^VE_PRIVATE= /etc/vz/vz.conf | sed 's/VE_PRIVATE=//' | sed 's#/$VEID##' | sed 's/"//g' | sed "s/'//g"`

    # Check for target VEID
    $CMD [ -d ${REMOTE_VE_PRIVATE}/$target_veid ]
    [ $? -eq 0 ] && error "Container $target_veid already exists on $target"
    $CMD mkdir -p ${REMOTE_VE_PRIVATE}/$target_veid >> ${LOG_FILE} 2>&1
    [ $? -ne 0 ] && error "Failed to create Container $target_veid private on $target"
    $CMD mkdir -p ${REMOTE_VE_ROOT}/$target_veid >> ${LOG_FILE} 2>&1
    [ $? -ne 0 ] && error "Failed to create Container $target_veid root on $target"

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

    echo "Container $veid: required space=${required_space}K" | tee -a ${LOG_FILE}

    # Create destination ploop
    $CMD mkdir -p ${REMOTE_VE_PRIVATE}/$target_veid/root.hdd >> ${LOG_FILE} 2>&1
    [ $? -ne 0 ] && error "Failed to create root.hdd on $target"
    $CMD ploop init -t ext4 -s ${required_space}K ${REMOTE_VE_PRIVATE}/$target_veid/root.hdd/root.hds >> ${LOG_FILE} 2>&1
    [ $? -ne 0 ] && error "Failed to create ploop on $target"

    # Mount ploop
    $CMD ploop mount -m ${REMOTE_VE_ROOT}/$target_veid ${REMOTE_VE_PRIVATE}/$target_veid/root.hdd/DiskDescriptor.xml >> ${LOG_FILE} 2>&1
    [ $? -ne 0 ] && error "Failed to mount ploop on $target"
    echo "Container $veid: Mounted target ploop" | tee -a ${LOG_FILE}

    # Mount source container if not up
    if [ -n "$(vzctl status $veid | grep 'exist unmounted down')" ]; then
	    vzctl mount $veid >> ${LOG_FILE} 2>&1
            [ $? -ne 0 ] && error "Failed to mount $veid"
	    need_umount=1
	    echo "Container $veid: Mounted source" | tee -a ${LOG_FILE}
    fi
    if [ ! -d "${VE_ROOT}/$veid/etc" ]; then
	    error "No $veid root FS"
    fi

    # Copy data
    rsync -a$compress_opt --numeric-ids --xattrs -H -S -x ${VE_ROOT}/$veid/ $target:${REMOTE_VE_ROOT}/$target_veid | tee -a ${LOG_FILE} 2>&1
    [ $? -ne 0 ] && error "Failed to copy data"

    # Umount source root
    if [ $need_umount -eq 1 ] ; then
    	vzctl umount $veid >> ${LOG_FILE} 2>&1
	[ $? -ne 0 ] && error "Failed to umount $veid"
	echo "Container $veid: Umounted source" | tee -a ${LOG_FILE}
    fi

    # Umount target ploop
    $CMD ploop umount ${REMOTE_VE_PRIVATE}/$target_veid/root.hdd/DiskDescriptor.xml >> ${LOG_FILE} 2>&1
    [ $? -ne 0 ] && error "Failed to umount ploop on $target"
    echo "Container $veid: Umounted target ploop" | tee -a ${LOG_FILE}

    echo "Container $veid: Setting up destination Container..." | tee -a ${LOG_FILE}

    # Fill private area
    $CMD ln -s $vefstype ${REMOTE_VE_PRIVATE}/$target_veid/.ve.layout
    [ $? -ne 0 ] && error "Failed to create layout on $target"
    for dir in scripts dump fs ; do
        $CMD mkdir ${REMOTE_VE_PRIVATE}/$target_veid/$dir
        [ $? -ne 0 ] && error "Failed to create $dir dir on $target"
    done
    $CMD 'echo -n `hostname` > ${REMOTE_VE_PRIVATE}/$target_veid/.owner' >> ${LOG_FILE} 2>&1
    [ $? -ne 0 ] && error "Failed to create owner file on $target"

    # Copy config
    scp $ssh_opts $VECONFDIR/$veid.conf $target:${REMOTE_VE_PRIVATE}/$target_veid/ve.conf >> ${LOG_FILE} 2>&1
    [ $? -ne 0 ] && error "Failed to copy Container config file"

    # Modify VEID inside config
    if [ $target_veid != $veid ]; then
        $CMD sed -e "s,^VEID=.*,VEID=\"$target_veid\",g" -i ${REMOTE_VE_PRIVATE}/$target_veid/ve.conf
        [ $? -ne 0 ] && error "Failed to modify VEID in Container config file"
    fi

    # Modify VE_LAYOUT
    $CMD sed -e 's,^VE_LAYOUT=.*,VE_LAYOUT=\"ploop\",' -i ${REMOTE_VE_PRIVATE}/$target_veid/ve.conf
    [ $? -ne 0 ] && error "Failed to modify VE_LAYOUT in Container config file"

    # Modify OSTEMPLATE
    $CMD sed -e "/^OSTEMPLATE/s,altlinux-,alt-," -i ${REMOTE_VE_PRIVATE}/$target_veid/ve.conf
    [ $? -ne 0 ] && error "Failed to modify OSTEMPLATE in Container config file"

    # Register Container on target
    $CMD vzctl register ${REMOTE_VE_PRIVATE}/$target_veid $target_veid >> ${LOG_FILE} 2>&1
    [ $? -ne 0 ] && error "Failed to register Container $target_veid"

    # Set NAMESERVER
    $CMD vzctl set $target_veid --nameserver \"$NAMESERVER\" --save >> ${LOG_FILE} 2>&1
    [ $? -ne 0 ] && error "Failed to set NAMESERVER $NAMESERVER to Container $target_veid"

    # Set DISTRIBUTION
    $CMD vzctl set $target_veid --distribution $DISTRIBUTION --save >> ${LOG_FILE} 2>&1
    [ $? -ne 0 ] && error "Failed to set DISTRIBUTION $DISTRIBUTION to Container $target_veid"

    # Mount target
    $CMD vzctl mount $target_veid >> ${LOG_FILE} 2>&1
    [ $? -ne 0 ] && error "Failed to mount destination Container"
    echo "Container $veid: Mounted target ploop" | tee -a ${LOG_FILE}

    # Remove quota files
    $CMD "rm -f ${REMOTE_VE_ROOT}/$target_veid/aquota.*"
    $CMD "find ${REMOTE_VE_ROOT}/$target_veid/etc -name *vzquota* 2>/dev/null | xargs rm -f > /dev/null 2>&1"

    # Change /etc/mtab
    $CMD rm -f ${REMOTE_VE_ROOT}/$target_veid/etc/mtab
    $CMD ln -s /proc/mounts ${REMOTE_VE_ROOT}/$target_veid/etc/mtab
    [ $? -ne 0 ] && error "Failed to fix /etc/mtab in destination Container"

    # Remove /dev/*
    $CMD "rm -rf ${REMOTE_VE_ROOT}/$target_veid/dev; mkdir -p ${REMOTE_VE_ROOT}/$target_veid/dev"
    [ $? -ne 0 ] && error "Failed to remove /dev/* in destination Container"

    $CMD vzctl umount $target_veid >> ${LOG_FILE} 2>&1
    [ $? -ne 0 ] && error "Failed to umount destination Container"
    echo "Container $veid: Umounted target ploop" | tee -a ${LOG_FILE}

    # Stop source
#    vzctl stop $veid >> ${LOG_FILE} 2>&1

    echo "Container $veid: Done." | tee -a ${LOG_FILE}
}

# Check for parameters
# HOST from .ssh/config OR root@HOST
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
ssh $SSH_OPTS -o PasswordAuthentication="no" $TARGET exit
[ $? -ne 0 ] && error "ssh $SSH_OPTS key was not configured for $TARGET"

# Get path to config dir
if [ -d /etc/sysconfig/vz-scripts ]; then
	VECONFDIR=/etc/sysconfig/vz-scripts
elif [ -d /etc/vz/conf ]; then
	VECONFDIR=/etc/vz/conf
else
	error "Failed to detect Containers config dir"
fi

RC=0
while [ $COUNT -gt 0 ]; do
        COUNT=$((COUNT-1))
	echo "Migration of Container ${VEID_LIST[$COUNT]} started at" `date` | tee -a ${LOG_FILE}
	migrate ${VEID_LIST[$COUNT]} ${TARGET_VEID_LIST[$COUNT]} $TARGET "$SSH_OPTS"
	err=$?
	if [ $err -ne 0 ]; then
		echo "Migraton of Container ${VEID_LIST[$COUNT]} failed with error $err" | tee -a ${LOG_FILE}
		RC=1
	else
		echo "Migration of Container ${VEID_LIST[$COUNT]} completed successfully at" `date` | tee -a ${LOG_FILE}
	fi
done

echo "All done" | tee -a ${LOG_FILE}
exit $RC
