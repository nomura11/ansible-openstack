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
yum install -q -y openstack-keystone python-openstackclient memcached python-memcached || exit 1

systemctl enable memcached.service
systemctl start memcached.service

cat <<EOF | tee ${SETUPDIR}/mod-keystone.conf
[DEFAULT]
admin_token = ${ADMIN_TOKEN}
log_dir = /var/log/keystone
[database]
connection = mysql://keystone:${KEYSTONE_DBPASS}@${CONTROLLER_HOSTNAME}/keystone
[memcache]
servers = localhost:11211
[token]
provider = uuid
driver = memcache
[revoke]
driver = sql
EOF
modify_inifile /etc/keystone/keystone.conf ${SETUPDIR}/mod-keystone.conf

su -s /bin/sh -c "keystone-manage db_sync" keystone

KEYSTONE_USE_WSGI=yes
if [ -n "${KEYSTONE_USE_WSGI}" ]; then
yum install -q -y httpd mod_wsgi || exit 1
cat <<EOF > /etc/httpd/conf.d/wsgi-keystone.conf
Listen 5000
Listen 35357

<VirtualHost *:5000>
    WSGIDaemonProcess keystone-public processes=5 threads=1 user=keystone group=keystone display-name=%{GROUP}
    WSGIProcessGroup keystone-public
    WSGIScriptAlias / /usr/bin/keystone-wsgi-public
    WSGIApplicationGroup %{GLOBAL}
    WSGIPassAuthorization On
    <IfVersion >= 2.4>
        ErrorLogFormat "%{cu}t %M"
    </IfVersion>
    ErrorLog /var/log/httpd/keystone-error.log
    CustomLog /var/log/httpd/keystone-access.log combined

    <Directory /usr/bin>
        <IfVersion >= 2.4>
            Require all granted
        </IfVersion>
        <IfVersion < 2.4>
            Order allow,deny
            Allow from all
        </IfVersion>
    </Directory>
</VirtualHost>

<VirtualHost *:35357>
    WSGIDaemonProcess keystone-admin processes=5 threads=1 user=keystone group=keystone display-name=%{GROUP}
    WSGIProcessGroup keystone-admin
    WSGIScriptAlias / /usr/bin/keystone-wsgi-admin
    WSGIApplicationGroup %{GLOBAL}
    WSGIPassAuthorization On
    <IfVersion >= 2.4>
        ErrorLogFormat "%{cu}t %M"
    </IfVersion>
    ErrorLog /var/log/httpd/keystone-error.log
    CustomLog /var/log/httpd/keystone-access.log combined

    <Directory /usr/bin>
        <IfVersion >= 2.4>
            Require all granted
        </IfVersion>
        <IfVersion < 2.4>
            Order allow,deny
            Allow from all
        </IfVersion>
    </Directory>
</VirtualHost>
EOF
systemctl enable httpd.service
systemctl start httpd.service
else
systemctl enable openstack-keystone.service
systemctl start openstack-keystone.service
fi

#
# - Create tenants, users, and roles
# - Create the service entity and API endpoint
# - Verify operation
#

export OS_TOKEN=${ADMIN_TOKEN}
export OS_URL=http://${CONTROLLER_HOSTNAME}:35357/v3
export OS_IDENTITY_API_VERSION=3

# Endpoints
service_create ${SETUPDIR}/service-def-keystone.sh

# Admin
openstack project create --domain default --description "Admin Project" admin
if ! (openstack project list | grep admin); then
	echo "Failed to create tenant: admin"
	exit 1
fi
openstack user create --domain default --password $ADMIN_PASS admin
openstack role create admin
openstack role add --project admin --user admin admin

# Service
openstack project create --domain default --description "Service Project" service
if ! (openstack project list | grep service); then
	echo "Failed to create tenant: service"
	exit 1
fi

# Demo
openstack project create --domain default --description "Demo Project" demo
if ! (openstack project list | grep demo); then
	echo "Failed to create tenant: demo"
	exit 1
fi
openstack user create --domain default --password $DEMO_PASS demo
openstack role create user
openstack role add --project demo --user demo user

unset OS_URL
unset OS_TOKEN

# Test
#keystone --os-username=admin --os-password=$ADMIN_PASS --os-auth-url=http://${CONTROLLER_HOSTNAME}:35357/v2.0 token-get || exit 1
#keystone --os-username=admin --os-password=$ADMIN_PASS --os-tenant-name=admin --os-auth-url=http://${CONTROLLER_HOSTNAME}:35357/v2.0 token-get || exit 1
#keystone --os-username=demo --os-password=$DEMO_PASS --os-tenant-name=demo --os-auth-url=http://${CONTROLLER_HOSTNAME}:5000/v2.0 token-get || exit 1
. ${OPENRC}
openstack token issue || exit 1
openstack user list || exit 1

# -------------------------------------------------------------
# Done
touch $donefile
exit 0
