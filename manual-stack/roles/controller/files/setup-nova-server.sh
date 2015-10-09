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

donefile="${SETUPDIR}/controller-nova.done"
logfile="${SETUPDIR}/controller-nova.log"
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
# Nova
#

create_database nova ${NOVA_DBPASS}
service_create ${SETUPDIR}/service-def-nova.sh

yum install -q -y openstack-nova-api \
	openstack-nova-cert \
	openstack-nova-conductor \
	openstack-nova-console \
	openstack-nova-novncproxy \
	openstack-nova-scheduler \
	python-novaclient || exit 1

cat <<EOF | tee ${SETUPDIR}/mod-nova.conf
[database]
connection = mysql://nova:${NOVA_DBPASS}@${CONTROLLER_HOSTNAME}/nova
...
[DEFAULT]
rpc_backend = rabbit
[oslo_messaging_rabbit]
rabbit_host = ${CONTROLLER_HOSTNAME}
rabbit_userid = openstack
rabbit_password = ${RABBIT_PASS}
...
[DEFAULT]
auth_strategy=keystone
[keystone_authtoken]
auth_uri = http://${CONTROLLER_HOSTNAME}:5000
auth_url = http://${CONTROLLER_HOSTNAME}:35357
auth_plugin = password
project_domain_id = default
user_domain_id = default
project_name = service
username = nova
password = ${NOVA_PASS}
...
[DEFAULT]
my_ip = ${CONTROLLER_IP_ADDR}
...
[DEFAULT]
vncserver_listen = ${CONTROLLER_IP_ADDR}
vncserver_proxyclient_address = ${CONTROLLER_IP_ADDR}
...
[glance]
host = ${CONTROLLER_HOSTNAME}
...
[oslo_concurrency]
lock_path = /var/lib/nova/tmp
...
[osapi_v3]
enabled = True
EOF
modify_inifile /etc/nova/nova.conf ${SETUPDIR}/mod-nova.conf

su -s /bin/sh -c "nova-manage db sync" nova

systemctl enable openstack-nova-api.service openstack-nova-cert.service \
  openstack-nova-consoleauth.service openstack-nova-scheduler.service \
  openstack-nova-conductor.service openstack-nova-novncproxy.service
systemctl start openstack-nova-api.service openstack-nova-cert.service \
  openstack-nova-consoleauth.service openstack-nova-scheduler.service \
  openstack-nova-conductor.service openstack-nova-novncproxy.service

# FIXME: why
sleep 5
rm -f /var/lib/nova/nova.sqlite

# -------------------------------------------------------------
#
# nova-network
#
## Disable for now (nova-network)
if [ 1 -eq 0 ]; then
cat <<EOF | tee ${SETUPDIR}/mod-nova.conf.network
[DEFAULT]
network_api_class = nova.network.api.API
security_group_api = nova
EOF
modify_inifile /etc/nova/nova.conf ${SETUPDIR}/mod-nova.conf.network

service nova-api restart
service nova-scheduler restart
service nova-conductor restart
fi
## Disable for now (nova-network)

# -------------------------------------------------------------
# Done
touch $donefile
exit 0
