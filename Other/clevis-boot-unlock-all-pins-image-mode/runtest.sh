#!/bin/bash

# Include Beaker environment
. /usr/share/beakerlib/beakerlib.sh || exit 1

# Define variables for image building and VM creation
BOOTC_IMAGE_TAG="localhost:5000/clevis-bootc-test-image:latest" # Use a local registry for build/push
VM_NAME="clevis-bootc-vm"
VM_DISK_PATH="/var/lib/libvirt/images/${VM_NAME}.qcow2"
VM_DISK_SIZE_GB=10
SSH_KEY_PUB="${HOME}/.ssh/id_rsa.pub"
SSH_KEY_PRIV="${HOME}/.ssh/id_rsa"
TANG_IP="" # To be determined dynamically on the host

# --- Helper functions for VM interaction (replaces vmCmd) ---
# Assumes SSH_KEY_PRIV and VM_IP are set.
vmCmd() {
    local ip="$1"
    shift
    ssh -o StrictHostKeyChecking=no -i "${SSH_KEY_PRIV}" root@"${ip}" "$@"
}

# --- Function to build the bootc image with Clevis ---
build_bootc_image() {
    rlLogInfo "Building bootc-ostree image: ${BOOTC_IMAGE_TAG}"

    local build_dir=$(mktemp -d)
    trap "rm -rf ${build_dir}" EXIT # Ensure cleanup of temp directory

    # Define the Containerfile content
    # This Containerfile installs clevis and enables its systemd units.
    # The actual LUKS encryption and clevis binding happen during 'bootc install to-disk'.
    cat <<EOF > "${build_dir}/Containerfile"
FROM registry.access.redhat.com/rhel9/rhel-bootc:latest
# Alternatively, for Fedora: FROM fedora/fedora-bootc:latest

# Install clevis and related packages
RUN dnf install -y clevis clevis-luks clevis-dracut cryptsetup-luks && dnf clean all

# Enable clevis systemd units for boot-time unlock
RUN systemctl enable clevis-luks-askpass.path
RUN systemctl enable clevis-luks-tang.path # If Tang is the primary method being tested
# Note: For PKCS11, 'clevis-luks-pkcs11-askpass.socket' would also be relevant.

# Basic init command
CMD ["/sbin/init"]
EOF

    rlRun "podman build -t ${BOOTC_IMAGE_TAG} ${build_dir}" 0 "Building bootc image"
    rlRun "podman push ${BOOTC_IMAGE_TAG}" 0 "Pushing image to local registry"
}

# --- Function to deploy the bootc image to a VM ---
deploy_bootc_to_vm() {
    rlLogInfo "Deploying bootc image to VM: ${VM_NAME}"

    # Clean up previous VM and disk if they exist
    rlRun "virsh destroy ${VM_NAME}" || :
    rlRun "virsh undefine ${VM_NAME} --nvram" || :
    rlRun "rm -f ${VM_DISK_PATH}" || :

    # Create the target disk image for bootc install
    rlRun "qemu-img create -f qcow2 ${VM_DISK_PATH} ${VM_DISK_SIZE_GB}G" 0 "Creating VM disk for bootc install"

    # Install the bootc image onto the disk, performing LUKS encryption and Clevis binding
    # IMPORTANT: Ensure 'bootc' command is available on the host.
    rlLogInfo "Running 'bootc install to-disk' with LUKS and Clevis Tang binding."
    rlRun "bootc install to-disk \
           --target-img ${VM_DISK_PATH} \
           --keyfile ${SSH_KEY_PUB} \
           --username root \
           --root-encryption luks \
           --clevis-tang-url 'http://${TANG_IP}' \
           ${BOOTC_IMAGE_TAG}" \
           0 "Installing bootc image to disk with LUKS and Clevis"

    # Define OS variant based on host OS for virt-install
    local OS_VARIANT
    if rlIsFedora; then
        OS_VARIANT="fedora$(grep VERSION_ID /etc/os-release | cut -d'=' -f2 | tr -d '"')"
    elif rlIsRHEL; then
        OS_VARIANT="rhel$(grep VERSION_ID /etc/os-release | cut -d'=' -f2 | tr -d '"').0" # E.g., rhel9.0
    else
        OS_VARIANT="linux" # Fallback
    fi

    # Create and start the VM using virt-install
    rlRun "virt-install \
           --name ${VM_NAME} \
           --ram 2048 \
           --vcpus 2 \
           --disk path=${VM_DISK_PATH},bus=virtio \
           --os-variant ${OS_VARIANT} \
           --network default,model=virtio \
           --import \
           --noautoconsole \
           --graphics none" 0 "Creating and starting VM from bootc image"

    # Get VM IP address
    VM_IP=""
    for i in $(seq 1 60); do # Wait up to 10 minutes for IP
        VM_IP=$(virsh domifaddr ${VM_NAME} | grep ipv4 | awk '{print $4}' | cut -d/ -f1)
        if [ -n "${VM_IP}" ]; then
            rlLogInfo "VM IP: ${VM_IP}"
            break
        fi
        rlLogInfo "Waiting for VM IP... (attempt ${i}/60)"
        sleep 10
    done
    [ -n "${VM_IP}" ] || rlDie "Could not get VM IP address"

    # Wait for SSH to be available
    for i in $(seq 1 30); do # Wait up to 5 minutes for SSH
        if ssh -o StrictHostKeyChecking=no -i "${SSH_KEY_PRIV}" root@"${VM_IP}" "true" &>/dev/null; then
            rlLogInfo "SSH connection to VM successful."
            break
        fi
        rlLogInfo "Waiting for SSH on ${VM_IP}... (attempt ${i}/30)"
        sleep 10
    done
    ssh -o StrictHostKeyChecking=no -i "${SSH_KEY_PRIV}" root@"${VM_IP}" "true" || rlDie "Failed to SSH to VM"

    export VM_IP # Make VM_IP available globally for vmCmd
}

