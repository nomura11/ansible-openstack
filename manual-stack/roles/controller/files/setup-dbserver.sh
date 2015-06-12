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
export PATH=${SETUPDIR}:$PATH

donefile="${SETUPDIR}/controller-dbserver.done"
logfile="${SETUPDIR}/controller-dbserver.log"
exec 3>/dev/stdout >> $logfile 2>&1
if [ -e "$donefile" ]; then
	exit 0
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
# Done
touch $donefile
exit 0
