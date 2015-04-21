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
# Check Compute-specific parameters
#
if [ -z "$MANAGEMENT_IP_ADDR" ]; then
	echo "MANAGEMENT_IP_ADDR not defined"
	exit 1
fi
if [ -z "$COMPUTE_INTERNAL_IF" ]; then
	echo "COMPUTE_INTERNAL_IF not defined"
	exit 1
fi
ifup "$COMPUTE_INTERNAL_IF"
if [ $? -ne 0 ]; then
	echo "Failed to activate ${COMPUTE_INTERNAL_IF}"
	exit 1
fi

if [ -z "$COMPUTE_STORAGE_IF" ]; then
	echo "COMPUTE_STORAGE_IF not defined"
	exit 1
fi
ifup "$COMPUTE_STORAGE_IF"
if [ $? -ne 0 ]; then
	echo "Failed to activate ${COMPUTE_STORAGE_IF}"
	exit 1
fi

# -------------------------------------------------------------
PWDFILE=${SETUPDIR}/pass.txt
#OPENRC=${SETUPDIR}/openrc.sh
export PATH=${SETUPDIR}:$PATH

donefile="${SETUPDIR}/compute.done"
logfile="${SETUPDIR}/compute.log"
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
# Nova Compute
#
yum install -q -y openstack-nova-compute sysfsutils || exit 1

cat <<EOF | tee ${SETUPDIR}/mod-comp-nova.conf
[DEFAULT]
rpc_backend = rabbit
rabbit_host = ${CONTROLLER_HOSTNAME}
rabbit_password = ${RABBIT_PASS}
auth_strategy=keystone
my_ip=${MANAGEMENT_IP_ADDR}
vnc_enabled=True
vncserver_listen=0.0.0.0
vncserver_proxyclient_address=${MANAGEMENT_IP_ADDR}
novncproxy_base_url=http://${CONTROLLER_IP_ADDR}:6080/vnc_auto.html
[keystone_authtoken]
auth_uri = http://${CONTROLLER_HOSTNAME}:5000/v2.0
identity_uri = http://${CONTROLLER_HOSTNAME}:35357
admin_tenant_name = service
admin_user = nova
admin_password = ${NOVA_PASS}
[glance]
host=${CONTROLLER_HOSTNAME}
[osapi_v3]
enabled = True
EOF
modify_inifile /etc/nova/nova.conf ${SETUPDIR}/mod-comp-nova.conf

# for test only
if ! (grep -q vmx /proc/cpuinfo); then
	cat <<EOF | tee ${SETUPDIR}/mod-comp-nova.conf.qemu
[libvirt]
virt_type=qemu
EOF
	modify_inifile /etc/nova/nova.conf ${SETUPDIR}/mod-comp-nova.conf.qemu
fi

systemctl enable libvirtd.service openstack-nova-compute.service
systemctl start libvirtd.service openstack-nova-compute.service

# -------------------------------------------------------------
#
# Clean up libvirt
#
if (virsh net-info default >& /dev/null); then
	virsh net-destroy default
	virsh net-undefine default
fi

# -------------------------------------------------------------
#
# Neutron
#

#
# To configure prerequisites
#
cat <<EOF >> /etc/sysctl.conf
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF
sysctl -p

#
# To install the Networking components
#
yum install -q -y openstack-neutron-ml2 openstack-neutron-openvswitch || exit 1

#
# To configure the Networking common components
#
cat <<EOF | tee ${SETUPDIR}/mod-comp-neutron.conf
[DEFAULT]
rpc_backend = rabbit
rabbit_host = ${CONTROLLER_HOSTNAME}
rabbit_password = ${RABBIT_PASS}
auth_strategy = keystone
core_plugin = ml2
service_plugins = router
allow_overlapping_ips = True
[keystone_authtoken]
auth_uri = http://${CONTROLLER_HOSTNAME}:5000/v2.0/
identity_uri = http://${CONTROLLER_HOSTNAME}:35357
admin_tenant_name = service
admin_user = neutron
admin_password = ${NEUTRON_PASS}
EOF
modify_inifile /etc/neutron/neutron.conf ${SETUPDIR}/mod-comp-neutron.conf

