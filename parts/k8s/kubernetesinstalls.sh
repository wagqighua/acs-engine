#!/bin/bash

function installEtcd() {
    retrycmd_get_tarball 60 10 /tmp/etcd-${ETCD_VERSION}-linux-amd64.tar.gz ${ETCD_DOWNLOAD_URL}/etcd-${ETCD_VERSION}-linux-amd64.tar.gz || exit $ERR_ETCD_DOWNLOAD_TIMEOUT
    tar xzvf /tmp/etcd-${ETCD_VERSION}-linux-amd64.tar.gz -C /usr/bin/ --strip-components=1
}

function installDeps() {
    retrycmd_if_failure_no_stats 20 1 5 curl -fsSL https://packages.microsoft.com/config/ubuntu/16.04/packages-microsoft-prod.deb > /tmp/packages-microsoft-prod.deb || exit $ERR_MS_PROD_DEB_DOWNLOAD_TIMEOUT
    retrycmd_if_failure 60 5 10 dpkg -i /tmp/packages-microsoft-prod.deb || exit $ERR_MS_PROD_DEB_PKG_ADD_FAIL
    apt_get_update || exit $ERR_APT_UPDATE_TIMEOUT
    # See https://github.com/kubernetes/kubernetes/blob/master/build/debian-hyperkube-base/Dockerfile#L25-L44
    apt_get_install 20 30 300 apt-transport-https ca-certificates iptables iproute2 ebtables socat util-linux mount ethtool init-system-helpers nfs-common ceph-common conntrack glusterfs-client ipset jq cgroup-lite git pigz xz-utils blobfuse fuse cifs-utils || exit $ERR_APT_INSTALL_TIMEOUT
}

function installFlexVolDrivers() {
    PLUGIN_DIR=/etc/kubernetes/volumeplugins
    # install blobfuse flexvolume driver
    BLOBFUSE_DIR=$PLUGIN_DIR/azure~blobfuse
    mkdir -p $BLOBFUSE_DIR
    retrycmd_if_failure_no_stats 20 1 30 curl -fsSL https://acs-mirror.azureedge.net/flexvol/blobfuse-v0.1 > $BLOBFUSE_DIR/blobfuse || exit $ERR_FLEXVOLUME_DOWNLOAD_TIMEOUT
    chmod a+x $BLOBFUSE_DIR/blobfuse
    # install smb flexvolume driver
    SMB_DIR=$PLUGIN_DIR/microsoft.com~smb
    mkdir -p $SMB_DIR
    retrycmd_if_failure_no_stats 20 1 30 curl -fsSL https://acs-mirror.azureedge.net/flexvol/smb-v0.1 > $SMB_DIR/smb || exit $ERR_FLEXVOLUME_DOWNLOAD_TIMEOUT
    chmod a+x $SMB_DIR/smb
}

function installDocker() {
    retrycmd_if_failure_no_stats 20 1 5 curl -fsSL https://aptdocker.azureedge.net/gpg > /tmp/aptdocker.gpg || exit $ERR_DOCKER_KEY_DOWNLOAD_TIMEOUT
    retrycmd_if_failure 10 5 10 apt-key add /tmp/aptdocker.gpg || exit $ERR_DOCKER_APT_KEY_TIMEOUT
    echo "deb ${DOCKER_REPO} ubuntu-xenial main" | sudo tee /etc/apt/sources.list.d/docker.list
    printf "Package: docker-engine\nPin: version ${DOCKER_ENGINE_VERSION}\nPin-Priority: 550\n" > /etc/apt/preferences.d/docker.pref
    apt_get_update || exit $ERR_APT_UPDATE_TIMEOUT
    apt_get_install 20 30 120 docker-engine || exit $ERR_DOCKER_INSTALL_TIMEOUT
    echo "ExecStartPost=/sbin/iptables -P FORWARD ACCEPT" >> /etc/systemd/system/docker.service.d/exec_start.conf
    usermod -aG docker ${ADMINUSER}
    touch /var/log/azure/docker-install.complete
}

