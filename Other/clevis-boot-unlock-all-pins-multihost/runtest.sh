#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /clevis-tests/Otherl/tang-boot-unlock
#   Description: Test of clevis boot unlock via tang.
#   Author: Patrik Koncity <pkoncity@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2024 Red Hat, Inc.
#
#   This program is free software: you can redistribute it and/or
#   modify it under the terms of the GNU General Public License as
#   published by the Free Software Foundation, either version 2 of
#   the License, or (at your option) any later version.
#
#   This program is distributed in the hope that it will be
#   useful, but WITHOUT ANY WARRANTY; without even the implied
#   warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
#   PURPOSE.  See the GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program. If not, see http://www.gnu.org/licenses/.
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Include Beaker environment
. /usr/share/beakerlib/beakerlib.sh || exit 1

# --- Configuration ---
# COOKIE marks if the client has rebooted.
COOKIE="/var/opt/clevis_setup_done"
# Define persistent file locations for the client
PERSISTENT_LOOPFILE="/var/opt/loopfile"
PERSISTENT_ADV_FILE="/var/opt/adv.jws"
# Define the name for our unlocked device
LUKS_DEV_NAME="myluksdev"


# --- Role and IP Assignment ---
# This function reads the tmt topology and assigns variables.
function assign_roles() {
    if [ -n "${TMT_TOPOLOGY_BASH}" ] && [ -f "${TMT_TOPOLOGY_BASH}" ]; then
        rlLog "Sourcing roles from ${TMT_TOPOLOGY_BASH}"
        . "${TMT_TOPOLOGY_BASH}"
        export CLEVIS_HOSTNAME=${TMT_GUESTS[${TMT_ROLES["client"]}]['hostname']}
        export TANG_HOSTNAME=${TMT_GUESTS[${TMT_ROLES["server"]}]['hostname']}
        MY_IP="${TMT_GUEST['hostname']}"
    else
        rlDie "FATAL: Could not find TMT topology information. This test must be run in a multihost environment."
    fi

    export CLEVIS_IP=$(getent hosts "$CLEVIS_HOSTNAME" | awk '{ print $1 }' | head -n 1)
    export TANG_IP=$(getent hosts "$TANG_HOSTNAME" | awk '{ print $1 }' | head -n 1)

    rlLog "ROLE ASSIGNMENT:"
    rlLog "Client Host: ${CLEVIS_HOSTNAME} (${CLEVIS_IP})"
    rlLog "Server Host: ${TANG_HOSTNAME} (${TANG_IP})"
    rlLog "My Host/IP: $(hostname) / ${MY_IP}"
}


