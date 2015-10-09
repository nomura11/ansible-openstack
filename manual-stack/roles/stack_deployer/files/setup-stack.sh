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
fi

# Network parameters (Neutron)
if [ -z "$EXTNET_NAME" ]; then
	echo "EXTNET_NAME not defined"
	exit 1
elif [ -z "$ADMINNET_NAME" ]; then
	echo "ADMINNET_NAME not defined"
	exit 1
elif [ -z "$EXTNET_START" ]; then
	echo "EXTNET_START not defined"
	exit 1
elif [ -z "$EXTNET_END" ]; then
	echo "EXTNET_END not defined"
	exit 1
elif [ -z "$EXTNET_GW" ]; then
	echo "EXTNET_GW not defined"
	exit 1
elif [ -z "$EXTNET_CIDR" ]; then
	echo "EXTNET_CIDR not defined"
	exit 1
elif [ -z "$ADMINNET_GW" ]; then
	echo "ADMINNET_GW not defined"
	exit 1
elif [ -z "$ADMINNET_CIDR" ]; then
	echo "ADMINNET_CIDR not defined"
	exit 1
fi

# -------------------------------------------------------------
OPENRC=${SETUPDIR}/openrc.sh
export PATH=${SETUPDIR}:$PATH

donefile="${SETUPDIR}/deployer.done"
logfile="${SETUPDIR}/deployer.log"
exec 3>/dev/stdout >> $logfile 2>&1
if [ -e "$donefile" ]; then
	exit 0
fi

# -------------------------------------------------------------
#
# openrc
#
if [ ! -e ${OPENRC} ]; then
	echo "openrc ($OPENRC) not exist"
	exit 1
fi
. ${OPENRC}
if [ -z "${OS_PASSWORD}" ]; then
	echo "OS_PASSWORD is not correct: ${OS_PASSWORD}"
	exit 1
fi

# -------------------------------------------------------------
#
# Nova/Glance Client
#
yum install -q -y python-novaclient python-ceilometerclient python-cinderclient python-glanceclient python-heatclient python-keystoneclient python-neutronclient || exit 1

# -------------------------------------------------------------
#
# Glance
#
for f in ${SETUPDIR}/*.{img,qcow2}; do
	if [ ! -e ${f} ]; then
		continue
	fi
	echo "Importing image: $f"

	# rip off directory prefix and suffix such as ".img" ".qcow2"
	iname="$(basename ${f%.*})"
	# guess the 1st word is distro name...
	iname="${iname%%-*}"

	if (file -b "$f" | grep -qi 'QEMU.*QCOW'); then
		iformat="qcow2"
	elif (file -b "$f" | grep -qi 'ISO 9660 CD-ROM'); then
		iformat="iso"
	elif (echo "$f" | grep -qi '.qcow2'); then
		iformat="qcow2"
	else
		echo "Unknown image type, assume 'raw'"
		iformat="raw"
	fi

	glance image-create \
		--name="${iname}" \
		--disk-format="${iformat}" \
		--container-format=bare \
		--is-public=true \
	< ${f}
done

# -------------------------------------------------------------
#
# Nova
#

# keypair
KEY_FILE=/root/.ssh/id_rsa.pub
KEY_NAME=adminkey
nova keypair-add --pub_key ${KEY_FILE} ${KEY_NAME}

# default secgroup
nova secgroup-add-rule default tcp 22 22 0.0.0.0/0
nova secgroup-add-rule default icmp -1 -1 0.0.0.0/0

# -------------------------------------------------------------
#
# Neutron Network
#

#
# External network
#

# To create the external network
neutron net-create ${EXTNET_NAME} \
	--router:external \
	--provider:physical_network external \
	--provider:network_type flat

# To create a subnet on the external network
neutron subnet-create --name ${EXTNET_SUBNET} \
	--allocation-pool start=${EXTNET_START},end=${EXTNET_END} \
	--disable-dhcp \
	--gateway ${EXTNET_GW} \
	${EXTNET_NAME} ${EXTNET_CIDR}

#
# Tenant network
#

# To create the tenant network
neutron net-create ${ADMINNET_NAME}

# To create a subnet on the tenant network
neutron subnet-create --name ${ADMINNET_SUBNET} \
	--gateway ${ADMINNET_GW} \
	${ADMINNET_NAME} ${ADMINNET_CIDR}

# To create a router on the tenant network and attach the external and tenant networks to it
neutron router-create ${ADMINNET_ROUTER}
neutron router-interface-add ${ADMINNET_ROUTER} ${ADMINNET_SUBNET}
neutron router-gateway-set ${ADMINNET_ROUTER} ${EXTNET_NAME}

# Create a floating-ip
neutron floatingip-create ${EXTNET_NAME}


# -------------------------------------------------------------
#
# Nova Network (FlatDHCP + multihost)
#
touch $donefile
exit 0

if (nova network-show ${ADMINNET_NAME}); then
	# already done
	exit 0
fi

tenant_id=$(keystone tenant-list | awk '$4 == "admin" { print $2 }')
nova network-create ${ADMINNET_NAME} \
	--fixed-range-v4=${ADMINNET_CIDR} \
	--project-id ${tenant_id} \
	--multi-host=T

# floating IP pool
nova floating-ip-bulk-create --pool "${EXTNET_NAME}" \
	--interface ${NETWORK_EXTERNAL_IF} \
	${EXTNET_CIDR}

# allocate 1 floating IP
nova floating-ip-create ${EXTNET_NAME}

# -------------------------------------------------------------

touch $donefile
exit 0