function installNetworkPlugin() {
    if [[ "${NETWORK_PLUGIN}" = "azure" ]]; then
        installAzureCNI
    elif [[ "${NETWORK_PLUGIN}" = "kubenet" ]]; then
		installCNI
	elif [[ "${NETWORK_PLUGIN}" = "flannel" ]]; then
        installCNI
    fi
}

function installCNI() {
    mkdir -p $CNI_BIN_DIR
    CONTAINERNETWORKING_CNI_TGZ_TMP=/tmp/containernetworking_cni.tgz
    retrycmd_get_tarball 60 5 $CONTAINERNETWORKING_CNI_TGZ_TMP ${CNI_PLUGINS_URL} || exit $ERR_CNI_DOWNLOAD_TIMEOUT
    tar -xzf $CONTAINERNETWORKING_CNI_TGZ_TMP -C $CNI_BIN_DIR
    chown -R root:root $CNI_BIN_DIR
    chmod -R 755 $CNI_BIN_DIR
    # Turn on br_netfilter (needed for the iptables rules to work on bridges)
    # and permanently enable it
    retrycmd_if_failure 30 6 10 modprobe br_netfilter || exit $ERR_MODPROBE_FAIL
    # /etc/modules-load.d is the location used by systemd to load modules
    echo -n "br_netfilter" > /etc/modules-load.d/br_netfilter.conf
}

function installAzureCNI() {
    CNI_CONFIG_DIR=/etc/cni/net.d
    mkdir -p $CNI_CONFIG_DIR
    chown -R root:root $CNI_CONFIG_DIR
    chmod 755 $CNI_CONFIG_DIR
    mkdir -p $CNI_BIN_DIR
    AZURE_CNI_TGZ_TMP=/tmp/azure_cni.tgz
    retrycmd_get_tarball 60 5 $AZURE_CNI_TGZ_TMP ${VNET_CNI_PLUGINS_URL} || exit $ERR_CNI_DOWNLOAD_TIMEOUT
    tar -xzf $AZURE_CNI_TGZ_TMP -C $CNI_BIN_DIR
    installCNI
    mv $CNI_BIN_DIR/10-azure.conflist $CNI_CONFIG_DIR/
    chmod 600 $CNI_CONFIG_DIR/10-azure.conflist
    /sbin/ebtables -t nat --list
}

function installKataContainersRuntime() {
    # Add Kata Containers repository key
    echo "Adding Kata Containers repository key..."
    KATA_RELEASE_KEY_TMP=/tmp/kata-containers-release.key
    KATA_URL=http://download.opensuse.org/repositories/home:/katacontainers:/release/xUbuntu_16.04/Release.key
    retrycmd_if_failure_no_stats 20 1 5 curl -fsSL $KATA_URL > $KATA_RELEASE_KEY_TMP || exit $ERR_KATA_KEY_DOWNLOAD_TIMEOUT
    retrycmd_if_failure 10 5 10 apt-key add $KATA_RELEASE_KEY_TMP || exit $ERR_KATA_APT_KEY_TIMEOUT

    # Add Kata Container repository
    echo "Adding Kata Containers repository..."
    echo 'deb http://download.opensuse.org/repositories/home:/katacontainers:/release/xUbuntu_16.04/ /' > /etc/apt/sources.list.d/kata-containers.list

    # Install Kata Containers runtime
    echo "Installing Kata Containers runtime..."
    apt_get_update || exit $ERR_APT_UPDATE_TIMEOUT
    apt_get_install 20 30 120 kata-runtime || exit $ERR_KATA_INSTALL_TIMEOUT
}

