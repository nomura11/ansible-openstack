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

donefile="${SETUPDIR}/controller-ceilometer.done"
logfile="${SETUPDIR}/controller-ceilometer.log"
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
# Ceilometer
#

yum install -q -y mongodb-server mongodb || exit 1

if [ -e /etc/mongodb.conf ]; then
	mongoconf=/etc/mongodb.conf
elif [ -e /etc/mongod.conf ]; then
	mongoconf=/etc/mongod.conf
else
	echo "Could not find mongodb conf"
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
db.createUser({user: \"ceilometer\",
            pwd: \"${CEILOMETER_DBPASS}\",
            roles: [ \"readWrite\", \"dbAdmin\" ]})"

service_create ${SETUPDIR}/service-def-ceilometer.sh

yum install -q -y openstack-ceilometer-api \
  openstack-ceilometer-collector openstack-ceilometer-notification \
  openstack-ceilometer-central openstack-ceilometer-alarm \
  python-ceilometerclient || exit 1

cat <<EOF | tee ${SETUPDIR}/mod-ceilometer.conf
[database]
connection = mongodb://ceilometer:${CEILOMETER_DBPASS}@${CONTROLLER_HOSTNAME}:27017/ceilometer
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
username = ceilometer
password = ${CEILOMETER_PASS}
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
notification_driver = messagingv2
rpc_backend = rabbit
[oslo_messaging_rabbit]
rabbit_host = ${CONTROLLER_HOSTNAME}
rabbit_userid = openstack
rabbit_password = ${RABBIT_PASS}
EOF
modify_inifile /etc/glance/glance-api.conf ${SETUPDIR}/mod-glance.conf.ceilometer
systemctl restart openstack-glance-api.service openstack-glance-registry.service

# Cinder
cat <<EOF | tee ${SETUPDIR}/mod-cinder.conf.ceilometer
[DEFAULT]
notification_driver = messagingv2
EOF
modify_inifile /etc/cinder/cinder.conf ${SETUPDIR}/mod-cinder.conf.ceilometer
systemctl restart openstack-cinder-api.service openstack-cinder-scheduler.service

# -------------------------------------------------------------
# Done
touch $donefile
exit 0
