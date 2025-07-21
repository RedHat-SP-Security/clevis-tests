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
COOKIE="/var/opt/clevis_setup_done"
ENCRYPTED_FILE="/var/opt/encrypted-volume.img"
LUKS_DEV_NAME="tang-unlocked-device"
MOUNT_POINT="/mnt/tang-test"
LOOP_SERVICE_NAME="setup-luks-loop.service"
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

            #rlRun "yum install -y clevis-dracut clevis-systemd" 0 "Install Clevis boot/systemd components"

            rlRun "mkdir -p /var/opt"
            rlRun "truncate -s 512M ${ENCRYPTED_FILE}" 0 "Create 512MB image file"
            
            LOOP_DEV=$(losetup -f --show "${ENCRYPTED_FILE}")
            rlAssertNotEquals "Loop device setup failed" "" "$LOOP_DEV"
            rlLog "Image file ${ENCRYPTED_FILE} is now attached to ${LOOP_DEV}"

            rlRun "echo -n 'password' | cryptsetup luksFormat ${LOOP_DEV} -" 0 "Format loop device with LUKS2"
            LUKS_UUID=$(cryptsetup luksUUID "${LOOP_DEV}")
            rlAssertNotEquals "LUKS UUID should not be empty" "" "$LUKS_UUID"

            rlLogInfo "Fetching Tang advertisement"
            rlRun "curl -sf http://${TANG_IP}/adv -o /tmp/adv.jws" 0 "Download Tang advertisement"

            SSS_CONFIG='{"t":1,"pins":{"tang":[{"url":"http://'"${TANG_IP}"'","adv":"/tmp/adv.jws"}]}}'
            rlLogInfo "Binding LUKS device ${LOOP_DEV} with SSS (Tang) pin"
            rlRun "clevis luks bind -f -d ${LOOP_DEV} sss '${SSS_CONFIG}'" 0 "Bind with SSS Tang pin" <<< 'password'

            # Unlock, format, and then re-lock the device before configuring boot
            rlLogInfo "Pre-formatting the LUKS volume"
            rlRun "clevis luks unlock -d ${LOOP_DEV} -n ${LUKS_DEV_NAME}" 0 "Temporarily unlock for formatting"
            rlRun "mkfs.xfs /dev/mapper/${LUKS_DEV_NAME}" 0 "Create filesystem"
            rlRun "cryptsetup luksClose ${LUKS_DEV_NAME}" 0 "Re-lock the device"

            # Create a systemd service to set up the loop device very early at boot
            rlLogInfo "Creating a systemd service to set up loop device at boot"
            cat << EOF > /etc/systemd/system/${LOOP_SERVICE_NAME}
[Unit]
Description=Setup loop device for LUKS test
DefaultDependencies=no
Before=local-fs-pre.target cryptsetup.target
After=systemd-udev-settle.service

