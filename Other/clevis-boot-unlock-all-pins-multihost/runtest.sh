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

    if [ ! -f "$COOKIE" ]; then
        # === PRE-REBOOT: SETUP PHASE ===
        rlPhaseStartSetup "Clevis Client: Initial Setup"
            rlLog "Waiting for Tang server at ${TANG_IP} to be ready..."
            rlRun "sync-block TANG_SETUP_DONE ${TANG_IP}" 0 "Waiting for Tang setup part"

            if $IMAGE_MODE; then
                # --- Image Mode: Use Loopback Device with systemd service ---
                rlRun "mkdir -p /var/opt"
                rlRun "truncate -s 512M ${ENCRYPTED_FILE}" 0 "Create 512MB image file"
                
                LOOP_DEV=$(losetup -f --show "${ENCRYPTED_FILE}")
                rlAssertNotEquals "Loop device setup failed" "" "$LOOP_DEV"
                rlLog "Image file ${ENCRYPTED_FILE} is now attached to ${LOOP_DEV}"

                rlRun "echo -n 'password' | cryptsetup luksFormat ${LOOP_DEV} -" 0 "Format loop device with LUKS2"
                LUKS_UUID=$(cryptsetup luksUUID "${LOOP_DEV}")

                rlRun "clevis luks unlock -d ${LOOP_DEV} -n ${LUKS_DEV_NAME}" 0 "Temp unlock"
                rlRun "mkfs.xfs /dev/mapper/${LUKS_DEV_NAME}" 0 "Create filesystem"
                rlRun "cryptsetup luksClose ${LUKS_DEV_NAME}" 0 "Re-lock device"

            else
                # --- Package Mode: Use RAM Disk ---
                rlLog "Creating a RAM disk at ${RAM_DISK_DEVICE}"
                rlRun "modprobe brd rd_nr=1 rd_size=524288" 0 "Create 512MB RAM disk"
                rlAssertExists "${RAM_DISK_DEVICE}"
                
                rlRun "echo -n 'password' | cryptsetup luksFormat ${RAM_DISK_DEVICE} -" 0 "Format RAM disk with LUKS2"
                LUKS_UUID=$(cryptsetup luksUUID "${RAM_DISK_DEVICE}")
            fi
            
            rlAssertNotEquals "LUKS UUID should not be empty" "" "$LUKS_UUID"
            rlLogInfo "Fetching Tang advertisement"
            rlRun "curl -sf http://${TANG_IP}/adv -o /tmp/adv.jws" 0 "Download Tang advertisement"

            DEVICE_TO_BIND=$([ "$IMAGE_MODE" = true ] && echo "$LOOP_DEV" || echo "$RAM_DISK_DEVICE")
            SSS_CONFIG='{"t":1,"pins":{"tang":[{"url":"http://'"${TANG_IP}"'","adv":"/tmp/adv.jws"}]}}'
            rlLogInfo "Binding LUKS device ${DEVICE_TO_BIND} with SSS (Tang) pin"
            rlRun "clevis luks bind -f -d ${DEVICE_TO_BIND} sss '${SSS_CONFIG}'" 0 "Bind with SSS Tang pin" <<< 'password'

            if $IMAGE_MODE; then
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
            fi

            rlLogInfo "Ensuring /etc/crypttab and /etc/fstab exist"
            rlRun "touch /etc/crypttab /etc/fstab"
            
            rlLogInfo "Adding entry to /etc/crypttab for initramfs-based unlock."
            grep -q "UUID=${LUKS_UUID}" /etc/crypttab || \
                echo "${LUKS_DEV_NAME} UUID=${LUKS_UUID} none _netdev" >> /etc/crypttab

            rlRun "mkdir -p ${MOUNT_POINT}"
            grep -q "${MOUNT_POINT}" /etc/fstab || \
                echo "/dev/mapper/${LUKS_DEV_NAME} ${MOUNT_POINT} xfs defaults,nofail 0 0" >> /etc/fstab

            rlLogInfo "Configuring dracut to add clevis and network support"
            echo 'add_dracutmodules+=" clevis network "' > /etc/dracut.conf.d/99-clevis.conf
            echo 'kernel_cmdline+=" rd.neednet=1 ip=dhcp "' >> /etc/dracut.conf.d/99-clevis.conf
            if [ "$IMAGE_MODE" = "false" ]; then
                echo 'add_drivers+=" brd "' >> /etc/dracut.conf.d/99-clevis.conf
            fi
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
                rlRun "journalctl -b --no-pager" 2 "Get full boot journal on failure"
                rlFail "Device ${LUKS_DEV_NAME} was not automatically unlocked after waiting."
            fi
            
            if [ "$IMAGE_MODE" = "false" ]; then
                # Only format the RAM disk post-boot
                rlLogInfo "Creating filesystem on the unlocked RAM disk"
                rlRun "mkfs.xfs /dev/mapper/${LUKS_DEV_NAME}" 0 "Create filesystem"
            fi

            rlRun "mount ${MOUNT_POINT}" 0 "Mount the device via fstab entry"

            rlRun "lsblk" 0 "Display block devices"
            rlRun "findmnt ${MOUNT_POINT}" 0 "Verify device is mounted"
            rlRun "journalctl -b | grep 'Finished Cryptography Setup for ${LUKS_DEV_NAME}'" 0 "Check for cryptsetup completion in journal"

            rlLog "LUKS device was unlocked via Clevis + Tang at boot."
            export SYNC_PROVIDER=${TANG_IP}
            rlRun "sync-set CLEVIS_TEST_DONE"
        rlPhaseEnd

        rlPhaseStartCleanup "Clevis Client: Cleanup"
            rlRun "umount ${MOUNT_POINT}" || rlLogInfo "Not mounted"
            rlRun "cryptsetup luksClose ${LUKS_DEV_NAME}" || rlLogInfo "Not open"

            if $IMAGE_MODE; then
                LOOP_DEV=$(losetup -j "${ENCRYPTED_FILE}" | cut -d: -f1)
                [ -n "$LOOP_DEV" ] && rlRun "losetup -d ${LOOP_DEV}" || rlLogInfo "Loop device not attached"
                rlRun "systemctl disable ${LOOP_SERVICE_NAME}"
                rlRun "rm -f '${ENCRYPTED_FILE}' /etc/systemd/system/${LOOP_SERVICE_NAME}"
            fi

            rlRun "rm -f '$COOKIE' /etc/dracut.conf.d/99-clevis.conf /tmp/adv.jws"
            rlRun "sed -i \"/${LUKS_DEV_NAME}/d\" /etc/crypttab"
            rlRun "sed -i \"|${MOUNT_POINT}|d\" /etc/fstab"
            rlRun "rmdir ${MOUNT_POINT}"
            rlRun "dracut -f --regenerate-all" 0 "Regenerate initramfs to remove Clevis hook"
            
            rlRun "sync-set CLIENT_CLEANUP_DONE"
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
        pkill -f "ncat -l -k -p ${SYNC_SET_PORT}" || true
        rlRun "firewall-cmd --remove-port=${SYNC_GET_PORT}/tcp --permanent"
        rlRun "firewall-cmd --remove-port=${SYNC_SET_PORT}/tcp --permanent"
        rlRun "firewall-cmd --remove-service=http --permanent"
        rlRun "firewall-cmd --reload"
        
        rlRun "sync-block CLIENT_CLEANUP_DONE ${CLEVIS_IP}" 0 "Wait for Clevis client cleanup"
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