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
. ${SETUPDIR}/setup-functions
PWDFILE=${SETUPDIR}/pass.txt
OPENRC=${SETUPDIR}/openrc.sh
export PATH=${SETUPDIR}:$PATH

donefile="${SETUPDIR}/controller-glance.done"
logfile="${SETUPDIR}/controller-glance.log"
exec 3>/dev/stdout >> $logfile 2>&1
if [ -e "$donefile" ]; then
	exit 0
fi

# -------------------------------------------------------------
#
# Passwords
#
if [ ! -e ${PWDFILE} ]; then
	echo "${PWDFILE} does not exist"
	exit 1
fi
. ${PWDFILE}
if [ -z "${ADMIN_PASS}" ]; then
	echo "ADMIN_PASS is not set"
	exit 1
fi

#
# openrc
#
if [ ! -e ${OPENRC} ]; then
	echo "${OPENRC} does not exist"
	exit 1
fi
. ${OPENRC}
if [ -z "${OS_PASSWORD}" -o "${OS_PASSWORD}" != "${ADMIN_PASS}" ]; then
	echo "OS_PASSWORD is not correct: ${OS_PASSWORD}"
	exit 1
fi

# -------------------------------------------------------------
#
# Glance
#

create_database glance ${GLANCE_DBPASS}
service_create ${SETUPDIR}/service-def-glance.sh

yum install -q -y openstack-glance python-glanceclient || exit 1
cat <<EOF | tee ${SETUPDIR}/mod-glance.conf
[database]
connection = mysql://glance:${GLANCE_DBPASS}@${CONTROLLER_HOSTNAME}/glance
...
[keystone_authtoken]
auth_uri = http://${CONTROLLER_HOSTNAME}:5000
auth_url = http://${CONTROLLER_HOSTNAME}:35357
auth_plugin = password
project_domain_id = default
user_domain_id = default
project_name = service
username = glance
password = ${GLANCE_PASS}
[paste_deploy]
flavor = keystone
...
[DEFAULT]
notification_driver = noop
EOF
modify_inifile /etc/glance/glance-api.conf ${SETUPDIR}/mod-glance.conf
modify_inifile /etc/glance/glance-registry.conf ${SETUPDIR}/mod-glance.conf

cat <<EOF | tee ${SETUPDIR}/mod-glance-store.conf
[glance_store]
default_store = file
filesystem_store_datadir = /var/lib/glance/images/
EOF
modify_inifile /etc/glance/glance-api.conf ${SETUPDIR}/mod-glance-store.conf

su -s /bin/sh -c "glance-manage db_sync" glance

systemctl enable openstack-glance-api.service openstack-glance-registry.service
systemctl start openstack-glance-api.service openstack-glance-registry.service

# -------------------------------------------------------------
# Done
touch $donefile
exit 0
