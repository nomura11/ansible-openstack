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

#
# Check General parameters
#
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

#
# Check Storage-specific parameters
#
if [ -z "$STORAGE_NETWORK_IF" ]; then
	echo "STORAGE_NETWORK_IF not defined"
	exit 1
elif [ -z "$STORAGE_NETWORK_IF_IP" ]; then
	echo "STORAGE_NETWORK_IF_IP not defined"
	exit 1
fi
ifup "$STORAGE_NETWORK_IF"
if [ $? -ne 0 ]; then
	echo "Failed to activate ${STORAGE_NETWORK_IF}"
	exit 1
fi
if [ -z "$STORAGE_PVS" ]; then
	echo "STORAGE_PVS not defined"
	exit 1
fi
goodpvs=
for d in $STORAGE_PVS; do
	if [ ! -b $d ]; then
		echo "Not a valid block device: $d"
		continue
	fi
	goodpvs="$goodpvs $d"
done
if [ -z "$goodpvs" ]; then
	exit 1
fi
if [ -z "$MANAGEMENT_IP_ADDR" ]; then
	echo "MANAGEMENT_IP_ADDR not defined"
	exit 1
fi

# -------------------------------------------------------------
PWDFILE=${SETUPDIR}/pass.txt
export PATH=${SETUPDIR}:$PATH

donefile="${SETUPDIR}/storage.done"
logfile="${SETUPDIR}/storage.log"
exec 3>/dev/stdout >> $logfile 2>&1
if [ -e "$donefile" ]; then
	exit 0
fi

# -------------------------------------------------------------
#
# Passwords
#
if [ ! -e ${PWDFILE} ]; then
	echo "Password file ($PWDFILE) not exist"
	exit 1
fi
. ${PWDFILE}

# -------------------------------------------------------------
#
# Install and configure a storage node
#

#
# To configure prerequisites
#
# 1.
yum install -q -y lvm2 || exit 1
systemctl enable lvm2-lvmetad.service
systemctl start lvm2-lvmetad.service
# 2., 3.
vgcreate cinder-volumes ${goodpvs} || exit 1
# ?.
#yum install -q -y qemu-img || exit 1

#
# Install and configure Block Storage volume components
#
yum install -q -y openstack-cinder targetcli python-oslo-policy || exit 1

cat <<EOF | tee ${SETUPDIR}/mod-blk-cinder.conf
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
password = ${CINDER_PASS}
...
[DEFAULT]
my_ip = ${MANAGEMENT_IP_ADDR}
...
[lvm]
volume_driver = cinder.volume.drivers.lvm.LVMVolumeDriver
volume_group = cinder-volumes
iscsi_protocol = iscsi
iscsi_helper = lioadm
...
[DEFAULT]
enabled_backends = lvm
...
[DEFAULT]
glance_host = ${CONTROLLER_HOSTNAME}
...
[oslo_concurrency]
lock_path = /var/lib/cinder/tmp
EOF
modify_inifile /etc/cinder/cinder.conf ${SETUPDIR}/mod-blk-cinder.conf

# Use specific network for storage traffic:
# http://www.gossamer-threads.com/lists/openstack/operators/30097
cat <<EOF | tee ${SETUPDIR}/mod-blk-cinder.conf.storage_ip
[DEFAULT]
iscsi_ip_address = ${STORAGE_NETWORK_IF_IP}
[lvm]
iscsi_ip_address = ${STORAGE_NETWORK_IF_IP}
EOF
modify_inifile /etc/cinder/cinder.conf ${SETUPDIR}/mod-blk-cinder.conf.storage_ip

#
# To finalize installation
#
systemctl enable openstack-cinder-volume.service target.service
systemctl start openstack-cinder-volume.service target.service


# -------------------------------------------------------------
#
# Ceilometer
#

cat <<EOF | tee ${SETUPDIR}/mod-blk-cinder.conf.ceilometer
[DEFAULT]
notification_driver = messagingv2
EOF
modify_inifile /etc/cinder/cinder.conf ${SETUPDIR}/mod-blk-cinder.conf.ceilometer
systemctl restart openstack-cinder-volume.service

# -------------------------------------------------------------
touch $donefile
exit 0
