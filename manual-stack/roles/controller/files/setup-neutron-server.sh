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

if [ -z "$CONTROLLER_EXTERNAL_IF" ]; then
	echo "CONTROLLER_EXTERNAL_IF not defined"
fi
if [ -z "$CONTROLLER_TUNNEL_IF_IP" ]; then
	echo "CONTROLLER_TUNNEL_IF_IP not defined"
fi

# -------------------------------------------------------------
. ${SETUPDIR}/setup-functions
PWDFILE=${SETUPDIR}/pass.txt
OPENRC=${SETUPDIR}/openrc.sh
export PATH=${SETUPDIR}:$PATH

donefile="${SETUPDIR}/controller-neutron.done"
logfile="${SETUPDIR}/controller-neutron.log"
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
# Neutron
#

create_database neutron ${NEUTRON_DBPASS}
service_create ${SETUPDIR}/service-def-neutron.sh

yum install -q -y openstack-neutron openstack-neutron-ml2 python-neutronclient which || exit 1
if [ ! -z "$CONTROLLER_TUNNEL_IF_IP" ]; then
	yum install -q -y openstack-neutron-openvswitch ebtables ipset || exit 1
fi

service_tenant_id=$(keystone tenant-get service | awk '$2 == "id" { print $4 }')
cat <<EOF | tee ${SETUPDIR}/mod-neutron.conf
[database]
connection = mysql://neutron:${NEUTRON_DBPASS}@${CONTROLLER_HOSTNAME}/neutron
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
username = neutron
password = ${NEUTRON_PASS}
...
[DEFAULT]
core_plugin = ml2
service_plugins = router
allow_overlapping_ips = True
...
[DEFAULT]
notify_nova_on_port_status_changes = True
notify_nova_on_port_data_changes = True
nova_url = http://${CONTROLLER_HOSTNAME}:8774/v2
[nova]
auth_url = http://${CONTROLLER_HOSTNAME}:35357
auth_plugin = password
project_domain_id = default
user_domain_id = default
region_name = RegionOne
project_name = service
username = nova
password = ${NOVA_PASS}
EOF
modify_inifile /etc/neutron/neutron.conf ${SETUPDIR}/mod-neutron.conf

#
# To configure the Modular Layer 2 (ML2) plug-in
#
cat <<EOF | tee ${SETUPDIR}/mod-ml2.conf.neutron
[ml2]
type_drivers = flat,vlan,gre,vxlan
tenant_network_types = gre
mechanism_drivers = openvswitch
...
[ml2_type_gre]
tunnel_id_ranges = 1:1000
...
[securitygroup]
enable_security_group = True
enable_ipset = True
firewall_driver = neutron.agent.linux.iptables_firewall.OVSHybridIptablesFirewallDriver
EOF
modify_inifile /etc/neutron/plugins/ml2/ml2_conf.ini ${SETUPDIR}/mod-ml2.conf.neutron

#
if [ ! -z "${CONTROLLER_TUNNEL_IF_IP}" ]; then
#
# To configure the Open Vswitch agent
#
cat <<EOF | tee ${SETUPDIR}/mod-ml2-openvswitch_agent.ini.neutron
[ml2_type_flat]
flat_networks = external
...
[ovs]
local_ip = ${CONTROLLER_TUNNEL_IF_IP}
bridge_mappings = external:br-ex
...
[agent]
tunnel_types = gre
EOF
modify_inifile /etc/neutron/plugins/ml2/ml2_conf.ini ${SETUPDIR}/mod-ml2-openvswitch_agent.ini.neutron

#
# To configure the Layer-3 (L3) agent
#
cat <<EOF | tee ${SETUPDIR}/mod-l3_agent.ini.neutron
[DEFAULT]
interface_driver = neutron.agent.linux.interface.OVSInterfaceDriver
external_network_bridge = 
router_delete_namespaces = True
EOF
modify_inifile /etc/neutron/l3_agent.ini ${SETUPDIR}/mod-l3_agent.ini.neutron

# Reduce MTU of the router to workaround GRE/OVS problem(?)
## https://bugs.launchpad.net/neutron/+bug/1311097
cat <<EOF | tee ${SETUPDIR}/mod-l3_agent.ini.mtu-workaround
[DEFAULT]
network_device_mtu = 1470
EOF
modify_inifile /etc/neutron/l3_agent.ini ${SETUPDIR}/mod-l3_agent.ini.mtu-workaround


