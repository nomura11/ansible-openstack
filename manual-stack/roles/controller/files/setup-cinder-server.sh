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

donefile="${SETUPDIR}/controller-cinder.done"
logfile="${SETUPDIR}/controller-cinder.log"
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
# Cinder
#

create_database cinder ${CINDER_DBPASS}
service_create ${SETUPDIR}/service-def-cinder-v1.sh
service_create ${SETUPDIR}/service-def-cinder-v2.sh

yum install -q -y openstack-cinder python-cinderclient || exit 1

cat <<EOF | tee ${SETUPDIR}/mod-cinder.conf
[database]
connection = mysql://cinder:${CINDER_DBPASS}@${CONTROLLER_HOSTNAME}/cinder
...
[DEFAULT]
rpc_backend = rabbit
[oslo_messaging_rabbit]
rabbit_host = ${CONTROLLER_HOSTNAME}
rabbit_userid = openstack
rabbit_password = ${RABBIT_PASS}
...
[DEFAULT]
auth_strategy = keystone
[keystone_authtoken]
auth_uri = http://${CONTROLLER_HOSTNAME}:5000
auth_url = http://${CONTROLLER_HOSTNAME}:35357
auth_plugin = password
project_domain_id = default
user_domain_id = default
project_name = service
username = cinder
password=${CINDER_PASS}
...
[DEFAULT]
my_ip = ${CONTROLLER_IP_ADDR}
...
[oslo_concurrency]
lock_path = /var/lib/cinder/tmp
EOF
modify_inifile /etc/cinder/cinder.conf ${SETUPDIR}/mod-cinder.conf

su -s /bin/sh -c "cinder-manage db sync" cinder

# Configure Compute to use Block Storage
cat <<EOF | tee ${SETUPDIR}/mod-nova.conf.cinder
[cinder]
os_region_name = RegionOne
EOF
modify_inifile /etc/nova/nova.conf ${SETUPDIR}/mod-nova.conf.cinder

# Finalize installation
# 1.
systemctl restart openstack-nova-api.service
# 2.
systemctl enable openstack-cinder-api.service openstack-cinder-scheduler.service
systemctl start openstack-cinder-api.service openstack-cinder-scheduler.service

# -------------------------------------------------------------
# Done
touch $donefile
exit 0
