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

donefile="${SETUPDIR}/controller-keystone.done"
logfile="${SETUPDIR}/controller-keystone.log"
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
# Keystone
#

create_database keystone ${KEYSTONE_DBPASS}
yum install -q -y openstack-keystone python-keystoneclient || exit 1
cat <<EOF | tee ${SETUPDIR}/mod-keystone.conf
[DEFAULT]
admin_token = ${ADMIN_TOKEN}
...
[database]
connection = mysql://keystone:${KEYSTONE_DBPASS}@${CONTROLLER_HOSTNAME}/keystone
...
[token]
provider = keystone.token.providers.uuid.Provider
driver = keystone.token.persistence.backends.sql.Token
...
[revoke]
driver = keystone.contrib.revoke.backends.sql.Revoke
...
[DEFAULT]
log_dir = /var/log/keystone
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
# Done
touch $donefile
exit 0