[Service]
Type=oneshot
ExecStart=/sbin/losetup -f --show ${ENCRYPTED_FILE}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
            rlRun "systemctl daemon-reload"
            rlRun "systemctl enable ${LOOP_SERVICE_NAME}"

            # Configure crypttab to find the device by UUID. The _netdev option is critical.
            rlLogInfo "Adding entry to /etc/crypttab for initramfs-based unlock."
            grep -q "UUID=${LUKS_UUID}" /etc/crypttab || \
                echo "${LUKS_DEV_NAME} UUID=${LUKS_UUID} none _netdev" >> /etc/crypttab

            # Add fstab entry with 'nofail' to prevent boot hangs if unlock fails for any reason
            rlRun "mkdir -p ${MOUNT_POINT}"
            grep -q "${MOUNT_POINT}" /etc/fstab || \
                echo "/dev/mapper/${LUKS_DEV_NAME} ${MOUNT_POINT} xfs defaults,nofail 0 0" >> /etc/fstab

            # CRITICAL: Build an initramfs with Clevis and robust networking.
            rlLogInfo "Configuring dracut to add clevis and network support"
            echo 'add_dracutmodules+=" clevis network "' > /etc/dracut.conf.d/99-clevis.conf
            echo 'kernel_cmdline+=" rd.neednet=1 ip=dhcp "' >> /etc/dracut.conf.d/99-clevis.conf
            rlRun "dracut -f --regenerate-all" 0 "Regenerate initramfs"

            rlRun "touch '$COOKIE'"
            tmt-reboot
        rlPhaseEnd
    else
        # === POST-REBOOT: VERIFICATION PHASE ===
        rlPhaseStartTest "Clevis Client: Verify Auto-Unlock"
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
                rlRun "journalctl -b --no-pager -u 'systemd-cryptsetup@*.service'" 2 "Get cryptsetup service logs on failure"
                rlRun "journalctl -b --no-pager -u ${LOOP_SERVICE_NAME}" 2 "Get loop setup service logs on failure"
                rlFail "Device ${LUKS_DEV_NAME} was not automatically unlocked after waiting."
            fi

            # The device is already unlocked, now we just mount it.
            rlRun "mount ${MOUNT_POINT}" 0 "Mount the device via fstab entry"

            rlRun "lsblk" 0 "Display block devices"
            rlRun "findmnt ${MOUNT_POINT}" 0 "Verify device is mounted"
            rlLog "LUKS device was unlocked via Clevis + Tang at boot."
            export SYNC_PROVIDER=${TANG_IP}
            # Signal to the server that the test is done and cleanup can begin
            rlRun "sync-set CLEVIS_TEST_DONE"
        rlPhaseEnd

        # === COORDINATED CLEANUP ===
        rlPhaseStartCleanup "Clevis Client: Cleanup"
            # Wait for the server to signal it has finished its cleanup
            rlRun "sync-block TANG_CLEANUP_DONE ${TANG_IP}" 0 "Wait for Tang server cleanup"

            rlRun "umount ${MOUNT_POINT}" || rlLogInfo "Not mounted"
            rlRun "cryptsetup luksClose ${LUKS_DEV_NAME}" || rlLogInfo "Not open"
            LOOP_DEV=$(losetup -j "${ENCRYPTED_FILE}" | cut -d: -f1)
            [ -n "$LOOP_DEV" ] && rlRun "losetup -d ${LOOP_DEV}" || rlLogInfo "Loop device not attached"
            rlRun "systemctl disable ${LOOP_SERVICE_NAME}"
            rlRun "rm -f '$COOKIE' '${ENCRYPTED_FILE}' /etc/dracut.conf.d/99-clevis.conf /etc/systemd/system/${LOOP_SERVICE_NAME} /tmp/adv.jws"
            rlRun "sed -i \"/${LUKS_DEV_NAME}/d\" /etc/crypttab"
            rlRun "sed -i \"|${MOUNT_POINT}|d\" /etc/fstab"
            rlRun "rmdir ${MOUNT_POINT}"
            rlRun "dracut -f --regenerate-all" 0 "Regenerate initramfs to remove Clevis hook"
            
            # Final signal that all operations are complete
            rlRun "sync-set CLIENT_DONE"
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
        rlLog "Waiting for client to finish its test..."
        rlRun "sync-block CLEVIS_TEST_DONE ${CLEVIS_IP}" 0 "Wait for Clevis test completion"
    rlPhaseEnd
}

function Tang_Server_Cleanup() {
    rlPhaseStartCleanup "Tang Server: Cleanup"
        rlLog "Server cleanup started."
        rlRun "firewall-cmd --remove-port=${SYNC_GET_PORT}/tcp --permanent"
        rlRun "firewall-cmd --remove-port=${SYNC_SET_PORT}/tcp --permanent"
        rlRun "firewall-cmd --remove-service=http --permanent"
        rlRun "firewall-cmd --reload"

        # Signal to the client that server cleanup is done
        export SYNC_PROVIDER=${TANG_IP}
        rlRun "sync-set TANG_CLEANUP_DONE"
        
        # Wait for the client to finish its own cleanup
        rlRun "sync-block CLIENT_DONE ${CLEVIS_IP}" 0 "Wait for Clevis client cleanup"
        rlRun "sync-stop" 0 "Stop all synchronization daemons"
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