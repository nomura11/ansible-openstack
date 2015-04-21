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
fi

#
# Check Network-specific parameters
#
if [ -z "$NETWORK_TUNNEL_IF" ]; then
	echo "NETWORK_TUNNEL_IF not defined"
	exit 1
fi
ifup "$NETWORK_TUNNEL_IF"
if [ $? -ne 0 ]; then
	echo "Failed to activate ${NETWORK_TUNNEL_IF}"
	exit 1
fi

if [ -z "$NETWORK_EXTERNAL_IF" ]; then
	echo "NETWORK_EXTERNAL_IF not defined"
	exit 1
fi
ifup "$NETWORK_EXTERNAL_IF"
if [ $? -ne 0 ]; then
	echo "Failed to activate ${NETWORK_EXTERNAL_IF}"
	exit 1
fi

# -------------------------------------------------------------
PWDFILE=${SETUPDIR}/pass.txt
#OPENRC=${SETUPDIR}/openrc.sh
export PATH=${SETUPDIR}:$PATH

donefile="${SETUPDIR}/network.done"
logfile="${SETUPDIR}/network.log"
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
# Network node setup
#

#
# To configure prerequisites
#
cat <<EOF | tee ${SETUPDIR}/mod-net-sysctl.conf
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF
modify_inifile /etc/sysctl.conf ${SETUPDIR}/mod-net-sysctl.conf
sysctl -p

#
# To install the Networking components
#
yum install -q -y openstack-neutron openstack-neutron-ml2 openstack-neutron-openvswitch || exit 1

#
# To configure the Networking common components
#

#service_tenant_id=$(keystone tenant-get service | awk '$2 == "id" { print $4 }')
cat <<EOF | tee ${SETUPDIR}/mod-net-neutron.conf
[DEFAULT]
rpc_backend = rabbit
rabbit_host = ${CONTROLLER_HOSTNAME}
rabbit_password = ${RABBIT_PASS}
auth_strategy = keystone
core_plugin = ml2
service_plugins = router
allow_overlapping_ips = True
[keystone_authtoken]
auth_uri = http://${CONTROLLER_HOSTNAME}:5000/v2.0
identity_uri = http://${CONTROLLER_HOSTNAME}:35357
admin_tenant_name = service
admin_user = neutron
admin_password = ${NEUTRON_PASS}
EOF
modify_inifile /etc/neutron/neutron.conf ${SETUPDIR}/mod-net-neutron.conf

#
# To configure the Modular Layer 2 (ML2) plug-in
#
cat <<EOF | tee ${SETUPDIR}/mod-net-ml2_conf.ini
[ml2]
type_drivers = flat,gre
tenant_network_types = gre
mechanism_drivers = openvswitch
[ml2_type_flat]
flat_networks = external
[ml2_type_gre]
tunnel_id_ranges = 1:1000
[securitygroup]
enable_security_group = True
enable_ipset = True
firewall_driver = neutron.agent.linux.iptables_firewall.OVSHybridIptablesFirewallDriver
[ovs]
local_ip = ${NETWORK_TUNNEL_IF_IP}
enable_tunneling = True
bridge_mappings = external:br-ex
[agent]
tunnel_types = gre
EOF
modify_inifile /etc/neutron/plugins/ml2/ml2_conf.ini ${SETUPDIR}/mod-net-ml2_conf.ini

#
# To configure the Layer-3 (L3) agent
#
cat <<EOF | tee ${SETUPDIR}/mod-net-l3_agent.ini
[DEFAULT]
interface_driver = neutron.agent.linux.interface.OVSInterfaceDriver
use_namespaces = True
external_network_bridge = br-ex
router_delete_namespaces = True
EOF
modify_inifile /etc/neutron/l3_agent.ini ${SETUPDIR}/mod-net-l3_agent.ini

# Reduce MTU of the router to workaround GRE/OVS problem(?)
## https://bugs.launchpad.net/neutron/+bug/1311097
cat <<EOF | tee ${SETUPDIR}/mod-net-l3_agent.ini.mtu-workaround
[DEFAULT]
network_device_mtu = 1470
EOF
modify_inifile /etc/neutron/l3_agent.ini ${SETUPDIR}/mod-net-l3_agent.ini.mtu-workaround


#
# To configure the DHCP agent
#
cat <<EOF | tee ${SETUPDIR}/mod-net-dhcp_agent.ini
[DEFAULT]
interface_driver = neutron.agent.linux.interface.OVSInterfaceDriver
dhcp_driver = neutron.agent.linux.dhcp.Dnsmasq
use_namespaces = True
dhcp_delete_namespaces = True
EOF
modify_inifile /etc/neutron/dhcp_agent.ini ${SETUPDIR}/mod-net-dhcp_agent.ini

# (Optional) DHCP MTU
cat <<EOF | tee ${SETUPDIR}/mod-net-dhcp_agent.ini.mtu
[DEFAULT]
dnsmasq_config_file = /etc/neutron/dnsmasq-neutron.conf
EOF
modify_inifile /etc/neutron/dhcp_agent.ini ${SETUPDIR}/mod-net-dhcp_agent.ini.mtu
echo "dhcp-option-force=26,1454" >  /etc/neutron/dnsmasq-neutron.conf
pkill dnsmasq

#
# To configure the metadata agent
#
cat <<EOF | tee ${SETUPDIR}/mod-net-metadata_agent.ini
[DEFAULT]
auth_url = http://${CONTROLLER_HOSTNAME}:5000/v2.0
auth_region = regionOne
admin_tenant_name = service
admin_user = neutron
admin_password = ${NEUTRON_PASS}
nova_metadata_ip = ${CONTROLLER_HOSTNAME}
metadata_proxy_shared_secret = ${NEUTRON_SHARED_SECRET}
EOF
modify_inifile /etc/neutron/metadata_agent.ini ${SETUPDIR}/mod-net-metadata_agent.ini

#
# To configure the Open vSwitch (OVS) service
#
systemctl enable openvswitch.service
systemctl start openvswitch.service
ovs-vsctl add-br br-ex
ovs-vsctl add-port br-ex ${NETWORK_EXTERNAL_IF}
#ethtool -K ${NETWORK_EXTERNAL_IF} gro off

#
# To finalize the installation
#
# 1.
ln -s /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugin.ini
# Due to packaging bug, ..
cp /usr/lib/systemd/system/neutron-openvswitch-agent.service \
  /usr/lib/systemd/system/neutron-openvswitch-agent.service.orig
sed -i 's,plugins/openvswitch/ovs_neutron_plugin.ini,plugin.ini,g' \
  /usr/lib/systemd/system/neutron-openvswitch-agent.service
# 2.
systemctl enable neutron-openvswitch-agent.service neutron-l3-agent.service \
  neutron-dhcp-agent.service neutron-metadata-agent.service \
  neutron-ovs-cleanup.service
systemctl start neutron-openvswitch-agent.service neutron-l3-agent.service \
  neutron-dhcp-agent.service neutron-metadata-agent.service

touch $donefile
exit 0