#
# To configure the DHCP agent
#
cat <<EOF | tee ${SETUPDIR}/mod-dhcp_agent.ini.neutron
[DEFAULT]
interface_driver = neutron.agent.linux.interface.OVSInterfaceDriver
dhcp_driver = neutron.agent.linux.dhcp.Dnsmasq
dhcp_delete_namespaces = True
EOF
modify_inifile /etc/neutron/dhcp_agent.ini ${SETUPDIR}/mod-dhcp_agent.ini.neutron

# (Optional) DHCP MTU
cat <<EOF | tee ${SETUPDIR}/mod-dhcp_agent.ini.mtu.neutron
[DEFAULT]
dnsmasq_config_file = /etc/neutron/dnsmasq-neutron.conf
EOF
modify_inifile /etc/neutron/dhcp_agent.ini ${SETUPDIR}/mod-dhcp_agent.ini.mtu.neutron
echo "dhcp-option-force=26,1454" >  /etc/neutron/dnsmasq-neutron.conf
pkill dnsmasq

#
# To configure the metadata agent
#
cat <<EOF | tee ${SETUPDIR}/mod-metadata_agent.ini.neutron
[DEFAULT]
auth_uri = http://${CONTROLLER_HOSTNAME}:5000
auth_url = http://${CONTROLLER_HOSTNAME}:35357
auth_region = RegionOne
auth_plugin = password
project_domain_id = default
user_domain_id = default
project_name = service
username = neutron
password = ${NEUTRON_PASS}
...
[DEFAULT]
nova_metadata_ip = ${CONTROLLER_HOSTNAME}
...
[DEFAULT]
metadata_proxy_shared_secret = ${NEUTRON_SHARED_SECRET}
EOF
modify_inifile /etc/neutron/metadata_agent.ini ${SETUPDIR}/mod-metadata_agent.ini.neutron

#
# To configure the Open vSwitch (OVS) service
#
systemctl enable openvswitch.service
systemctl start openvswitch.service
ovs-vsctl add-br br-ex
ovs-vsctl add-port br-ex ${CONTROLLER_EXTERNAL_IF}
ethtool -K ${CONTROLLER_EXTERNAL_IF} gro off

fi
# end of : [ ! -z "${CONTROLLER_TUNNEL_IF_IP}" ]

#
# To configure Compute to use Networking
#
cat <<EOF | tee ${SETUPDIR}/mod-nova.conf.neutron
[DEFAULT]
network_api_class = nova.network.neutronv2.api.API
security_group_api = neutron
linuxnet_interface_driver = nova.network.linux_net.LinuxOVSInterfaceDriver
firewall_driver = nova.virt.firewall.NoopFirewallDriver
...
[neutron]
url = http://${CONTROLLER_HOSTNAME}:9696
auth_strategy = keystone
admin_auth_url = http://${CONTROLLER_HOSTNAME}:35357/v2.0
admin_tenant_name = service
admin_username = neutron
admin_password = ${NEUTRON_PASS}
...
service_metadata_proxy = True
metadata_proxy_shared_secret = ${NEUTRON_SHARED_SECRET}
EOF
modify_inifile /etc/nova/nova.conf ${SETUPDIR}/mod-nova.conf.neutron

#
# To finalize installation
#
ln -s /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugin.ini
su -s /bin/sh -c "neutron-db-manage --config-file /etc/neutron/neutron.conf \
  --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade head" neutron
systemctl restart openstack-nova-api.service openstack-nova-scheduler.service \
  openstack-nova-conductor.service
if [ -z "$CONTROLLER_TUNNEL_IF_IP" ]; then
	systemctl enable neutron-server.service
	systemctl start neutron-server.service
else
	systemctl enable neutron-server.service \
		neutron-openvswitch-agent.service neutron-dhcp-agent.service \
		neutron-metadata-agent.service
	systemctl start neutron-server.service \
		neutron-openvswitch-agent.service neutron-dhcp-agent.service \
		neutron-metadata-agent.service
	systemctl enable neutron-l3-agent.service
	systemctl start neutron-l3-agent.service
fi

# -------------------------------------------------------------
# Done
touch $donefile
exit 0
