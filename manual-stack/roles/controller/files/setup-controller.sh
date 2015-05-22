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
PWDFILE=${SETUPDIR}/pass.txt
OPENRC=${SETUPDIR}/openrc.sh
export PATH=${SETUPDIR}:$PATH

donefile="${SETUPDIR}/controller.done"
logfile="${SETUPDIR}/controller.log"
exec 3>/dev/stdout >> $logfile 2>&1
if [ -e "$donefile" ]; then
	exit 0
fi

function create_database {
	local name=$1
	local pass=$2

	if [ "$name" = "" ] || [ "$pass" = "" ]; then
		echo "No username/password given."
		exit 1
	fi

	cat <<EOF | tee >(mysql --user=root --password=${DBROOTPASS})
CREATE DATABASE ${name};
GRANT ALL PRIVILEGES ON ${name}.* TO '${name}'@'localhost' IDENTIFIED BY '${pass}';
GRANT ALL PRIVILEGES ON ${name}.* TO '${name}'@'%' IDENTIFIED BY '${pass}';
EOF
}

function service_create {
	local config=$1

	if [ ! -e $config ]; then
		echo "$config not exist"
		exit 1
	fi

	. ${OPENRC}

	echo "Reading config file: $config"
	. $config
	if [ "$SERVICE_EMAIL" ]; then
		keystone user-create --name=${SERVICE_NAME} --pass=${SERVICE_PASS} --email=${SERVICE_EMAIL}
		keystone user-role-add --user=${SERVICE_NAME} --tenant=service --role=admin
		keystone user-get ${SERVICE_NAME}
	fi
	keystone service-create --name=${SERVICE_NAME} --type=${SERVICE_TYPE} --description="${SERVICE_DESCRIPTION}"
	SID=$(keystone service-list | awk "\$4 == \"${SERVICE_NAME}\" {print \$2}")
	if [ -z "$SID" ]; then
		echo "Service ID cannot determined"
		exit 1
	fi
	keystone endpoint-create --service-id=${SID} --publicurl=${SERVICE_URL_PUBLIC} --internalurl=${SERVICE_URL_INTERNAL} --adminurl=${SERVICE_URL_ADMIN}

	keystone service-get ${SERVICE_NAME}
	if [ $? -ne 0 ]; then
		echo "Failed to create service: $SERVICE_NAME"
		exit 1
	fi

	#
	keystone user-list
	keystone service-list
	keystone endpoint-list
}

# -------------------------------------------------------------
#
# Passwords
#
if [ ! -e ${PWDFILE} ]; then
	echo "Generating password file"
	pwnames='
	RABBIT_PASS
	KEYSTONE_DBPASS
	ADMIN_PASS
	ADMIN_TOKEN
	GLANCE_DBPASS
	GLANCE_PASS
	NOVA_DBPASS
	NOVA_PASS
	DASH_DBPASS
	CINDER_DBPASS
	CINDER_PASS
	NEUTRON_DBPASS
	NEUTRON_PASS
	HEAT_DBPASS
	HEAT_PASS
	CEILOMETER_DBPASS
	CEILOMETER_PASS
	'
	for n in $pwnames; do
		echo "$n=$(openssl rand -hex 10)"
	done | tee ${PWDFILE}
fi
. ${PWDFILE}
if [ -z "${ADMIN_PASS}" ]; then
	echo "ADMIN_PASS is not set"
	exit 1
fi

#
# openrc
#
cat <<EOF | tee ${OPENRC}
export OS_USERNAME=admin
export OS_PASSWORD=${ADMIN_PASS}
export OS_TENANT_NAME=admin
export OS_AUTH_URL=http://${CONTROLLER_HOSTNAME}:35357/v2.0
EOF
. ${OPENRC}
if [ -z "${OS_PASSWORD}" -o "${OS_PASSWORD}" != "${ADMIN_PASS}" ]; then
	echo "OS_PASSWORD is not correct: ${OS_PASSWORD}"
	exit 1
fi