# --- Clevis Client Logic ---
# This function contains all steps that run on the Clevis client machine.
function Clevis_Client_Test() {
    if [ ! -f "$COOKIE" ]; then
        # === PRE-REBOOT: SETUP PHASE ===
        rlPhaseStartSetup "Clevis Client: Initial Setup"
            rlRun "rpm -q clevis-dracut cryptsetup tpm2-tools" 0 "Verify required packages are in the image"
            rlLog "Waiting for Tang server at ${TANG_IP} to be ready..."
            sync-block "TANG_SETUP_DONE" "${TANG_IP}"
            rlLog "Tang server is ready. Proceeding with client setup."

            rlRun "mkdir -p /var/opt"
            rlRun "dd if=/dev/zero of=${PERSISTENT_LOOPFILE} bs=1M count=100" 0 "Create 100MB loopfile"
            LOOP_DEV=$(losetup -f --show ${PERSISTENT_LOOPFILE})
            rlAssertNotEquals "Loop device should be created" "" "$LOOP_DEV"
            rlLogInfo "Using loop device ${LOOP_DEV} for LUKS."

            rlRun "echo -n 'password' | cryptsetup luksFormat ${LOOP_DEV} --type luks2 -" 0 "Format disk with LUKS2"
            LUKS_UUID=$(cryptsetup luksUUID "${LOOP_DEV}")
            rlAssertNotEquals "LUKS UUID should not be empty" "" "${LUKS_UUID}"

            rlLogInfo "Downloading Tang advertisement from http://${TANG_IP}/adv"
            rlRun "curl -sfgo ${PERSISTENT_ADV_FILE} http://${TANG_IP}/adv" 0 "Download Tang advertisement"

            # --- Dynamically build the Clevis SSS pin configuration ---
            local SSS_CONFIG
            if [ -e "/dev/tpm0" ] || [ -e "/dev/tpmrm0" ]; then
                rlLogInfo "TPM2 device found. Binding with Tang and TPM2 (t=2)."
                SSS_CONFIG='{"t":2,"pins":{"tang":[{"url":"http://'"${TANG_IP}"'"}],"tpm2":{}}}'
            else
                rlLogWarning "TPM2 device not found. Binding with Tang only (t=1)."
                SSS_CONFIG='{"t":1,"pins":{"tang":[{"url":"http://'"${TANG_IP}"'"}]}}'
            fi
            # --- End of dynamic pin building ---

            rlLogInfo "Binding Clevis with SSS config: ${SSS_CONFIG}"
            rlRun "clevis luks bind -d ${LOOP_DEV} sss '${SSS_CONFIG}' <<< 'password'" 0 "Bind Clevis to LUKS device"

            rlLogInfo "Adding entry to /etc/crypttab for automatic unlock."
            rlRun "echo '${LUKS_DEV_NAME} UUID=${LUKS_UUID} none luks,clevis,nofail' >> /etc/crypttab"

            rlLogInfo "Creating dracut hook to set up loop device during boot."
            cat << EOF_HOOK > "/var/opt/90-luks-loop-hook.sh"
#!/bin/bash
echo "LUKS Loop Hook: Setting up ${PERSISTENT_LOOPFILE}..." > /dev/kmsg
losetup \$(losetup -f) "${PERSISTENT_LOOPFILE}"
echo "LUKS Loop Hook: losetup complete." > /dev/kmsg
udevadm settle
EOF_HOOK
            chmod +x /var/opt/90-luks-loop-hook.sh

            cat << EOF_CONF > "/etc/dracut.conf.d/99-loopluks.conf"
install_items+=" /var/opt/90-luks-loop-hook.sh /usr/lib/dracut/hooks/pre-udev/90-luks-loop-hook.sh "
install_items+=" ${PERSISTENT_LOOPFILE} "
add_dracutmodules+=" network clevis "
kernel_cmdline="rd.neednet=1"
EOF_CONF

            rlRun "dracut --force" 0 "Regenerate initramfs with new hook"
            rlLogInfo "Initial setup complete. Triggering reboot."
            rlRun "touch '$COOKIE'"
            tmt-reboot
        rlPhaseEnd
    else
        # === POST-REBOOT: VERIFICATION PHASE ===
        rlPhaseStartTest "Clevis Client: Verify Auto-Unlock"
            rlRun "cryptsetup status ${LUKS_DEV_NAME}" 0 "Verify '${LUKS_DEV_NAME}' is active and unlocked"
            rlRun "journalctl -b | grep 'Finished Cryptography Setup for ${LUKS_DEV_NAME}'" 0 "Verify journal for successful cryptsetup"
            rlLogPass "Test passed: Clevis successfully unlocked the device during boot."
            rlRun "sync-set CLEVIS_TEST_DONE"
        rlPhaseEnd

        rlPhaseStartCleanup "Clevis Client: Cleanup"
            rlRun "umount /mnt/luks_test" ||:
            rlRun "cryptsetup luksClose ${LUKS_DEV_NAME}" ||:
            current_loop_dev=$(losetup -j ${PERSISTENT_LOOPFILE} 2>/dev/null | awk -F: '{print $1}')
            if [ -n "${current_loop_dev}" ]; then
              rlRun "losetup -d ${current_loop_dev}" ||:
            fi
            rlRun "rm -f '${COOKIE}'" ||:
            rlRun "rm -f '${PERSISTENT_LOOPFILE}'" ||:
            rlRun "rm -f '${PERSISTENT_ADV_FILE}'" ||:
            rlRun "rm -f /var/opt/90-luks-loop-hook.sh" ||:
            rlRun "rm -f /etc/dracut.conf.d/99-loopluks.conf" ||:
            rlRun "sed -i \"/${LUKS_DEV_NAME}/d\" /etc/crypttab" ||:
            rlRun "dracut --force" 0 "Regenerate initramfs to restore clean state"
        rlPhaseEnd
    fi
}


# --- Tang Server Logic ---
# This function contains all steps that run on the Tang server machine.
function Tang_Server_Setup() {
    rlPhaseStartSetup "Tang Server: Setup"
        rlRun "dnf install -y tang jose" 0 "Installing Tang and Jose on Server"
        rlRun "setenforce 0" 0 "Putting SELinux in Permissive mode for simplicity"

        # Generate Tang keys
        rlRun "mkdir -p /var/db/tang"
        rlRun "jose jwk gen -i '{\"alg\":\"ES512\"}' -o /var/db/tang/sig.jwk" 0 "Generate signature key"
        rlRun "jose jwk gen -i '{\"alg\":\"ECMR\"}' -o /var/db/tang/exc.jwk" 0 "Generate exchange key"

        rlRun "systemctl enable --now tangd.socket" 0 "Starting Tang service"
        rlRun "systemctl status tangd.socket" 0 "Checking Tang service status"
        rlRun "curl -sf http://localhost/adv" 0 "Verify Tang is responsive locally"

        rlLog "Tang server setup complete. Signaling to client."
        sync-set "TANG_SETUP_DONE"

        rlLog "Waiting for Clevis client at ${CLEVIS_IP} to finish its test..."
        sync-block "CLEVIS_TEST_DONE" "${CLEVIS_IP}"
        rlLog "Client has finished. Tang server role is complete."
    rlPhaseEnd
}


