#!/bin/bash -x

if [ $# -ne 1 ]; then
	echo "Usage: setup.sh <config>"
	exit 1
elif [ ! -f "$1" ]; then
	echo "File $1 does not exist"
	exit 1
fi

echo "Reading config file: $1"
. $1

if [ ! -d "${SETUPDIR}" ]; then
	echo "SETUPDIR=$SETUPDIR does not exist"
	exit 1
elif [ -z "$CONTROLLER_HOSTNAME" ]; then
	echo "CONTROLLER_HOSTNAME not defined"
	exit 1
elif [ -z "$CONTROLLER_IP_ADDR" ]; then
	echo "CONTROLLER_IP_ADDR not defined"
	exit 1
elif [ -z "$DBROOTPASS" ]; then
	echo "DBROOTPASS not defined"
	exit 1
fi

# -------------------------------------------------------------
PWDFILE=${SETUPDIR}/pass.txt
OPENRC=${SETUPDIR}/openrc.sh

donefile="${SETUPDIR}/controller-rcfiles.done"
logfile="${SETUPDIR}/controller-rcfiles.log"
exec 3>/dev/stdout >> $logfile 2>&1
if [ -e "$donefile" ]; then
	exit 0
fi

# -------------------------------------------------------------
#
# Passwords
#
if [ ! -e ${PWDFILE} ]; then
	echo "Generating password file"
	pwnames='
	RABBIT_PASS
	KEYSTONE_DBPASS
	ADMIN_PASS
	ADMIN_TOKEN
	GLANCE_DBPASS
	GLANCE_PASS
	NOVA_DBPASS
	NOVA_PASS
	DASH_DBPASS
	CINDER_DBPASS
	CINDER_PASS
	NEUTRON_DBPASS
	NEUTRON_PASS
	HEAT_DBPASS
	HEAT_PASS
	CEILOMETER_DBPASS
	CEILOMETER_PASS
	'
	for n in $pwnames; do
		echo "$n=$(openssl rand -hex 10)"
	done | tee ${PWDFILE}
fi
. ${PWDFILE}
if [ -z "${ADMIN_PASS}" ]; then
	echo "ADMIN_PASS is not set"
	exit 1
fi

#
# openrc
#
cat <<EOF | tee ${OPENRC}
export OS_USERNAME=admin
export OS_PASSWORD=${ADMIN_PASS}
export OS_TENANT_NAME=admin
export OS_AUTH_URL=http://${CONTROLLER_HOSTNAME}:35357/v2.0
EOF
. ${OPENRC}
if [ -z "${OS_PASSWORD}" -o "${OS_PASSWORD}" != "${ADMIN_PASS}" ]; then
	echo "OS_PASSWORD is not correct: ${OS_PASSWORD}"
	exit 1
fi

# -------------------------------------------------------------
# Done
touch $donefile
exit 0