# -------------------------------------------------------------
#
# MySQL
#
yum install -q -y mariadb mariadb-server MySQL-python || exit 1
cat <<EOF | tee ${SETUPDIR}/mod-my.cnf
[mysqld]
bind-address = ${CONTROLLER_IP_ADDR}
default-storage-engine = innodb
innodb_file_per_table
collation-server = utf8_general_ci
init-connect = 'SET NAMES utf8'
character-set-server = utf8
EOF
modify_inifile /etc/my.cnf ${SETUPDIR}/mod-my.cnf
systemctl enable mariadb.service
systemctl start mariadb.service
# FIXME: why
sleep 5
mysqladmin -u root password ${DBROOTPASS}
#mysql_secure_installation 
cat <<EOF | tee >(mysql --user=root --password=${DBROOTPASS})
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%';
FLUSH PRIVILEGES;
EOF

# -------------------------------------------------------------
#
# RabbitMQ
#
yum install -q -y rabbitmq-server || exit 1
systemctl enable rabbitmq-server.service
systemctl start rabbitmq-server.service
rabbitmqctl change_password guest $RABBIT_PASS

# -------------------------------------------------------------
#
# Keystone
#

create_database keystone ${KEYSTONE_DBPASS}
yum install -q -y openstack-keystone python-keystoneclient || exit 1
cat <<EOF | tee ${SETUPDIR}/mod-keystone.conf
[DEFAULT]
admin_token = ${ADMIN_TOKEN}
log_dir = /var/log/keystone
[database]
connection = mysql://keystone:${KEYSTONE_DBPASS}@${CONTROLLER_HOSTNAME}/keystone
[token]
provider = keystone.token.providers.uuid.Provider
driver = keystone.token.persistence.backends.sql.Token
[revoke]
driver = keystone.contrib.revoke.backends.sql.Revoke
EOF
modify_inifile /etc/keystone/keystone.conf ${SETUPDIR}/mod-keystone.conf
keystone-manage pki_setup --keystone-user keystone --keystone-group keystone
chown -R keystone:keystone /var/log/keystone
chown -R keystone:keystone /etc/keystone/ssl
chmod -R o-rwx /etc/keystone/ssl
su -s /bin/sh -c "keystone-manage db_sync" keystone
systemctl enable openstack-keystone.service
systemctl start openstack-keystone.service
# FIXME: why
sleep 5
rm -f /var/lib/keystone/keystone.db

(crontab -l -u keystone 2>&1 | grep -q token_flush) || \
 echo '@hourly /usr/bin/keystone-manage token_flush >/var/log/keystone/keystone-tokenflush.log 2>&1' >> /var/spool/cron/keystone

#
# - Create tenants, users, and roles
# - Create the service entity and API endpoint
# - Verify operation
#

export OS_SERVICE_TOKEN=${ADMIN_TOKEN}
export OS_SERVICE_ENDPOINT=http://${CONTROLLER_HOSTNAME}:35357/v2.0

# Admin
keystone tenant-create --name=admin --description="Admin Tenant"
if ! (keystone tenant-list | grep admin); then
	echo "Failed to create tenant: admin"
	exit 1
fi
keystone user-create --name=admin --pass=$ADMIN_PASS --email=admin@localhost
keystone role-create --name=admin
keystone user-role-add --user=admin --tenant=admin --role=admin
keystone user-role-add --user=admin --tenant=admin --role=_member_

# Demo
keystone tenant-create --name=demo --description="Demo Tenant"
if ! (keystone tenant-list | grep demo); then
	echo "Failed to create tenant: demo"
	exit 1
fi
keystone user-create --name=demo --tenant=demo --pass=$DEMO_PASS --email=demo@localhost

# Service
keystone tenant-create --name=service --description="Service Tenant"
if ! (keystone tenant-list | grep service); then
	echo "Failed to create tenant: service"
	exit 1
fi

# Endpoints
service_create ${SETUPDIR}/service-def-keystone.sh
unset OS_SERVICE_ENDPOINT
unset OS_SERVICE_TOKEN

