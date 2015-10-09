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

donefile="${SETUPDIR}/controller-heat.done"
logfile="${SETUPDIR}/controller-heat.log"
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
# Heat
#

create_database heat ${HEAT_DBPASS}
service_create ${SETUPDIR}/service-def-heat.sh
service_create ${SETUPDIR}/service-def-heat-cfn.sh
openstack role create heat_stack_owner
openstack role create heat_stack_user
#
#openstack role add --project demo --user demo heat_stack_owner
openstack role add --project admin --user admin heat_stack_owner

# 1., 2.
yum install -q -y openstack-heat-api openstack-heat-api-cfn openstack-heat-engine python-heatclient || exit 1
cp /usr/share/heat/heat-dist.conf /etc/heat/heat.conf
chown -R heat:heat /etc/heat/heat.conf

cat <<EOF | tee ${SETUPDIR}/mod-heat.conf
[database]
connection = mysql://heat:${HEAT_DBPASS}@${CONTROLLER_HOSTNAME}/heat
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
admin_user = heat
admin_password = ${HEAT_PASS}
[ec2authtoken]
auth_uri = http://${CONTROLLER_HOSTNAME}:5000/v2.0
...
[DEFAULT]
heat_metadata_server_url = http://${CONTROLLER_HOSTNAME}:8000
heat_waitcondition_server_url = http://${CONTROLLER_HOSTNAME}:8000/v1/waitcondition
...
[DEFAULT]
stack_domain_admin = heat_domain_admin
stack_domain_admin_password = ${HEAT_DOMAIN_PASS}
stack_user_domain_name = heat_user_domain
...
EOF
modify_inifile /etc/heat/heat.conf ${SETUPDIR}/mod-heat.conf
sed -i -e 's/^sql_connection/#sql_connection/' -e 's/^db_backend/#db_backend/' /etc/heat/heat.conf

# 3.
heat-keystone-setup-domain \
  --stack-user-domain-name heat_user_domain \
  --stack-domain-admin heat_domain_admin \
  --stack-domain-admin-password ${HEAT_DOMAIN_PASS}

# 4.
su -s /bin/sh -c "heat-manage db_sync" heat

# To finalize installation
systemctl enable openstack-heat-api.service openstack-heat-api-cfn.service \
  openstack-heat-engine.service
systemctl start openstack-heat-api.service openstack-heat-api-cfn.service \
  openstack-heat-engine.service

# -------------------------------------------------------------
# Done
touch $donefile
exit 0