#
# To configure the Modular Layer 2 (ML2) plug-in
#
cat <<EOF | tee ${SETUPDIR}/mod-comp-ml2_conf.ini
[ml2]
type_drivers = flat,gre
tenant_network_types = gre
mechanism_drivers = openvswitch
[ml2_type_gre]
tunnel_id_ranges = 1:1000
[securitygroup]
enable_security_group = True
enable_ipset = True
firewall_driver = neutron.agent.linux.iptables_firewall.OVSHybridIptablesFirewallDriver
[ovs]
local_ip = ${COMPUTE_INTERNAL_IF_IP}
enable_tunneling = True
[agent]
tunnel_types = gre
EOF
modify_inifile /etc/neutron/plugins/ml2/ml2_conf.ini ${SETUPDIR}/mod-comp-ml2_conf.ini

#
# To configure the Open vSwitch (OVS) service
#
systemctl enable openvswitch.service
systemctl start openvswitch.service

#
# To configure Compute to use Networking
#
cat <<EOF | tee ${SETUPDIR}/mod-comp-nova.conf.neutron
[DEFAULT]
network_api_class=nova.network.neutronv2.api.API
security_group_api = neutron
linuxnet_interface_driver = nova.network.linux_net.LinuxOVSInterfaceDriver
firewall_driver = nova.virt.firewall.NoopFirewallDriver
[neutron]
url=http://${CONTROLLER_HOSTNAME}:9696
auth_strategy=keystone
admin_auth_url=http://${CONTROLLER_HOSTNAME}:35357/v2.0
admin_tenant_name=service
admin_username=neutron
admin_password=${NEUTRON_PASS}
EOF
modify_inifile /etc/nova/nova.conf ${SETUPDIR}/mod-comp-nova.conf.neutron

#
# To finalize the installation
#
# 1.
ln -s /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugin.ini
#
cp /usr/lib/systemd/system/neutron-openvswitch-agent.service \
  /usr/lib/systemd/system/neutron-openvswitch-agent.service.orig
sed -i 's,plugins/openvswitch/ovs_neutron_plugin.ini,plugin.ini,g' \
  /usr/lib/systemd/system/neutron-openvswitch-agent.service
# 2.
systemctl restart openstack-nova-compute.service
# 3.
systemctl enable neutron-openvswitch-agent.service
systemctl start neutron-openvswitch-agent.service

# -------------------------------------------------------------
#
# Nova Network (FlatDHCP + multihost)
#

# Disable (nova-network)
if [ 1 -eq 0 ]; then

# For FlatDHCP model, define bridge interface above flat interface
ifdir=/etc/network/interfaces.d
if [ -z "${NOVA_NETWORK_VLAN_START}" ] && \
   [ ! -f $ifdir/${NOVA_NETWORK_FLAT_BRIDGE}.cfg ]; then
	if [ -f $ifdir/${NETWORK_TUNNEL_IF}.cfg ]; then
		ifdown ${NETWORK_TUNNEL_IF}
		cat <<EOF | tee $ifdir/${NOVA_NETWORK_FLAT_BRIDGE}.cfg
auto ${NOVA_NETWORK_FLAT_BRIDGE}
iface ${NOVA_NETWORK_FLAT_BRIDGE} inet manual
        bridge_stp off
        bridge_fd 0
        bridge_maxwait 0
        bridge_ports ${NETWORK_TUNNEL_IF}
EOF
		cat <<EOF | tee $ifdir/${NETWORK_TUNNEL_IF}.cfg
auto ${NETWORK_TUNNEL_IF}
iface ${NETWORK_TUNNEL_IF} inet manual
EOF
		ifup ${NETWORK_TUNNEL_IF}
		ifup ${NOVA_NETWORK_FLAT_BRIDGE}
	fi