# Test
keystone --os-username=admin --os-password=$ADMIN_PASS --os-auth-url=http://${CONTROLLER_HOSTNAME}:35357/v2.0 token-get || exit 1
keystone --os-username=admin --os-password=$ADMIN_PASS --os-tenant-name=admin --os-auth-url=http://${CONTROLLER_HOSTNAME}:35357/v2.0 token-get || exit 1
keystone --os-username=demo --os-password=$DEMO_PASS --os-tenant-name=demo --os-auth-url=http://${CONTROLLER_HOSTNAME}:5000/v2.0 token-get || exit 1
. ${OPENRC}
keystone token-get || exit 1
keystone user-list || exit 1

# -------------------------------------------------------------
#
# Clients
#
yum install -q -y python-novaclient python-ceilometerclient python-cinderclient python-glanceclient python-heatclient python-keystoneclient python-neutronclient || exit 1

# -------------------------------------------------------------
#
# Glance
#

create_database glance ${GLANCE_DBPASS}
service_create ${SETUPDIR}/service-def-glance.sh

yum install -q -y openstack-glance python-glanceclient || exit 1
cat <<EOF | tee ${SETUPDIR}/mod-glance.conf
[DEFAULT]
rpc_backend = rabbit
rabbit_host = ${CONTROLLER_HOSTNAME}
rabbit_password = ${RABBIT_PASS}
notification_driver = noop
[database]
connection = mysql://glance:${GLANCE_DBPASS}@${CONTROLLER_HOSTNAME}/glance
EOF
modify_inifile /etc/glance/glance-api.conf ${SETUPDIR}/mod-glance.conf
modify_inifile /etc/glance/glance-registry.conf ${SETUPDIR}/mod-glance.conf

cat <<EOF | tee ${SETUPDIR}/mod-glance-auth.conf
[keystone_authtoken]
auth_uri = http://${CONTROLLER_HOSTNAME}:5000/v2.0
identity_uri = http://${CONTROLLER_HOSTNAME}:35357
admin_tenant_name = service
admin_user = glance
admin_password = ${GLANCE_PASS}
[paste_deploy]
flavor = keystone
EOF
modify_inifile /etc/glance/glance-api.conf ${SETUPDIR}/mod-glance-auth.conf
modify_inifile /etc/glance/glance-registry.conf ${SETUPDIR}/mod-glance-auth.conf

cat <<EOF | tee ${SETUPDIR}/mod-glance-store.conf
[glance_store]
default_store = file
filesystem_store_datadir = /var/lib/glance/images/
EOF
modify_inifile /etc/glance/glance-api.conf ${SETUPDIR}/mod-glance-auth.conf

su -s /bin/sh -c "glance-manage db_sync" glance

systemctl enable openstack-glance-api.service openstack-glance-registry.service
systemctl start openstack-glance-api.service openstack-glance-registry.service

# FIXME: why
sleep 5
rm -f /var/lib/glance/glance.sqlite

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
[DEFAULT]
rpc_backend = rabbit
rabbit_host = ${CONTROLLER_HOSTNAME}
rabbit_password = ${RABBIT_PASS}
my_ip=${CONTROLLER_IP_ADDR}
vncserver_listen=${CONTROLLER_IP_ADDR}
vncserver_proxyclient_address=${CONTROLLER_IP_ADDR}
auth_strategy=keystone
[database]
connection = mysql://nova:${NOVA_DBPASS}@${CONTROLLER_HOSTNAME}/nova
[keystone_authtoken]
auth_uri = http://${CONTROLLER_HOSTNAME}:5000/v2.0
identity_uri = http://${CONTROLLER_HOSTNAME}:35357
admin_tenant_name = service
admin_user = nova
admin_password = ${NOVA_PASS}
[osapi_v3]
enabled = True
[glance]
host = ${CONTROLLER_HOSTNAME}
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

## Disable for now (nova-network)
if [ 1 -eq 0 ]; then
# -------------------------------------------------------------
#
# nova-network
#
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
#
# Cinder
#

create_database cinder ${CINDER_DBPASS}
service_create ${SETUPDIR}/service-def-cinder-v1.sh
service_create ${SETUPDIR}/service-def-cinder-v2.sh

yum install -q -y openstack-cinder python-cinderclient python-oslo-db || exit 1

