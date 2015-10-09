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


if [ -z "${FLATNET}" ]; then
	echo "FLATNET not defined"
	exit 1
elif [ -z "${FLATNET_CIDR}" ]; then
	echo "FLATNET_CIDR not defined"
	exit 1
elif [ -z "${FLATNET_GW}" ]; then
	echo "FLATNET_GW not defined"
	exit 1
elif [ -z "${FLATNET_START_IP}" ]; then
	echo "FLATNET_START_IP not defined"
	exit 1
elif [ -z "${FLATNET_END_IP}" ]; then
	echo "FLATNET_END_IP not defined"
	exit 1
fi
# -------------------------------------------------------------
. ${SETUPDIR}/setup-functions
PWDFILE=${SETUPDIR}/pass.txt
OPENRC=${SETUPDIR}/openrc.sh
export PATH=${SETUPDIR}:$PATH

donefile="${SETUPDIR}/controller-ironic.done"
logfile="${SETUPDIR}/controller-ironic.log"
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
# Ironic
#

create_database ironic ${IRONIC_DBPASS}
service_create ${SETUPDIR}/service-def-ironic.sh

yum install -q -y openstack-ironic-api openstack-ironic-conductor python-ironicclient || exit 1

cat <<EOF | tee ${SETUPDIR}/mod-ironic.conf
[database]
connection = mysql://ironic:${IRONIC_DBPASS}@${CONTROLLER_HOSTNAME}/ironic?charset=utf8
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
#project_name = service
#username = ironic
#password = ${IRONIC_PASS}
admin_tenant_name = service
admin_user = ironic
admin_password = ${IRONIC_PASS}
...
[DEFAULT]
my_ip = ${CONTROLLER_IP_ADDR}
...
[neutron]
url = http://${CONTROLLER_HOSTNAME}:9696
...
[glance]
glance_host = ${CONTROLLER_HOSTNAME}
...
[DEFAULT]
log_file = /var/log/ironic.log
...
[DEFAULT]
enabled_drivers = pxe_ssh
[ssh]
libvirt_uri = qemu:///system
...
EOF
modify_inifile /etc/ironic/ironic.conf ${SETUPDIR}/mod-ironic.conf

ironic-dbsync --config-file /etc/ironic/ironic.conf create_schema

systemctl enable openstack-ironic-api.service openstack-ironic-conductor.service
systemctl start openstack-ironic-api.service openstack-ironic-conductor.service

# Nova configuration

cat <<EOF | tee ${SETUPDIR}/mod-nova.conf.ironic
[DEFAULT]
compute_driver = nova.virt.ironic.IronicDriver
firewall_driver = nova.virt.firewall.NoopFirewallDriver
scheduler_host_manager = nova.scheduler.ironic_host_manager.IronicHostManager
ram_allocation_ratio = 1.0
reserved_host_memory_mb = 0
compute_manager = ironic.nova.compute.manager.ClusteredComputeManager
scheduler_use_baremetal_filters = True
...
[ironic]
admin_username = ironic
admin_password = ${IRONIC_PASS}
admin_url = http://${CONTROLLER_HOSTNAME}:35357/v2.0
admin_tenant_name = service
api_endpoint = http://${CONTROLLER_HOSTNAME}:6385/v1
EOF
modify_inifile /etc/nova/nova.conf ${SETUPDIR}/mod-nova.conf.ironic

systemctl restart openstack-nova-scheduler.service

# apply same config to compute node and restart nova-compute service

# Neutron configuration

cat <<EOF | tee ${SETUPDIR}/mod-ml2_conf.ini.ironic
[ml2]
type_drivers = flat
tenant_network_types = flat
mechanism_drivers = openvswitch
...
[ml2_type_flat]
flat_networks = ${FLATNET}
...
[ml2_type_vlan]
network_vlan_ranges = ${FLATNET}
...
[securitygroup]
firewall_driver = neutron.agent.linux.iptables_firewall.OVSHybridIptablesFirewallDriver
enable_security_group = True
...
[ovs]
bridge_mappings = ${FLATNET}:br-ex
EOF
modify_inifile /etc/neutron/plugins/ml2/ml2_conf.ini ${SETUPDIR}/mod-ml2_conf.ini.ironic

# restart openvswitch agent

neutron net-create \
	flat-net \
	--shared \
	--provider:network_type flat \
	--provider:physical_network ${FLATNET}

neutron subnet-create \
	flat-net ${FLATNET_CIDR} \
	--name flat-subnet \
	--ip-version=4 \
	--gateway=${FLATNET_GW} \
	--allocation-pool start=${FLATNET_START_IP},end=${FLATNET_END_IP} \
	--enable-dhcp

# -------------------------------------------------------------
# Done
touch $donefile
exit 0
