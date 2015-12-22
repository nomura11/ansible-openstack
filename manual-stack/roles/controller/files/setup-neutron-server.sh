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

yum install -q -y openstack-neutron openstack-neutron-ml2 \
  python-neutronclient || exit 1

if [ ! -z "$CONTROLLER_TUNNEL_IF_IP" ]; then
	yum install -q -y openstack-neutron-openvswitch ebtables ipset || exit 1
fi

service_tenant_id=$(keystone tenant-get service | awk '$2 == "id" { print $4 }')
cat <<EOF | tee ${SETUPDIR}/mod-neutron.conf
[database]
connection = mysql://neutron:${NEUTRON_DBPASS}@${CONTROLLER_HOSTNAME}/neutron
...
[DEFAULT]
core_plugin = ml2
service_plugins = router
allow_overlapping_ips = True
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
...
[oslo_concurrency]
lock_path = /var/lib/neutron/tmp
EOF
modify_inifile /etc/neutron/neutron.conf ${SETUPDIR}/mod-neutron.conf

#
# To configure the Modular Layer 2 (ML2) plug-in
#
cat <<EOF | tee ${SETUPDIR}/mod-ml2.conf.neutron
[ml2]
type_drivers = flat,vlan,vxlan
tenant_network_types = vxlan
mechanism_drivers = openvswitch
...
[ml2]
#extension_drivers = port_security
...
[ml2_type_flat]
flat_networks = public
...
[ml2_type_vxlan]
vni_ranges = 1:1000
...
[securitygroup]
enable_security_group = True
firewall_driver = neutron.agent.linux.iptables_firewall.OVSHybridIptablesFirewallDriver
EOF
modify_inifile /etc/neutron/plugins/ml2/ml2_conf.ini ${SETUPDIR}/mod-ml2.conf.neutron

#
if [ ! -z "${CONTROLLER_TUNNEL_IF_IP}" ]; then

#
# To configure the Open Vswitch agent
#
cat <<EOF | tee ${SETUPDIR}/mod-ml2-openvswitch_agent.ini.neutron
[ovs]
integration_bridge = br-int
tunnel_bridge = br-tun
local_ip = ${CONTROLLER_TUNNEL_IF_IP}
enable_tunneling = True
bridge_mappings = public:br-ex
...
[agent]
polling_interval = 2
tunnel_types =vxlan
vxlan_udp_port =4789
l2_population = False
arp_responder = False
prevent_arp_spoofing = True
enable_distributed_routing = False
drop_flows_on_start=False
...
[securitygroup]
enable_security_group = True
firewall_driver = neutron.agent.linux.iptables_firewall.OVSHybridIptablesFirewallDriver
...
EOF
modify_inifile /etc/neutron/plugins/ml2/openvswitch_agent.ini ${SETUPDIR}/mod-ml2-openvswitch_agent.ini.neutron

#
# To configure the layer-3 agent
#
cat <<EOF | tee ${SETUPDIR}/mod-l3_agent.ini.neutron
[DEFAULT]
interface_driver = neutron.agent.linux.interface.OVSInterfaceDriver
external_network_bridge =
EOF
modify_inifile /etc/neutron/l3_agent.ini ${SETUPDIR}/mod-l3_agent.ini.neutron

#
# To configure the DHCP agent
#
cat <<EOF | tee ${SETUPDIR}/mod-dhcp_agent.ini.neutron
[DEFAULT]
interface_driver = neutron.agent.linux.interface.OVSInterfaceDriver
dhcp_driver = neutron.agent.linux.dhcp.Dnsmasq
enable_isolated_metadata = True
EOF
modify_inifile /etc/neutron/dhcp_agent.ini ${SETUPDIR}/mod-dhcp_agent.ini.neutron

# (Optional) DHCP MTU
cat <<EOF | tee ${SETUPDIR}/mod-dhcp_agent.ini.mtu.neutron
[DEFAULT]
dnsmasq_config_file = /etc/neutron/dnsmasq-neutron.conf
EOF
modify_inifile /etc/neutron/dhcp_agent.ini ${SETUPDIR}/mod-dhcp_agent.ini.mtu.neutron
echo "dhcp-option-force=26,1450" >  /etc/neutron/dnsmasq-neutron.conf
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

fi
# endif ${CONTROLLER_TUNNEL_IF_IP}

#
# To configure Compute to use Networking
#
cat <<EOF | tee ${SETUPDIR}/mod-nova.conf.neutron
[neutron]
url = http://${CONTROLLER_HOSTNAME}:9696
auth_url = http://${CONTROLLER_HOSTNAME}:35357
auth_plugin = password
project_domain_id = default
user_domain_id = default
region_name = RegionOne
project_name = service
username = neutron
password = ${NEUTRON_PASS}
...
service_metadata_proxy = True
metadata_proxy_shared_secret = ${NEUTRON_SHARED_SECRET}
EOF
modify_inifile /etc/nova/nova.conf ${SETUPDIR}/mod-nova.conf.neutron

#
if [ ! -z "${CONTROLLER_TUNNEL_IF_IP}" ]; then

#
# To configure the Open vSwitch (OVS) service
#
systemctl enable openvswitch.service
systemctl start openvswitch.service
ovs-vsctl add-br br-ex
ovs-vsctl add-port br-ex ${CONTROLLER_EXTERNAL_IF}
#ethtool -K ${CONTROLLER_EXTERNAL_IF} gro off

fi
# endif ${CONTROLLER_TUNNEL_IF_IP}

#
# To finalize installation
#
# 1.
ln -s /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugin.ini
# 2.
su -s /bin/sh -c "neutron-db-manage --config-file /etc/neutron/neutron.conf \
  --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade head" neutron
# 3.
systemctl restart openstack-nova-api.service

# 4.
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
