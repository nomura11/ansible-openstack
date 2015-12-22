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
else
	ifup "$COMPUTE_STORAGE_IF"
	if [ $? -ne 0 ]; then
		echo "Failed to activate ${COMPUTE_STORAGE_IF}"
		exit 1
	fi
fi

if [ -z "$COMPUTE_EXTERNAL_IF" ]; then
	echo "COMPUTE_EXTERNAL_IF not defined"
else
	ifup "$COMPUTE_EXTERNAL_IF"
	if [ $? -ne 0 ]; then
		echo "Failed to activate ${COMPUTE_EXTERNAL_IF}"
		exit 1
	fi
fi

# -------------------------------------------------------------
PWDFILE=${SETUPDIR}/pass.txt
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
username = nova
password = ${NOVA_PASS}
...
[DEFAULT]
my_ip = ${MANAGEMENT_IP_ADDR}
...
[DEFAULT]
vnc_enabled = True
vncserver_listen = 0.0.0.0
vncserver_proxyclient_address = ${MANAGEMENT_IP_ADDR}
novncproxy_base_url = http://${CONTROLLER_IP_ADDR}:6080/vnc_auto.html
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
modify_inifile /etc/nova/nova.conf ${SETUPDIR}/mod-comp-nova.conf

# for test only
if ! (grep -q vmx /proc/cpuinfo); then
	cat <<EOF | tee ${SETUPDIR}/mod-comp-nova.conf.qemu
[libvirt]
virt_type = qemu
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
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOF
sysctl -p

#
# To install the Networking components
#
yum install -q -y openstack-neutron openstack-neutron-ml2 openstack-neutron-openvswitch || exit 1

#
# To configure the Networking common components
#
cat <<EOF | tee ${SETUPDIR}/mod-comp-neutron.conf
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
EOF
modify_inifile /etc/neutron/neutron.conf ${SETUPDIR}/mod-comp-neutron.conf

#
# To configure the Modular Layer 2 (ML2) plug-in
#
cat <<EOF | tee ${SETUPDIR}/mod-comp-ml2_conf.ini
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
...
[ovs]
local_ip = ${COMPUTE_INTERNAL_IF_IP}
...
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
# Ceilometer
#

#
# To install and configure the agent
#
yum install -q -y openstack-ceilometer-compute python-ceilometerclient python-pecan || exit 1

cat <<EOF | tee ${SETUPDIR}/mod-comp-ceilometer.conf
[publisher]
telemetry_secret = ${CEILOMETER_SHARED_SECRET}
...
[DEFAULT]
rpc_backend = rabbit
[oslo_messaging_rabbit]
rabbit_host = ${CONTROLLER_HOSTNAME}
rabbit_userid = openstack
rabbit_password = ${RABBIT_PASS}
...
[keystone_authtoken]
auth_uri = http://${CONTROLLER_HOSTNAME}:5000/v2.0
identity_uri = http://${CONTROLLER_HOSTNAME}:35357
admin_tenant_name = service
admin_user = ceilometer
admin_password = ${CEILOMETER_PASS}
...
[service_credentials]
os_auth_url = http://${CONTROLLER_HOSTNAME}:5000/v2.0
os_username = ceilometer
os_tenant_name = service
os_password = ${CEILOMETER_PASS}
os_endpoint_type = internalURL
os_region_name = RegionOne
...
[DEFAULT]
log_dir = /var/log/ceilometer
EOF
modify_inifile /etc/ceilometer/ceilometer.conf ${SETUPDIR}/mod-comp-ceilometer.conf

#
# To configure notifications
#
cat <<EOF | tee ${SETUPDIR}/mod-comp-nova.conf.ceilometer
[DEFAULT]
instance_usage_audit = True
instance_usage_audit_period = hour
notify_on_state_change = vm_and_task_state
notification_driver = messagingv2
EOF
modify_inifile /etc/nova/nova.conf ${SETUPDIR}/mod-comp-nova.conf.ceilometer

#
# To finalize installation
#
systemctl enable openstack-ceilometer-compute.service
systemctl start openstack-ceilometer-compute.service

systemctl restart openstack-nova-compute.service

# -------------------------------------------------------------
touch $donefile
exit 0
