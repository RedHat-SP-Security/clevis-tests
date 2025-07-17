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
COOKIE="/var/opt/clevis_setup_done"
PERSISTENT_LOOPFILE="/var/opt/loopfile"
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
        . "${TMT_TOPOLOGY_BASH}"

        export CLEVIS=${TMT_GUESTS["client.hostname"]}
        export TANG=${TMT_GUESTS["server.hostname"]}
        MY_IP="${TMT_GUEST['hostname']}"

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
            rlRun "sync-block TANG_SETUP_DONE" "${TANG_IP}" "Waiting for Tang setup part"
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
            # <<< FIX: Added retries to curl for network resilience
            rlRun "curl --retry 5 --retry-delay 2 -sfgo /var/opt/adv.jws http://${TANG_IP}/adv" 0 "Download Tang advertisement"

            local SSS_CONFIG
            if [ -e "/dev/tpm0" ] || [ -e "/dev/tpmrm0" ]; then
                rlLogInfo "TPM2 device found. Binding with Tang and TPM2 (t=2)."
                SSS_CONFIG='{"t":2,"pins":{"tang":[{"url":"http://'"${TANG_IP}"'"}],"tpm2":{}}}'
            else
                rlLogWarning "TPM2 device not found. Binding with Tang only (t=1)."
                SSS_CONFIG='{"t":1,"pins":{"tang":[{"url":"http://'"${TANG_IP}"'"}]}}'
            fi

            rlLogInfo "Binding Clevis with SSS config: ${SSS_CONFIG}"
            rlRun "clevis luks bind -f -d ${LOOP_DEV} sss '${SSS_CONFIG}' <<< 'password'" 0 "Bind Clevis to LUKS device"

            rlLogInfo "Adding entry to /etc/crypttab for automatic unlock."
            # <<< FIX: Use a unique separator to prevent duplicating the line
            grep -q "UUID=${LUKS_UUID}" /etc/crypttab || echo "${LUKS_DEV_NAME} UUID=${LUKS_UUID} none luks,clevis,nofail" >> /etc/crypttab

            rlLogInfo "Creating dracut hook to set up loop device during boot."
            # <<< FIX: Correct hook directory path in install_items
            cat << EOF_DRACUT_CONF > "/etc/dracut.conf.d/99-loopluks.conf"
install_items+=" ${PERSISTENT_LOOPFILE} "
add_dracutmodules+=" network clevis "
force_add_dracutmodules+=" network clevis "
kernel_cmdline+=" rd.neednet=1 "
EOF_DRACUT_CONF

            rlRun "dracut --force --verbose" 0 "Regenerate initramfs"
            rlLogInfo "Initial setup complete. Triggering reboot."
            rlRun "touch '$COOKIE'"
            tmt-reboot
        rlPhaseEnd
    else
        # === POST-REBOOT: VERIFICATION PHASE ===
        rlPhaseStartTest "Clevis Client: Verify Auto-Unlock"
            rlRun "lsblk" 0 "Display block devices post-reboot"
            rlRun "cryptsetup status ${LUKS_DEV_NAME}" 0 "Verify '${LUKS_DEV_NAME}' is active and unlocked"
            rlLog "Searching boot journal for explicit Clevis unlock messages..."
            rlRun "journalctl -b | grep 'clevis-luks-askpass.service: Deactivated successfully.'" 0 "Verify clevis-luks-askpass service ran during boot"
            rlRun "journalctl -b | grep 'Finished Cryptography Setup for ${LUKS_DEV_NAME}'" 0 "Verify journal for successful cryptsetup of our device"
            rlLogPass "Test passed: Clevis successfully unlocked the device during boot."
            # <<< FIX: Signal that the client is done.
            rlRun "sync-set CLEVIS_TEST_DONE" 0 "Setting that Clevis part is done"
        rlPhaseEnd

        rlPhaseStartCleanup "Clevis Client: Cleanup"
            rlRun "cryptsetup luksClose ${LUKS_DEV_NAME}" || rlLogInfo "Device not open, skipping close."
            current_loop_dev=$(losetup -j ${PERSISTENT_LOOPFILE} 2>/dev/null | cut -d: -f1)
            if [ -n "${current_loop_dev}" ]; then
              rlRun "losetup -d ${current_loop_dev}" 0 "Detaching loop device"
            fi
            rlRun "rm -f '$COOKIE' '${PERSISTENT_LOOPFILE}' /var/opt/adv.jws /etc/dracut.conf.d/99-loopluks.conf"
            rlRun "sed -i \"/${LUKS_UUID}/d\" /etc/crypttab" 0 "Remove entry from crypttab"
            rlRun "dracut --force" 0 "Regenerate initramfs to restore clean state"
        rlPhaseEnd
    fi
}


