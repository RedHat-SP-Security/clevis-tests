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


# --- IP Assignment ---
# This function resolves a hostname to an IP address.
function get_IP() {
    if echo "$1" | grep -E -q '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
        echo "$1"
    else
        getent hosts "$1" | awk '{ print $1 }' | head -n 1
    fi
}

# This function reads the tmt topology and gets IPs for all roles.
function assign_roles() {
    if [ -n "${TMT_TOPOLOGY_BASH}" ] && [ -f "${TMT_TOPOLOGY_BASH}" ]; then
        rlLog "Sourcing roles from ${TMT_TOPOLOGY_BASH}"
        # Sourcing this file makes TMT_ROLES and TMT_GUESTS available
        . "${TMT_TOPOLOGY_BASH}"

        # Get the guest name assigned to the 'client' role
        local client_guest_name=${TMT_ROLES["client"]}
        # Use that guest name to look up its hostname
        local clevis_hostname=${TMT_GUESTS[$client_guest_name]['hostname']}
        # Get the IP from the hostname
        export CLEVIS_IP=$(get_IP "$clevis_hostname")

        # Repeat for the server
        local server_guest_name=${TMT_ROLES["server"]}
        local tang_hostname=${TMT_GUESTS[$server_guest_name]['hostname']}
        export TANG_IP=$(get_IP "$tang_hostname")

        rlAssertNotEmpty "Could not resolve client IP" "$CLEVIS_IP"
        rlAssertNotEmpty "Could not resolve server IP" "$TANG_IP"

        rlLog "IPs discovered: Client=${CLEVIS_IP}, Server=${TANG_IP}"
    else
        rlDie "FATAL: Could not find TMT topology information. This test must be run in a multihost environment."
    fi
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

            local SSS_CONFIG
            if [ -e "/dev/tpm0" ] || [ -e "/dev/tpmrm0" ]; then
                rlLogInfo "TPM2 device found. Binding with Tang and TPM2 (t=2)."
                SSS_CONFIG='{"t":2,"pins":{"tang":[{"url":"http://'"${TANG_IP}"'"}],"tpm2":{}}}'
            else
                rlLogWarning "TPM2 device not found. Binding with Tang only (t=1)."
                SSS_CONFIG='{"t":1,"pins":{"tang":[{"url":"http://'"${TANG_IP}"'"}]}}'
            fi

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
function Tang_Server_Setup() {
    rlPhaseStartSetup "Tang Server: Setup"
        rlRun "dnf install -y tang jose" 0 "Installing Tang and Jose on Server"
        rlRun "setenforce 0" 0 "Putting SELinux in Permissive mode for simplicity"
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
        assign_roles
    rlPhaseEnd

    # Use the TMT_GUEST_ROLE variable for clear and robust role detection
    if [ "$TMT_GUEST_ROLE" == "client" ]; then
        rlLog "This machine is the CLIENT. Running Clevis test logic."
        Clevis_Client_Test
    elif [ "$TMT_GUEST_ROLE" == "server" ]; then
        rlLog "This machine is the SERVER. Running Tang setup logic."
        Tang_Server_Setup
    else
        rlFail "Unknown role: '$TMT_GUEST_ROLE' for host $(hostname)."
    fi
rlJournalEnd