cat <<EOF | tee ${SETUPDIR}/mod-cinder.conf
[DEFAULT]
rpc_backend = rabbit
rabbit_host = ${CONTROLLER_HOSTNAME}
#rabbit_port = 5672
#rabbit_userid = guest
rabbit_password = ${RABBIT_PASS}
auth_strategy = keystone
my_ip = ${CONTROLLER_IP_ADDR}
[database]
connection = mysql://cinder:${CINDER_DBPASS}@${CONTROLLER_HOSTNAME}/cinder
[keystone_authtoken]
auth_uri = http://${CONTROLLER_HOSTNAME}:5000/v2.0
identity_uri = http://${CONTROLLER_HOSTNAME}:35357
admin_tenant_name=service
admin_user=cinder
admin_password=${CINDER_PASS}
EOF
modify_inifile /etc/cinder/cinder.conf ${SETUPDIR}/mod-cinder.conf

su -s /bin/sh -c "cinder-manage db sync" cinder

systemctl enable openstack-cinder-api.service openstack-cinder-scheduler.service
systemctl start openstack-cinder-api.service openstack-cinder-scheduler.service

# FIXME: why
sleep 5
rm -f /var/lib/cinder/cinder.sqlite 

# -------------------------------------------------------------
#
# Ceilometer
#

yum install -q -y mongodb-server mongodb || exit 1

if [ -e /etc/mongodb.conf ]; then
	mongoconf=/etc/mongodb.conf
elif [ -e /etc/mongod.conf ]; then
	mongoconf=/etc/mongod.conf
else
	exit 1
fi

# Edit /etc/mongodb.conf
# bind_ip = 10.0.0.11
sed -i "s/^bind_ip *=.*\$/bind_ip = ${CONTROLLER_IP_ADDR}/" $mongoconf

# By default, MongoDB creates several 1 GB journal files in the
# /var/lib/mongodb/journal directory. If you want to reduce the size
# of each journal file to 128 MB and limit total journal space consumption
# to 512 MB, assert the smallfiles key:
if ! (grep -q '^smallfiles.*=.*true' $mongoconf); then
	echo "smallfiles = true" >> $mongoconf
fi

systemctl enable mongod.service
systemctl start mongod.service

