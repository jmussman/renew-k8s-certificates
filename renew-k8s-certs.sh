#!/bin/bash
#
# renew-k8s-certs
# Copyright (c) 2024 Joel A Mussman. All rights reserved.
#
# This script is released under the MIT license (https://opensource.org/license/mit) and
# may be copied, used, and altered as long as attribution is provided. This software is
# provided "as-is" without warranty. It should be tested by the user before running in
# production.
#
# This script handles the renewal of the self-signed certificates used by Kubernetes to
# authenticate and authorize the nodes and the admin user. This script is based on the blog post at
# https://medium.com/@sunilmalik12012/renew-expired-k8s-cluster-certificates-manually-e591ffa4dc6d,
# written by Sunil Malik.
#
# This script has been tested on Kubernetes 1.23 and 1.28 clusters.
#
# Change the mode of this script to executable and run in in bash; commands requiring elevated
# privileges will use sudo during the execution of the script.
#
# crictl requires a runtime-endpoint now, the defaults have been deprecated. The bulk of
# this script is to determine what the appropriate runtime-endpoint is.
#
# The script executes these steps:
#
#   1. Determine the runtime-endpoint.
#   2. Renew the certificates.
#   3. Print out the certificate expiration for a visual check.
#   4. Copy the new /etc/kubernetes/admin.conf file to ~/.kube/config
#   5. Restart the necessary containers: kube-apiserver, kube-scheduler, kube-controller-manager, etcd.
#   6. Check the status of the pods to see if they are restarted.
#   7. Check the status of the nodes to see if the workers are ready.
#
# There is no requirement to touch the other nodes, unless you are using them to issue commands
# against the API (really bad idea), but copy the admin.conf file if you feel it is necessary.
#

containers=('kube-apiserver' 'kube-scheduler' 'kube-controller-manager' 'etcd')
criEndpoint=unix:///run/containerd/containerd.sock
dockerShimEndpoint=unix:///var/run/dockershim.sock
majorCutoff=1
minorCutoff=23
option='--container-runtime-endpoint'

# Is Kubernetes installed?

if [[ -z $(which crictl) || -z $(which kubeadm) || -z $(which kubectl) ]]; then

	echo "Commands are missing, Kubernetes does not appear to be installed."

	exit 1
fi

#
# The hard part is figuring out which container runtime endpoint to use
# with the crictl command. <= 1.23, check the kublet command line for the
# --container-runtime-endpoint option. If it isn't there and and <= 1.23
# then it is the Docker shim. Otherwise, it is the CRI endpoint.
#

echo "Determining runtime-endpoint"

# Find the kubelet command line, look for the option and value.

kcl=$(ps --no-headers -fp $(pgrep kubelet))

if [[ -z $kcl || -z $(echo $kcl | grep '$option') ]]; then

	# No option on the kubelet command line. There is a gotcha here: the kubelet may not
	# be running because of an expired certificate. We have to assume that the version of
	# Kubernetes drives the endpoint.

	# Note: this was using "kubectl version | grep Server", but the output changes from 1.23
	# to 1.28. "kubeadm version" produces similar output and is the same in both versions.

	kv=$(kubeadm version)
	major=$(echo $kv | sed -e 's/^.*Major:"\([[:digit:]]*\).*$/\1/g')
	minor=$(echo $kv | sed -e 's/^.*Minor:"\([[:digit:]]*\).*$/\1/g')

	# Produce the endpoint based on the version detected.

	if (( $major > $majorCutoff || ($major == $majorCutoff && $minor > $minorCutoff ))); then

		echo "Installed Kubernetes > 1.23, using the CRI endpoint for crictl: $criEndpoint"

		cre=$criEndpoint

	else

		echo "Installed Kubernetes <= 1.23, using the Docker shim endpoint for crictl: $dockerShimEndpoint"

		cre=$dockerShimEndpoint
	fi
else

	# Use the endpoint specified by the running kublet command.

	cre=$(echo $kcl | sed -e "s/^.*${option}=\([^ ]*\).*$/\1/g")

	echo "Using the endpoint defined when starting kublet for crictl: $cre"
fi

#
# Replace the certificates.
#

echo
echo "Renewing certificates; you may be prompted for a password by sudo:"

sudo kubeadm certs renew all
sudo kubeadm certs check-expiration

#
# Copy the configuration to the user folder.
#

echo
echo "Copying new /etc/kubernetes/admin.conf to ~/.kube/config"

sudo cp /etc/kubernetes/admin.conf ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config
ls -l /etc/kubernetes/admin.conf ~/.kube/config

#
# Restart the Kubernetes system containers.
#

echo
echo "Restarting system containers:"

containerIds=()

for container in ${containers[@]}; do

	containerId=$(sudo crictl --runtime-endpoint $cre ps | grep $container | awk '{print $1}')
	containerIds=(${containerIds[@]} "$container:$containerId") 
done

for container in ${containerIds[@]}; do

	containerName=${container%%:*}
	containerId=${container#*:}

	echo " - Container $containerName ($containerId)"

 	sudo crictl --runtime-endpoint $cre stop $containerId > /dev/null
done

#
# Loop waiting for the services to restart; experiance says it may take up to 60 seconds to restart
# but the logic is here to way for kubectl to achieve a connection (the connection error is printed
# each interation).
#

echo

while [[ true ]]; do

	result=$(kubectl get pods --all-namespaces 2>&1)
	
	if [[ -z $(echo $result | grep "The connection to the server") ]]; then

		break
	fi

	echo $result
	echo "Waiting 15 seconds for API restart..."

	sleep 15
done

#
# Show the pod and node status.
#

echo
echo "Checking pod status:"

kubectl get pods --all-namespaces

echo
echo "Checking node status:"

kubectl get nodes

echo
echo "Finished."