# --- Main Execution Logic ---
rlJournalStart
    rlPhaseStartSetup "Global Setup"
        rlRun 'rlImport "sync"' || rlDie "Cannot import sync library"
        assign_roles
    rlPhaseEnd

    if echo " $HOSTNAME $MY_IP " | grep -q " ${CLEVIS_HOSTNAME} "; then
        Clevis_Client_Test
    elif echo " $HOSTNAME $MY_IP " | grep -q " ${TANG_HOSTNAME} "; then
        Tang_Server_Setup
    else
        rlFail "Unknown role for host $(hostname). Neither client nor server."
    fi
rlJournalEnd


# Tang server - package mode:
# - setup the Tang server
# - generate key using jose
# gen_tang_keys() {
#     rlRun "jose jwk gen -i '{\"alg\":\"ES512\"}' -o \"$1/sig.jwk\""
#     rlRun "jose jwk gen -i '{\"alg\":\"ECMR\"}' -o \"$1/exc.jwk\""
# }

# rlRun "setenforce 0" 0 "Putting SELinux in Permissive mode"
# - Start Tang Service: It launches the Tang server on a dynamic port (TANG_PORT) using the start_tang_fn function (likely a helper from utils.sh).
# - Verify Tang: It uses curl to check if the Tang server is responsive at https://<TANG_IP>:<TANG_PORT>/adv. The /adv endpoint provides the server's public advertisement keys.

# Clevis client - Image Mode
# - setup a LUKS device and encrypt it (basically prepare for the unlock in boot)
# - check if TPM2 is available - skip the unlocking with TPM2 pin if the TPm2 is not available
# Trust the Tang Server: The script copies the Tang server's certificate into the VM's system-wide trust store and runs update-ca-trust. This is crucial for establishing a secure TLS connection to the Tang server later.

# Fetch Tang Advertisement: It uses curl to download the Tang server's public keys (adv.jws).

# Bind the Encrypted Disk: This is the most critical step. The script finds all LUKS-encrypted devices and runs clevis luks bind.

# clevis luks bind -d "${dev}" sss '{"t":2,"pins":{"tang":[...], "tpm2": {...}}}'

# This command binds the LUKS device using the sss (Shamir's Secret Sharing) pin.

# The configuration '{"t":2, ...}' sets a threshold of 2. This means that to reconstruct the decryption key, both the Tang pin and the TPM2 pin must be satisfied.

# The tang pin points to the URL of the Tang server on the host.

# The tpm2 pin is configured to use PCRs (Platform Configuration Registers) 0 and 7, which measure firmware and bootloader integrity.

# Prepare for Boot:

# It adds rd.neednet=1 to the boot configuration. This tells the system to bring up networking in the early boot environment (the initramfs), which is necessary for Clevis to reach the Tang server.

# It runs dracut -f --regenerate-all. This rebuilds the initramfs, packaging Clevis, the new network configuration, and the LUKS binding information into the initial boot image.

# - the bootloader loads the kernel and the newly created initramfs.

# The initramfs environment starts. systemd-cryptsetup detects the encrypted LUKS volume.

# The Clevis hooks within initramfs are triggered.

# Clevis attempts to satisfy the SSS policy:

# It checks the TPM2 PCR values. If they match the values from when the binding was created, the TPM2 pin is satisfied.

# It brings up the network (rd.neednet=1) and contacts the Tang server on the host. It performs a cryptographic exchange to get the second part of the key.

# Since the threshold is 2, Clevis combines the secrets from the successful TPM2 unsealing and the Tang server response to reconstruct the master disk encryption key.

# The unlock is now complete. Clevis passes the key to systemd-cryptsetup, which unlocks the volume.

# The root filesystem is mounted, and the normal boot process continues until the VM is fully up and running.

# Wait for SSH: The runtest.sh script on the host waits for the VM to boot completely and respond to SSH commands (vmWaitByAddr).

# Final Verification: The host script connects to the booted VM via SSH (vmCmd) and checks the system journal (journalctl -b). It looks for log messages confirming that systemd-cryptsetup finished successfully, proving the automated unlock worked without requiring a password.