function installClearContainersRuntime() {
	# Add Clear Containers repository key
	echo "Adding Clear Containers repository key..."
    CC_RELEASE_KEY_TMP=/tmp/clear-containers-release.key
    CC_URL=https://download.opensuse.org/repositories/home:clearcontainers:clear-containers-3/xUbuntu_16.04/Release.key
    retrycmd_if_failure_no_stats 20 1 5 curl -fsSL $CC_URL > $CC_RELEASE_KEY_TMP || exit $ERR_APT_INSTALL_TIMEOUT
    retrycmd_if_failure 10 5 10 apt-key add $CC_RELEASE_KEY_TMP || exit $ERR_APT_INSTALL_TIMEOUT

	# Add Clear Container repository
	echo "Adding Clear Containers repository..."
	echo 'deb http://download.opensuse.org/repositories/home:/clearcontainers:/clear-containers-3/xUbuntu_16.04/ /' > /etc/apt/sources.list.d/cc-runtime.list

	# Install Clear Containers runtime
	echo "Installing Clear Containers runtime..."
    apt_get_update
    apt_get_install 20 30 120 cc-runtime

	# Install the systemd service and socket files.
	local repo_uri="https://raw.githubusercontent.com/clearcontainers/proxy/3.0.23"
    CC_SERVICE_IN_TMP=/tmp/cc-proxy.service.in
    CC_SOCKET_IN_TMP=/tmp/cc-proxy.socket.in
    retrycmd_if_failure_no_stats 20 1 5 curl -fsSL "${repo_uri}/cc-proxy.service.in" > $CC_SERVICE_IN_TMP
    retrycmd_if_failure_no_stats 20 1 5 curl -fsSL "${repo_uri}/cc-proxy.socket.in" > $CC_SOCKET_IN_TMP
    cat $CC_SERVICE_IN_TMP | sed 's#@libexecdir@#/usr/libexec#' > /etc/systemd/system/cc-proxy.service
    cat $CC_SOCKET_IN_TMP sed 's#@localstatedir@#/var#' > /etc/systemd/system/cc-proxy.socket
}

function installContainerd() {
	CRI_CONTAINERD_VERSION="1.1.0"
	CONTAINERD_DOWNLOAD_URL="https://storage.googleapis.com/cri-containerd-release/cri-containerd-${CRI_CONTAINERD_VERSION}.linux-amd64.tar.gz"

    CONTAINERD_TGZ_TMP=/tmp/containerd.tar.gz
    retrycmd_get_tarball 60 5 "$CONTAINERD_TGZ_TMP" "$CONTAINERD_DOWNLOAD_URL"
	tar -xzf "$CONTAINERD_TGZ_TMP" -C /
	rm -f "$CONTAINERD_TGZ_TMP"
	sed -i '/\[Service\]/a ExecStartPost=\/sbin\/iptables -P FORWARD ACCEPT' /etc/systemd/system/containerd.service

	echo "Successfully installed cri-containerd..."
	if [[ "$CONTAINER_RUNTIME" == "clear-containers" ]] || [[ "$CONTAINER_RUNTIME" == "kata-containers" ]] || [[ "$CONTAINER_RUNTIME" == "containerd" ]]; then
		setupContainerd
	fi
}

function extractHyperkube() {
    TMP_DIR=$(mktemp -d)
    retrycmd_if_failure 100 1 30 curl -sSL -o /usr/local/bin/img "https://acs-mirror.azureedge.net/img/img-linux-amd64-v0.4.6"
    chmod +x /usr/local/bin/img
    retrycmd_if_failure 75 1 60 img pull $HYPERKUBE_URL || exit $ERR_K8S_DOWNLOAD_TIMEOUT
    path=$(find /tmp/img -name "hyperkube")

    if [[ $OS == $COREOS_OS_NAME ]]; then
        cp "$path" "/opt/kubelet"
        cp "$path" "/opt/kubectl"
        chmod a+x /opt/kubelet /opt/kubectl
    else
        cp "$path" "/usr/local/bin/kubelet"
        cp "$path" "/usr/local/bin/kubectl"
        chmod a+x /usr/local/bin/kubelet /usr/local/bin/kubectl
    fi
    rm -rf /tmp/hyperkube.tar "/tmp/img"
}

function installContainerRuntime() {
    if [[ "$CONTAINER_RUNTIME" == "docker" ]]; then
        installDocker
    elif [[ "$CONTAINER_RUNTIME" == "clear-containers" ]]; then
	    # Ensure we can nest virtualization
        if grep -q vmx /proc/cpuinfo; then
            installClearContainersRuntime
        fi
    elif [[ "$CONTAINER_RUNTIME" == "kata-containers" ]]; then
        # Ensure we can nest virtualization
        if grep -q vmx /proc/cpuinfo; then
            installKataContainersRuntime
        fi
    fi
}