# --- Tang Server Logic ---
function Tang_Server_Setup() {
    rlPhaseStartSetup "Tang Server: Setup"
        rlRun "dnf install -y tang jose-util" 0 "Install server packages"
        rlRun "setenforce 0" 0 "Putting SELinux in Permissive mode for simplicity"
        rlRun "mkdir -p /var/db/tang" 0 "Ensure tang directory exists"
        rlRun "jose jwk gen -i '{\"alg\":\"ES512\"}' -o /var/db/tang/sig.jwk" 0 "Generate signature key"
        rlRun "jose jwk gen -i '{\"alg\":\"ECMR\"}' -o /var/db/tang/exc.jwk" 0 "Generate exchange key"
        rlRun "systemctl enable --now tangd.socket" 0 "Starting Tang service"
        rlRun "systemctl status tangd.socket" 0 "Checking Tang service status"
        rlRun "curl -sf http://localhost/adv" 0 "Verify Tang is responsive locally"

        rlLog "Tang server setup complete. Signaling to client."
        rlRun "sync-set TANG_SETUP_DONE" "Setting that Tang setup part is done"

        # <<< FIX: This is the "smart wait" logic.
        # Instead of a fixed sleep, we will now poll the local sync status file
        # until we see the "CLEVIS_TEST_DONE" flag set by the client.
        # This keeps the test process alive without causing a deadlock.
        rlLog "Server is now waiting for the client to signal it is finished..."
        WAIT_TIMEOUT=900 # 15 minutes max wait
        while [[ $WAIT_TIMEOUT -gt 0 ]]; do
            # Check if the local status file contains the client's "done" signal
            if grep -q "CLEVIS_TEST_DONE" "/var/tmp/sync-status"; then
                rlLog "Client has signaled completion. Server can now exit."
                break
            fi
            sleep 10
            WAIT_TIMEOUT=$((WAIT_TIMEOUT - 10))
        done

        if [[ $WAIT_TIMEOUT -le 0 ]]; then
            rlFail "Timed out waiting for the client to finish."
        fi
    rlPhaseEnd
}


# --- Main Execution Logic ---
rlJournalStart
    rlPhaseStartSetup "Global Setup"
        assign_roles
    rlPhaseEnd

    # Role detection logic
    # A case statement is slightly more robust for this
    case "${TMT_GUEST[role]}" in
        client)
            rlLog "This machine's role is CLIENT. Running Clevis test logic."
            Clevis_Client_Test
            ;;
        server)
            rlLog "This machine's role is SERVER. Running Tang setup logic."
            Tang_Server_Setup
            ;;
        *)
            # Fallback for the `grep` method if role isn't set
            if echo " $HOSTNAME $MY_IP " | grep -q " ${CLEVIS} "; then
                rlLog "This machine is the CLIENT. Running Clevis test logic."
                Clevis_Client_Test
            elif echo " $HOSTNAME $MY_IP " | grep -q " ${TANG} "; then
                rlLog "This machine is the SERVER. Running Tang setup logic."
                Tang_Server_Setup
            else
                rlFail "Unknown role for host $(hostname). Neither client nor server."
            fi
            ;;
    esac
rlJournalEnd