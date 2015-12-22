#!/bin/bash -x

if [ $# -ne 1 ]; then
	echo "Usage: setup.sh <config>"
	exit 1
elif [ ! -f "$1" ]; then
	echo "File $1 does not exist"
	exit 1
fi

configfile=$1
echo "Reading config file: $1"
. $1

if [ ! -d "${SETUPDIR}" ]; then
	echo "SETUPDIR=$SETUPDIR does not exist"
	exit 1
fi

if [ -z "$CONTROLLER_TUNNEL_IF" ]; then
	echo "CONTROLLER_TUNNEL_IF not defined"
else
	ifup "$CONTROLLER_TUNNEL_IF"
	if [ $? -ne 0 ]; then
		echo "Failed to activate ${CONTROLLER_TUNNEL_IF}"
		exit 1
	fi
fi

if [ -z "$CONTROLLER_EXTERNAL_IF" ]; then
	echo "CONTROLLER_EXTERNAL_IF not defined"
else
	ifup "$CONTROLLER_EXTERNAL_IF"
	if [ $? -ne 0 ]; then
		echo "Failed to activate ${CONTROLLER_EXTERNAL_IF}"
		exit 1
	fi
fi

# -------------------------------------------------------------
export PATH=${SETUPDIR}:$PATH

donefile="${SETUPDIR}/controller.done"
logfile="${SETUPDIR}/controller.log"
exec 3>/dev/stdout >> $logfile 2>&1
if [ -e "$donefile" ]; then
	exit 0
fi

setup-rcfiles.sh $configfile || exit 1
setup-dbserver.sh $configfile || exit 1
setup-rabbitmq-server.sh $configfile || exit 1
setup-keystone-server.sh $configfile || exit 1
setup-clients.sh $configfile || exit 1
setup-glance-server.sh $configfile || exit 1
setup-nova-server.sh $configfile || exit 1
setup-cinder-server.sh $configfile || exit 1
setup-ceilometer-server.sh $configfile || exit 1
setup-neutron-server.sh $configfile || exit 1
setup-heat-server.sh $configfile || exit 1

# -------------------------------------------------------------
# Done
touch $donefile
exit 0
