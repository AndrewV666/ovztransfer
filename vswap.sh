#!/bin/sh

if [ -z "$1" ] ; then
    echo "Usage: $0 CTID [RAM] [--set]"
    exit 1
fi

TEST=1
SWAP=0
CTID="$1"
shift

# OVZ7 config
CFG=/vz/private/${CTID}/ve.conf
if [ ! -f ${CFG} ] ; then
    # OVZ6 config
    CFG=/etc/vz/conf/${CTID}.conf
fi
if [ ! -f ${CFG} ] ; then
	echo "No ${CFG} file exists."
	exit 1
fi

# ${PRIVVMPAGES}*4096 bytes
RAM="$(grep PRIVVMPAGES ${CFG} | sed -e 's/^[^0-9]*//' -e 's/:.*//')"
RAM="$((RAM*4096))"
if [ "${RAM}" = "0" ] ; then
	RAM="1024M"
	echo "No PRIVVMPAGES in ${CFG}, using default ${RAM}. Or define it in command line."
fi

while [ $# -gt 0 ] ; do
    case "$1" in
                --set) TEST=0
                ;;
                [0-9]*) RAM="$1"
                ;;
    esac
    shift
done
echo "RAM=${RAM}"

if [ ${TEST} -eq 1 ] ; then
    grep -Ev '^(KMEMSIZE|LOCKEDPAGES|PRIVVMPAGES|SHMPAGES|NUMPROC|PHYSPAGES|VMGUARPAGES|OOMGUARPAGES|NUMTCPSOCK|NUMFLOCK|NUMPTY|NUMSIGINFO|TCPSNDBUF|TCPRCVBUF|OTHERSOCKBUF|DGRAMRCVBUF|NUMOTHERSOCK|DCACHESIZE|NUMFILE|AVNUMPROC|NUMIPTENT|ORIGIN_SAMPLE|SWAPPAGES)=' > ${CFG}.vswap < ${CFG}
    diff -bu ${CFG} ${CFG}.vswap
else
    cp ${CFG} ${CFG}.pre-vswap
    grep -Ev '^(KMEMSIZE|LOCKEDPAGES|PRIVVMPAGES|SHMPAGES|NUMPROC|PHYSPAGES|VMGUARPAGES|OOMGUARPAGES|NUMTCPSOCK|NUMFLOCK|NUMPTY|NUMSIGINFO|TCPSNDBUF|TCPRCVBUF|OTHERSOCKBUF|DGRAMRCVBUF|NUMOTHERSOCK|DCACHESIZE|NUMFILE|AVNUMPROC|NUMIPTENT|ORIGIN_SAMPLE|SWAPPAGES)=' > ${CFG} < ${CFG}.pre-vswap
    echo "vzctl set ${CTID} --ram ${RAM} --swap ${SWAP} --save"
    vzctl set ${CTID} --ram ${RAM} --swap ${SWAP} --save
    vzctl set ${CTID} --reset_ub
fi

