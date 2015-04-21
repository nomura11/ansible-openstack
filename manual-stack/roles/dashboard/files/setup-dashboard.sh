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
fi

donefile="${SETUPDIR}/dashboard.done"
logfile="${SETUPDIR}/dashboard.log"
exec 3>/dev/stdout >> $logfile 2>&1
if [ -e "$donefile" ]; then
	exit 0
fi

#
# To install the dashboard components
#
yum install -q -y openstack-dashboard httpd mod_wsgi memcached python-memcached || exit 1

#
# To configure the dashboard
#
config=/etc/openstack-dashboard/local_settings
orig=${config}.orig
if [ -e $config ] && [ ! -e $orig ] && cp -a $config $orig; then
	cat $orig | \
	sed "s/^OPENSTACK_HOST = .*/OPENSTACK_HOST = \"${CONTROLLER_HOSTNAME}\"/" | \
	sed "s/^ALLOWED_HOSTS = .*/ALLOWED_HOSTS = ['*']/" | \
	sed "s/'BACKEND': 'django.core.cache.backends.locmem.LocMemCache'/'BACKEND': 'django.core.cache.backends.memcached.MemcachedCache',\n		'LOCATION': '127.0.0.1:11211',/" > $config
	diff -u $orig $config
fi

#
# To finalize installation
#
# 1.
setsebool -P httpd_can_network_connect on
# 2.
chown -R apache:apache /usr/share/openstack-dashboard/static
# 3.
systemctl enable httpd.service memcached.service
systemctl start httpd.service memcached.service

touch $donefile
exit 0