sleep 3
mongo --host ${CONTROLLER_HOSTNAME} --eval "
db = db.getSiblingDB(\"ceilometer\");
db.addUser({user: \"ceilometer\",
            pwd: \"${CEILOMETER_DBPASS}\",
            roles: [ \"readWrite\", \"dbAdmin\" ]})"

service_create ${SETUPDIR}/service-def-ceilometer.sh

yum install -q -y openstack-ceilometer-api openstack-ceilometer-collector \
  openstack-ceilometer-notification openstack-ceilometer-central \
  openstack-ceilometer-alarm python-ceilometerclient || exit 1

cat <<EOF | tee ${SETUPDIR}/mod-ceilometer.conf
[DEFAULT]
rabbit_host = ${CONTROLLER_HOSTNAME}
rabbit_password = ${RABBIT_PASS}
log_dir = /var/log/ceilometer
auth_strategy = keystone
[database]
connection = mongodb://ceilometer:${CEILOMETER_DBPASS}@${CONTROLLER_HOSTNAME}:27017/ceilometer
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
EOF
modify_inifile /etc/ceilometer/ceilometer.conf ${SETUPDIR}/mod-ceilometer.conf

systemctl enable openstack-ceilometer-api.service \
                 openstack-ceilometer-notification.service \
                 openstack-ceilometer-central.service \
                 openstack-ceilometer-collector.service \
                 openstack-ceilometer-alarm-evaluator.service \
                 openstack-ceilometer-alarm-notifier.service
systemctl start  openstack-ceilometer-api.service \
                 openstack-ceilometer-notification.service \
                 openstack-ceilometer-central.service \
                 openstack-ceilometer-collector.service \
                 openstack-ceilometer-alarm-evaluator.service \
                 openstack-ceilometer-alarm-notifier.service

# Glance
cat <<EOF | tee ${SETUPDIR}/mod-glance.conf.ceilometer
[DEFAULT]
notification_driver = messaging
rpc_backend = rabbit
rabbit_host = ${CONTROLLER_HOSTNAME}
rabbit_password = ${RABBIT_PASS}
EOF
modify_inifile /etc/glance/glance-api.conf ${SETUPDIR}/mod-glance.conf.ceilometer
systemctl restart openstack-glance-api.service openstack-glance-registry.service

# Cinder
cat <<EOF | tee ${SETUPDIR}/mod-cinder.conf.ceilometer
[DEFAULT]
control_exchange = cinder
notification_driver = cinder.openstack.common.notifier.rpc_notifier
EOF
modify_inifile /etc/cinder/cinder.conf ${SETUPDIR}/mod-cinder.conf.ceilometer
systemctl restart openstack-cinder-api.service openstack-cinder-scheduler.service

#fi
# Disabled for now

# -------------------------------------------------------------
#
# Neutron
#

create_database neutron ${NEUTRON_DBPASS}
service_create ${SETUPDIR}/service-def-neutron.sh

yum install -q -y openstack-neutron openstack-neutron-ml2 python-neutronclient which || exit 1

service_tenant_id=$(keystone tenant-get service | awk '$2 == "id" { print $4 }')
cat <<EOF | tee ${SETUPDIR}/mod-neutron.conf
[DEFAULT]
rpc_backend = rabbit
rabbit_host = ${CONTROLLER_HOSTNAME}
rabbit_password = ${RABBIT_PASS}
auth_strategy = keystone
core_plugin = ml2
service_plugins = router
allow_overlapping_ips = True
notify_nova_on_port_status_changes = True
notify_nova_on_port_data_changes = True
nova_url = http://${CONTROLLER_HOSTNAME}:8774/v2
nova_admin_auth_url = http://${CONTROLLER_HOSTNAME}:35357/v2.0
nova_region_name = regionOne
nova_admin_username = nova
nova_admin_tenant_id = ${service_tenant_id}
nova_admin_password = ${NOVA_PASS}
#control_exchange = neutron
#notification_driver = neutron.openstack.common.notifier.rabbit_notifier
[keystone_authtoken]
auth_uri = http://${CONTROLLER_HOSTNAME}:5000/v2.0
identity_uri = http://${CONTROLLER_HOSTNAME}:35357
admin_tenant_name = service
admin_user = neutron
admin_password = ${NEUTRON_PASS}
[database]
connection = mysql://neutron:${NEUTRON_DBPASS}@${CONTROLLER_HOSTNAME}/neutron
EOF
modify_inifile /etc/neutron/neutron.conf ${SETUPDIR}/mod-neutron.conf

#
# To configure the Modular Layer 2 (ML2) plug-in
#
cat <<EOF | tee ${SETUPDIR}/mod-ml2.conf.neutron
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
EOF
modify_inifile /etc/neutron/plugins/ml2/ml2_conf.ini ${SETUPDIR}/mod-ml2.conf.neutron

#
# To configure Compute to use Networking
#
cat <<EOF | tee ${SETUPDIR}/mod-nova.conf.neutron
[DEFAULT]
network_api_class=nova.network.neutronv2.api.API
security_group_api=neutron
linuxnet_interface_driver = nova.network.linux_net.LinuxOVSInterfaceDriver
firewall_driver=nova.virt.firewall.NoopFirewallDriver
[neutron]
url=http://${CONTROLLER_HOSTNAME}:9696
auth_strategy=keystone
admin_auth_url=http://${CONTROLLER_HOSTNAME}:35357/v2.0
admin_tenant_name=service
admin_username=neutron
admin_password=${NEUTRON_PASS}
service_metadata_proxy = True
metadata_proxy_shared_secret = ${NEUTRON_SHARED_SECRET}
EOF
modify_inifile /etc/nova/nova.conf ${SETUPDIR}/mod-nova.conf.neutron

#
# To finalize installation
#
ln -s /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugin.ini
su -s /bin/sh -c "neutron-db-manage --config-file /etc/neutron/neutron.conf \
  --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade juno" neutron
systemctl restart openstack-nova-api.service openstack-nova-scheduler.service \
  openstack-nova-conductor.service
systemctl enable neutron-server.service
systemctl start neutron-server.service

touch $donefile
exit 0
