#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /clevis-tests/Otherl/tang-boot-unlock
#   Description: Multihost test of clevis boot unlock via tang.
#   Author: Adam Prikryl <aprikryl@redhat.com>
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
COOKIE_INSTALL="/var/opt/clevis_install_done"
COOKIE_CONFIG="/var/opt/clevis_config_done"
ENCRYPTED_FILE="/var/opt/encrypted-volume.luks"
LUKS_DEV_NAME="tang-unlocked-device"
MOUNT_POINT="/mnt/tang-test"
RAM_DISK_DEVICE="/dev/ram0"
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
    # Detect if we are running in Image Mode (bootc/ostree)
    if bootc status &>/dev/null; then
        IMAGE_MODE=true
        rlLog "Detected IMAGE MODE"
    else
        IMAGE_MODE=false
        rlLog "Detected PACKAGE MODE"
    fi

    if [ ! -f "$COOKIE_CONFIG" ]; then
        # === PRE-REBOOT: SETUP PHASE ===
        # This pre-reboot section is unchanged and correct.
        rlPhaseStartSetup "Clevis Client: Initial Setup"
            if $IMAGE_MODE && [ ! -f "$COOKIE_INSTALL" ]; then
                rlLog "Image Mode - Phase 1: Installing packages"
                rlRun "touch $COOKIE_INSTALL"
                rlLog "Packages should be layered by bootc_prepare_test. Rebooting to apply."
            fi

            rlLog "Waiting for Tang server at ${TANG_IP} to be ready..."
            rlRun "sync-block TANG_SETUP_DONE ${TANG_IP}" 0 "Waiting for Tang setup part"

            if ! $IMAGE_MODE; then
                rlRun "yum install -y clevis-dracut clevis-systemd" 0 "Install Clevis components"
            fi

            if $IMAGE_MODE; then
                rlRun "mkdir -p /var/opt"
                rlRun "truncate -s 512M ${ENCRYPTED_FILE}" 0 "Create 512MB image file"
                DEVICE_TO_ENCRYPT="${ENCRYPTED_FILE}"
            else
                rlLog "Creating a RAM disk at ${RAM_DISK_DEVICE}"
                rlRun "modprobe brd rd_nr=1 rd_size=524288" 0 "Create 512MB RAM disk"
                rlAssertExists "${RAM_DISK_DEVICE}"
                DEVICE_TO_ENCRYPT="${RAM_DISK_DEVICE}"
            fi

            rlRun "echo -n 'password' | cryptsetup luksFormat ${DEVICE_TO_ENCRYPT} -" 0 "Format device with LUKS2"
            rlLogInfo "Fetching Tang advertisement"
            rlRun "curl -sf http://${TANG_IP}/adv -o /tmp/adv.jws" 0 "Download Tang advertisement"

            SSS_CONFIG='{"t":1,"pins":{"tang":[{"url":"http://'"${TANG_IP}"'","adv":"/tmp/adv.jws"}]}}'
            rlLogInfo "Binding LUKS device with SSS (Tang) pin"
            rlRun "clevis luks bind -f -d ${DEVICE_TO_ENCRYPT} sss '${SSS_CONFIG}'" 0 "Bind with SSS Tang pin" <<< 'password'

            if ! $IMAGE_MODE; then
                LUKS_UUID=$(cryptsetup luksUUID "${DEVICE_TO_ENCRYPT}")
                rlAssertNotEquals "LUKS UUID should not be empty" "" "$LUKS_UUID"

                rlLogInfo "Pre-formatting the LUKS volume"
                rlRun "clevis luks unlock -d ${DEVICE_TO_ENCRYPT} -n ${LUKS_DEV_NAME}" 0 "Temporarily unlock for formatting"
                rlRun "mkfs.xfs /dev/mapper/${LUKS_DEV_NAME}" 0 "Create filesystem"
                rlRun "cryptsetup luksClose ${LUKS_DEV_NAME}" 0 "Re-lock the device"

                rlLogInfo "Adding entry to /etc/crypttab for initramfs-based unlock."
                grep -q "UUID=${LUKS_UUID}" /etc/crypttab || \
                    echo "${LUKS_DEV_NAME} UUID=${LUKS_UUID} none _netdev" >> /etc/crypttab
                rlRun "mkdir -p ${MOUNT_POINT}"
                grep -q "${MOUNT_POINT}" /etc/fstab || \
                    echo "/dev/mapper/${LUKS_DEV_NAME} ${MOUNT_POINT} xfs defaults,nofail 0 0" >> /etc/fstab
            fi

            rlLogInfo "Configuring dracut to add clevis and network support"
            echo 'add_dracutmodules+=" clevis network "' > /etc/dracut.conf.d/99-clevis.conf
            echo 'kernel_cmdline+=" rd.neednet=1 ip=dhcp "' >> /etc/dracut.conf.d/99-clevis.conf
            if [ "$IMAGE_MODE" = "false" ]; then
                echo 'add_drivers+=" brd "' >> /etc/dracut.conf.d/99-clevis.conf
            fi
            rlRun "dracut -f --regenerate-all" 0 "Regenerate initramfs"

            rlRun "touch '$COOKIE_CONFIG'"
            tmt-reboot
        rlPhaseEnd
    else
        # === POST-REBOOT: VERIFICATION PHASE (CORRECTED) ===
        rlPhaseStartTest "Clevis Client: Verify Unlock Capability"
            # RESTORED: This block performs the unlock/verification. It was missing before.
            if $IMAGE_MODE; then
                rlLogInfo "Image Mode: Verifying boot-time capability via manual unlock"
                rlRun "clevis luks unlock -d ${ENCRYPTED_FILE} -n ${LUKS_DEV_NAME}" 0 "Verify Clevis can unlock the device post-boot"
            else
                rlLogInfo "Package Mode: Verifying automatic unlock"
                local unlocked=false
                for i in $(seq 1 15); do
                    rlLog "Attempt $i/15: Checking if device was unlocked automatically..."
                    if cryptsetup status ${LUKS_DEV_NAME} > /dev/null 2>&1; then
                        rlLog "Device ${LUKS_DEV_NAME} was automatically unlocked."
                        unlocked=true
                        break
                    fi
                    rlLog "Device not yet active. Waiting 6 seconds..."
                    sleep 6
                done

                if ! $unlocked; then
                    rlRun "journalctl -b --no-pager" 2 "Get full boot journal on failure"
                    rlFail "Device ${LUKS_DEV_NAME} was not automatically unlocked after waiting."
                fi
            fi

            # Common verification steps that follow the unlock
            rlLogInfo "Creating filesystem and mounting the unlocked device"
            rlRun "mkfs.xfs /dev/mapper/${LUKS_DEV_NAME}" 0 "Create filesystem"
            rlRun "mkdir -p ${MOUNT_POINT}"
            rlRun "mount /dev/mapper/${LUKS_DEV_NAME} ${MOUNT_POINT}" 0 "Mount the device"
            rlRun "findmnt ${MOUNT_POINT}" 0 "Verify device is mounted"

            rlLog "Clevis is correctly configured and functional for boot-time unlocking."
            export SYNC_PROVIDER=${TANG_IP}

            # Signal test completion AFTER successful verification
            rlRun "sync-set CLEVIS_TEST_DONE" 0 "Signal that client test verification is complete"

        rlPhaseEnd

        # === COORDINATED CLEANUP (CORRECTED) ===
        rlPhaseStartCleanup "Clevis Client: Cleanup"
            # Perform all local cleanup actions first
            rlRun "umount ${MOUNT_POINT}" || rlLogInfo "Not mounted"
            rlRun "cryptsetup luksClose ${LUKS_DEV_NAME}" || rlLogInfo "Not open"

            if $IMAGE_MODE; then
                rlRun "rm -f '${ENCRYPTED_FILE}'"
            fi

            rlRun "rm -f '$COOKIE_CONFIG' '$COOKIE_INSTALL' /etc/dracut.conf.d/99-clevis.conf /tmp/adv.jws"
            [ -f /etc/crypttab ] && rlRun "sed -i \"/${LUKS_DEV_NAME}/d\" /etc/crypttab"
            [ -f /etc/fstab ] && rlRun "sed -i \"|${MOUNT_POINT}|d\" /etc/fstab"
            rlRun "rmdir ${MOUNT_POINT}"
            rlRun "dracut -f --regenerate-all" 0 "Regenerate initramfs to remove Clevis hook"

            # CORRECTED: Signal to the server that client cleanup is finished at the VERY END.
            rlRun "sync-set CLIENT_CLEANUP_DONE"
        rlPhaseEnd
    fi
}

# --- Tang Server Logic ---
function Tang_Server() {
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
        rlRun "sync-set TANG_SETUP_DONE" 0 "Tang setup of the server is done"
    rlPhaseEnd

    # NEW: Wait for the client to finish its main test verification
    rlPhaseStartTest "Tang Server: Awaiting Client Test Completion"
        rlRun "sync-block CLEVIS_TEST_DONE ${CLEVIS_IP}" 0 "Waiting for the Clevis client test to complete"
    rlPhaseEnd

    rlPhaseStartCleanup "Tang Server: Cleanup"
        # Now, wait for the client to finish its cleanup before we clean up the server
        rlRun "sync-block CLIENT_CLEANUP_DONE ${CLEVIS_IP}" 0 "Wait for Clevis client cleanup"

        # Now, perform the actual server cleanup
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
        Tang_Server
    else
        rlFail "Unknown host role"
    fi
rlJournalEnd