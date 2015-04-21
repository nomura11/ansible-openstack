#!/bin/bash

donefile=/root/netinit-done

if [ -e $donefile ]; then
	exit 0
fi

echo "NM_CONTROLLED=no" >> /etc/sysconfig/network-scripts/ifcfg-eth0
if (which systemctl); then
	systemctl stop NetworkManager.service && \
	systemctl disable NetworkManager.service && \
	systemctl enable network.service && \
	systemctl restart network.service
else
	chkconfig NetworkManager off && \
	service NetworkManager stop && \
	service network start && \
	chkconfig network on
fi

touch $donefile