rlJournalStart
  rlPhaseStartSetup
    rlImport --all || rlDie "Import failed to import Beakerlib libraries"

    # Ensure SSH key exists for VM access
    if [ ! -f "${SSH_KEY_PRIV}" ]; then
      rlRun "ssh-keygen -t rsa -b 2048 -f ${SSH_KEY_PRIV} -N ''" 0 "Generating SSH key pair"
    fi
    rlAssertExists "${SSH_KEY_PUB}" "Public SSH key must exist"

    # Set SELinux to permissive if requested (host only)
    rlLogInfo "DISABLE_SELINUX(${DISABLE_SELINUX})"
    if [ -n "${DISABLE_SELINUX}" ]; then
      rlRun "setenforce 0" 0 "Putting SELinux in Permissive mode on host"
    fi
    rlLogInfo "Host SELinux: $(getenforce)"

    # Start Tang server on the host
    rlLogInfo "Starting Tang server on host."
    rlRun "systemctl start tangd.socket" 0 "Starting tangd.socket"
    rlRun "systemctl status tangd.socket" 0 "Checking tangd.socket status"
    TANG_IP=$(ip addr show $(ip route get 1 | awk '{print $5; exit}') | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    rlAssertNotEquals "Tang IP should not be empty" "" "${TANG_IP}"
    rlLogInfo "Tang Server IP: ${TANG_IP}"

    # Build the custom bootc image with Clevis
    build_bootc_image
    rlAssertExists "$(podman image exists ${BOOTC_IMAGE_TAG} && echo true)" "Bootc image should be built"

    # Deploy the image to a new VM and configure Clevis unlock
    deploy_bootc_to_vm
    rlAssertNotEquals "VM_IP should not be empty after deployment" "" "${VM_IP}"

  rlPhaseEnd

  rlPhaseStartTest "Clevis Unlock Verification on Image Mode VM"

    # Verify Clevis unlock via journalctl in the VM
    rlLogInfo "Checking journalctl in VM for clevis unlock messages"
    if rlIsRHELLike '>=10'; then
      rlRun "vmCmd ${VM_IP} journalctl -b | grep \"Finished systemd-cryptsetup\"" 0 "Verify systemd-cryptsetup finished in VM"
    else
      rlRun "vmCmd ${VM_IP} journalctl -b | grep \"Finished Cryptography Setup for luks-\"" 0 "Verify Cryptography Setup finished in VM"
      rlRun "vmCmd ${VM_IP} journalctl -b | grep \"clevis-luks-askpass.service: Deactivated successfully\"" 0 "Verify clevis-luks-askpass deactivated in VM"
    fi

    # Further checks: verify that the root device is indeed unlocked by clevis
    # Get the root device in the VM (e.g., /dev/vda3 or /dev/vda2)
    ROOT_DEV=$(vmCmd ${VM_IP} findmnt -n -o SOURCE /)
    rlLogInfo "Root device in VM: ${ROOT_DEV}"
    # Verify Clevis is reported as a key protector
    rlRun "vmCmd ${VM_IP} cryptsetup luksDump ${ROOT_DEV} | grep -q 'Clevis'" 0 "Verify Clevis is bound to LUKS header on root device"

  rlPhaseEnd

  rlPhaseStartCleanup
    rlLogInfo "Cleaning up VM and image artifacts"

    # Stop and remove the VM
    rlRun "virsh destroy ${VM_NAME}" || :
    rlRun "virsh undefine ${VM_NAME} --nvram" || :
    rlRun "rm -f ${VM_DISK_PATH}" || :

    # Remove the built bootc image from local registry and local storage
    rlRun "podman rmi -f ${BOOTC_IMAGE_TAG}" || :

    # Stop Tang server
    rlRun "systemctl stop tangd.socket" || :
  rlPhaseEnd
rlJournalEnd