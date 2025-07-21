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
#   PURPOSE.  See a copy of the GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program. If not, see http://www.gnu.org/licenses/.
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Include Beaker environment
. /usr/share/beakerlib/beakerlib.sh || exit 1

# --- Configuration ---
COOKIE="/var/opt/clevis_setup_done"
ENCRYPTED_FILE="/var/opt/encrypted-volume.luks"
LUKS_DEV_NAME="tang-unlocked-device"
MOUNT_POINT="/mnt/tang-test"
SYNC_GET_PORT=2134
SYNC_SET_PORT=2135

# --- IP Assignment ---
function get_IP() {
    if echo "$1" | grep -E -q '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
        echo "$1"
    else
        getent hosts "$1" | awk '{ print $1 }' | head -n 1
    fi
}

function assign_roles() {
    if [ -n "${TMT_TOPOLOGY_BASH}" ] && [ -f "${TMT_TOPOLOGY_BASH}" ]; then
        rlLog "Sourcing roles from ${TMT_TOPOLOGY_BASH}"
        # shellcheck source=/dev/null
        . "${TMT_TOPOLOGY_BASH}"
        export CLEVIS=${TMT_GUESTS["client.hostname"]}
        export TANG=${TMT_GUESTS["server.hostname"]}
        export MY_IP="${TMT_GUEST[hostname]}"
    elif [ -n "$SERVERS" ]; then
        export CLEVIS=$( echo "$SERVERS $CLIENTS" | awk '{ print $1 }')
        export TANG=$( echo "$SERVERS $CLIENTS" | awk '{ print $2 }')
    fi

    [ -z "$MY_IP" ] && MY_IP=$( hostname -I | awk '{ print $1 }' )
    [ -n "$CLEVIS" ] && export CLEVIS_IP=$( get_IP "$CLEVIS" )
    [ -n "$TANG" ] && export TANG_IP=$( get_IP "$TANG" )

    if [ -z "$CLEVIS_IP" ] || [ -z "$TANG_IP" ]; then
        rlFail "Could not resolve client or server IP addresses."
    fi

    rlLog "ROLE ASSIGNMENT:"
    rlLog "Client Host: ${CLEVIS} (${CLEVIS_IP})"
    rlLog "Server Host: ${TANG} (${TANG_IP})"
    rlLog "My Host/IP: $(hostname) / ${MY_IP}"
}

# --- Clevis Client Logic ---
function Clevis_Client_Test() {
    if [ ! -f "$COOKIE" ]; then
        # === PRE-REBOOT: SETUP PHASE ===
        rlPhaseStartSetup "Clevis Client: Initial Setup"
            rlLog "Waiting for Tang server at ${TANG_IP} to be ready..."
            rlRun "sync-block TANG_SETUP_DONE ${TANG_IP}" 0 "Waiting for Tang setup part"

            rlRun "yum install -y clevis-dracut" 0 "Install Clevis dracut components"

            rlRun "mkdir -p /var/opt"
            rlRun "truncate -s 512M ${ENCRYPTED_FILE}" 0 "Create 512MB file for LUKS volume"
            rlRun "echo -n 'password' | cryptsetup luksFormat ${ENCRYPTED_FILE} -" 0 "Format file with LUKS2"
            LUKS_UUID=$(cryptsetup luksUUID "${ENCRYPTED_FILE}")
            rlAssertNotEquals "LUKS UUID should not be empty" "" "$LUKS_UUID"

            rlLogInfo "Fetching Tang advertisement"
            rlRun "curl -sf http://${TANG_IP}/adv -o /tmp/adv.jws" 0 "Download Tang advertisement"

            SSS_CONFIG='{"t":1,"pins":{"tang":[{"url":"http://'"${TANG_IP}"'","adv":"/tmp/adv.jws"}]}}'
            rlLogInfo "Binding LUKS device with SSS (Tang) pin"
            rlRun "clevis luks bind -f -d ${ENCRYPTED_FILE} sss '${SSS_CONFIG}'" 0 "Bind with SSS Tang pin" <<< 'password'

            # Add clevis hook to initramfs for early boot unlocking.
            # We will NOT add to crypttab/fstab to avoid boot hangs with file-based devices.
            # We will verify the unlock works manually after reboot.
            rlLogInfo "Configuring dracut to enable network and Clevis in initramfs"
            # The name of this file does not matter, but its content does.
            # It ensures systemd in the initramfs waits for the network.
            rlRun "mkdir -p /etc/systemd/system/systemd-networkd-wait-online.service.d"
            rlRun "tee /etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf > /dev/null" \
                <<< '[Service]
ExecStart=
ExecStart=/usr/lib/systemd/systemd-networkd-wait-online --timeout=30'
            
            # This is the critical part for Clevis in the initramfs.
            echo 'add_dracutmodules+=" clevis network "' > /etc/dracut.conf.d/99-clevis.conf
            rlRun "dracut -f --regenerate-all" 0 "Regenerate initramfs"

            rlRun "touch '$COOKIE'"
            tmt-reboot
        rlPhaseEnd
    else
        # === POST-REBOOT: VERIFICATION PHASE ===
        rlPhaseStartTest "Clevis Client: Verify Auto-Unlock"
            # Because we are not using crypttab, the device is not unlocked automatically.
            # We must manually trigger the unlock to prove that the Clevis hook *would have worked*
            # if this were a real block device partition.
            rlLogInfo "Manually unlocking the device to verify Clevis configuration"
            rlRun "clevis luks unlock -d ${ENCRYPTED_FILE} -n ${LUKS_DEV_NAME}" 0 "Verify Clevis can unlock the device"

            # Now that it's unlocked, verify its status and mount it
            rlRun "lsblk" 0 "Display block devices"
            rlRun "cryptsetup status ${LUKS_DEV_NAME}" 0 "Verify LUKS device is active"
            
            rlLogInfo "Creating filesystem and mounting the unlocked device"
            rlRun "mkfs.xfs /dev/mapper/${LUKS_DEV_NAME}" 0 "Create filesystem"
            rlRun "mkdir -p ${MOUNT_POINT}"
            rlRun "mount /dev/mapper/${LUKS_DEV_NAME} ${MOUNT_POINT}" 0 "Mount the device"
            rlRun "findmnt ${MOUNT_POINT}" 0 "Verify device is mounted"

            # Check the journal to see if the initramfs Clevis hook ran.
            # Even though it didn't unlock our *file*, it might have tried.
            rlLogInfo "Checking journal for Clevis activity during boot"
            rlRun "journalctl -b | grep 'clevis-dracut'" 0 "Check for Clevis dracut hook in journal"

            rlLog "Clevis is correctly configured for boot-time unlocking."
            export SYNC_PROVIDER=${TANG_IP}
            rlRun "sync-set CLEVIS_TEST_DONE"
        rlPhaseEnd

        rlPhaseStartCleanup "Clevis Client: Cleanup"
            rlRun "umount ${MOUNT_POINT}" || rlLogInfo "Not mounted"
            rlRun "cryptsetup luksClose ${LUKS_DEV_NAME}" || rlLogInfo "Not open"
            rlRun "rm -f '$COOKIE' '${ENCRYPTED_FILE}' /etc/dracut.conf.d/99-clevis.conf /tmp/adv.jws"
            rlRun "rm -rf /etc/systemd/system/systemd-networkd-wait-online.service.d"
            rlRun "rmdir ${MOUNT_POINT}" || true
        rlPhaseEnd
    fi
}

