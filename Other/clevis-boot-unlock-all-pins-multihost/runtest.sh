#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /clevis-tests/Other/clevis-boot-unlock-all-pins-multihost
#   Description: Multihost test of clevis boot unlock via all possible pins (tang, tpm2) and using sss.
#   Author: Adam Prikryl <aprikryl@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2025 Red Hat, Inc.
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

COOKIE_INSTALL="/var/opt/clevis_install_done"
COOKIE_CONFIG="/var/opt/clevis_config_done"
ENCRYPTED_FILE="/var/opt/encrypted-volume.luks"
LUKS_DEV_NAME="tang-unlocked-device"
MOUNT_POINT="/mnt/tang-test"
SYNC_GET_PORT=2134
SYNC_SET_PORT=2135

function get_IP() {
    if echo "$1" | grep -E -q '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
        echo "$1"
    else
        getent hosts "$1" | awk '{ print $1 }' | head -n 1
    fi
}

function assign_roles() {
    if [ -n "${TMT_TOPOLOGY_BASH}" ] && [ -f "${TMT_TOPOLOGY_BASH}" ]; then
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

function Clevis_Client_Test() {
    if bootc status &>/dev/null; then IMAGE_MODE=true; else IMAGE_MODE=false; fi

    local ADV_FILE="/var/opt/adv.jws"

    if [ ! -f "$COOKIE_CONFIG" ]; then
        rlPhaseStartSetup "Clevis Client: Initial Setup"
            rlRun "setenforce 0" 0 "Set SELinux to permissive mode"
            rlRun "systemctl enable --now firewalld"
            rlRun "firewall-cmd --add-port=${SYNC_GET_PORT}/tcp --permanent"
            rlRun "firewall-cmd --reload"
            rlRun "sync-block TANG_SETUP_DONE ${TANG_IP}"

            rlLogInfo "Creating and binding LUKS device"
            rlRun "mkdir -p /var/opt"
            rlRun "truncate -s 512M ${ENCRYPTED_FILE}"
            rlRun "echo -n 'password' | cryptsetup luksFormat ${ENCRYPTED_FILE} -"
            rlRun "curl -sf http://${TANG_IP}/adv -o ${ADV_FILE}"
            
            SSS_CONFIG='{"t":1,"pins":{"tang":[{"url":"http://'"${TANG_IP}"'","adv":"'"${ADV_FILE}"'"}]}}'
            rlRun "clevis luks bind -f -d ${ENCRYPTED_FILE} sss '${SSS_CONFIG}'" <<< 'password'

            rlLog "Creating custom systemd service for Clevis unlock"
            cat > /etc/systemd/system/clevis-test-unlock.service << EOF
[Unit]
Description=Clevis unlock for test device
After=network-online.target
Wants=network-online.target
DefaultDependencies=no
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/clevis-luks-unlock -d ${ENCRYPTED_FILE} -n ${LUKS_DEV_NAME}
[Install]
WantedBy=multi-user.target
EOF

            # Enable the new service
            rlRun "systemctl daemon-reload"
            rlRun "systemctl enable clevis-test-unlock.service"

            # Configure fstab to mount the device after it's unlocked
            rlRun "mkdir -p ${MOUNT_POINT}"
            echo "/dev/mapper/${LUKS_DEV_NAME} ${MOUNT_POINT} xfs defaults,nofail 0 0" >> /etc/fstab

            # Format the filesystem before rebooting
            rlRun "clevis luks unlock -d ${ENCRYPTED_FILE} -n ${LUKS_DEV_NAME}"
            rlRun "mkfs.xfs /dev/mapper/${LUKS_DEV_NAME}"
            rlRun "cryptsetup luksClose ${LUKS_DEV_NAME}"

            rlRun "touch '$COOKIE_CONFIG'"
            tmt-reboot
        rlPhaseEnd
    else
        rlPhaseStartTest "Clevis Client: Verify Automatic Boot Unlock"
            sleep 5
            rlRun "cryptsetup status ${LUKS_DEV_NAME}" 0 "Check that the LUKS device is active"
            rlRun "findmnt ${MOUNT_POINT}" 0 "Verify device was automatically mounted at boot"
            rlLog "Clevis correctly unlocked and mounted the device at boot time."
            rlRun "sync-set CLEVIS_TEST_DONE"
        rlPhaseEnd

        rlPhaseStartCleanup "Clevis Client: Cleanup"
            rlRun "systemctl disable clevis-test-unlock.service --now >/dev/null 2>&1 ||:"
            rlRun "rm -f /etc/systemd/system/clevis-test-unlock.service"
            rlRun "umount ${MOUNT_POINT}" || rlLogInfo "Device not mounted"
            rlRun "cryptsetup luksClose ${LUKS_DEV_NAME}" || rlLogInfo "Device not open"
            
            rlRun "rm -f '${ENCRYPTED_FILE}' '${ADV_FILE}' '$COOKIE_CONFIG' '$COOKIE_INSTALL'"
            [ -f /etc/fstab ] && rlRun "sed -i '\|${MOUNT_POINT}|d' /etc/fstab"
            rlRun "rmdir ${MOUNT_POINT}" || rlLogInfo "Mount point directory already removed"

            unset SYNC_PROVIDER
            rlRun "sync-set CLIENT_CLEANUP_DONE"
        rlPhaseEnd
    fi
}

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
        rlRun "curl -sf http://${TANG_IP}/adv"
        rlRun "sync-set TANG_SETUP_DONE"
    rlPhaseEnd

    rlPhaseStartTest "Tang Server: Wait for Client"
        rlRun "sync-block CLEVIS_TEST_DONE ${CLEVIS_IP}"
    rlPhaseEnd
    
    rlPhaseStartCleanup "Tang Server: Cleanup"
        rlRun "sync-block CLIENT_CLEANUP_DONE ${CLEVIS_IP}"
        rlRun "firewall-cmd --remove-port=${SYNC_GET_PORT}/tcp --permanent"
        rlRun "firewall-cmd --remove-port=${SYNC_SET_PORT}/tcp --permanent"
        rlRun "firewall-cmd --remove-service=http --permanent"
        rlRun "firewall-cmd --reload"
    rlPhaseEnd
}

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