fi

yum install -q -y nova-network nova-api-metadata vlan || exit 1

cat <<EOF | tee ${SETUPDIR}/mod-comp-nova.conf.network
[DEFAULT]
network_api_class=nova.network.api.API
security_group_api=nova
firewall_driver=nova.virt.libvirt.firewall.IptablesFirewallDriver
network_size=${NOVA_NETWORK_SIZE}
allow_same_net_traffic=False
multi_host=True
send_arp_for_ha=True
share_dhcp_address=True
force_dhcp_release=True
public_interface=${NETWORK_EXTERNAL_IF}
EOF
modify_inifile /etc/nova/nova.conf ${SETUPDIR}/mod-comp-nova.conf.network

if [ "${NOVA_NETWORK_VLAN_START}" ]; then
	# Vlan + multihost
	cat <<EOF | tee ${SETUPDIR}/mod-comp-nova.conf.network.vlan
[DEFAULT]
network_manager=nova.network.manager.VlanManager
vlan_interface=${NETWORK_TUNNEL_IF}
vlan_start=${NOVA_NETWORK_VLAN_START}
EOF
	modify_inifile /etc/nova/nova.conf ${SETUPDIR}/mod-comp-nova.conf.network.vlan
else
	# FlatDHCP + multihost
	cat <<EOF | tee ${SETUPDIR}/mod-comp-nova.conf.network.flatdhcp
[DEFAULT]
network_manager=nova.network.manager.FlatDHCPManager
flat_network_bridge=${NOVA_NETWORK_FLAT_BRIDGE}
flat_interface=${NETWORK_TUNNEL_IF}
EOF
	modify_inifile /etc/nova/nova.conf ${SETUPDIR}/mod-comp-nova.conf.network.flatdhcp
fi

service nova-network restart
service nova-api-metadata restart

# FIXME: why
sleep 5
nova-manage service list

fi
# Disabled (nova-network)

# -------------------------------------------------------------
#
# Ceilometer
#

yum install -q -y openstack-ceilometer-compute python-ceilometerclient python-pecan || exit 1

cat <<EOF | tee ${SETUPDIR}/mod-comp-nova.conf.ceilometer
[DEFAULT]
instance_usage_audit = True
instance_usage_audit_period = hour
notify_on_state_change = vm_and_task_state
notification_driver = nova.openstack.common.notifier.rpc_notifier
notification_driver = ceilometer.compute.nova_notifier
EOF
modify_inifile /etc/nova/nova.conf ${SETUPDIR}/mod-comp-nova.conf.ceilometer

systemctl restart openstack-nova-compute.service

cat <<EOF | tee ${SETUPDIR}/mod-comp-ceilometer.conf
[DEFAULT]
rabbit_host = ${CONTROLLER_HOSTNAME}
rabbit_password = ${RABBIT_PASS}
log_dir = /var/log/ceilometer
[publisher]
metering_secret = ${CEILOMETER_SHARED_SECRET}
[keystone_authtoken]
auth_uri = http://${CONTROLLER_HOSTNAME}:5000/v2.0
identity_uri = http://${CONTROLLER_HOSTNAME}:35357
admin_tenant_name = service
admin_user = ceilometer
admin_password = ${CEILOMETER_PASS}
[service_credentials]
os_auth_url = http://${CONTROLLER_HOSTNAME}:5000/v2.0
os_username = ceilometer
os_tenant_name = service
os_password = ${CEILOMETER_PASS}
os_endpoint_type = internalURL
os_region_name = regionOne
EOF
modify_inifile /etc/ceilometer/ceilometer.conf ${SETUPDIR}/mod-comp-ceilometer.conf

systemctl enable openstack-ceilometer-compute.service
systemctl start openstack-ceilometer-compute.service

# -------------------------------------------------------------
touch $donefile
exit 0