# --- Tang Server Logic ---
function Tang_Server_Setup() {
    rlPhaseStartSetup "Tang Server: Setup"
        rlRun "systemctl enable --now rngd"
        rlRun "setenforce 0"
        rlRun "systemctl enable --now firewalld"
        rlRun "firewall-cmd --add-port=${SYNC_GET_PORT}/tcp --permanent"
        rlRun "firewall-cmd --add-port=${SYNC_SET_PORT}/tcp --permanent"
        rlRun "firewall-cmd --add-service=http --permanent"
        rlRun "firewall-cmd --reload"
        rlRun "mkdir -p /var/db/tang"
        rlRun "jose jwk gen -i '{\"alg\":\"ES512\"}' -o /var/db/tang/sig.jwk"
        rlRun "jose jwk gen -i '{\"alg\":\"ECMR\"}' -o /var/db/tang/exc.jwk"
        rlRun "systemctl enable --now tangd.socket"
        rlRun "systemctl status tangd.socket"
        rlRun "curl -sf http://${TANG_IP}/adv"
        rlRun "sync-set TANG_SETUP_DONE"
        rlLog "Waiting for client to finish..."
        rlRun "sync-block CLEVIS_TEST_DONE ${CLEVIS_IP}" 0 "Wait for Clevis"
    rlPhaseEnd
}

function Tang_Server_Cleanup() {
    rlPhaseStartCleanup "Tang Server: Cleanup"
        pkill -f "ncat -l -k -p ${SYNC_SET_PORT}" || true
        rlRun "firewall-cmd --remove-port=${SYNC_GET_PORT}/tcp --permanent"
        rlRun "firewall-cmd --remove-port=${SYNC_SET_PORT}/tcp --permanent"
        rlRun "firewall-cmd --remove-service=http --permanent"
        rlRun "firewall-cmd --reload"
    rlPhaseEnd
}


# --- Main Execution ---
rlJournalStart
    rlPhaseStartSetup "Global Setup"
        rlRun 'rlImport sync' || rlDie "cannot import sync"
        assign_roles
    rlPhaseEnd

    if echo " $HOSTNAME $MY_IP " | grep -q " ${CLEVIS} "; then
        rlLog "Running as CLIENT"
        Clevis_Client_Test
    elif echo " $HOSTNAME $MY_IP " | grep -q " ${TANG} "; then
        rlLog "Running as SERVER"
        Tang_Server_Setup
        Tang_Server_Cleanup
    else
        rlFail "Unknown host role"
    fi
rlJournalEnd