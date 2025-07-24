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

function Clevis_Client_Test() {
    if bootc status &>/dev/null; then
        IMAGE_MODE=true
        rlLog "Detected IMAGE MODE"
    else
        IMAGE_MODE=false
        rlLog "Detected PACKAGE MODE"
    fi

    if [ ! -f "$COOKIE_CONFIG" ]; then
        rlPhaseStartSetup "Clevis Client: Initial Setup"
            rlLogInfo "Configuring client firewall to allow status polling from server"
            rlRun "systemctl enable --now firewalld"
            rlRun "firewall-cmd --add-port=${SYNC_GET_PORT}/tcp --permanent"
            rlRun "firewall-cmd --reload"

            if $IMAGE_MODE && [ ! -f "$COOKIE_INSTALL" ]; then
                rlLog "Image Mode - Phase 1: Installing packages"
                rlRun "touch $COOKIE_INSTALL"
                rlLog "Packages should be layered by bootc_prepare_test. Rebooting to apply."
            fi

            if ! $IMAGE_MODE; then
                rlRun "dnf install -y clevis-dracut clevis-systemd" 0 "Install Clevis components"
            fi

            # --- UNIFIED SETUP FOR AUTOMATIC UNLOCK ---
            DEVICE_TO_ENCRYPT="${ENCRYPTED_FILE}"
            rlRun "mkdir -p /var/opt"
            rlRun "truncate -s 512M ${DEVICE_TO_ENCRYPT}" 0 "Create 512MB image file"

            rlRun "echo -n 'password' | cryptsetup luksFormat ${DEVICE_TO_ENCRYPT} -" 0 "Format device with LUKS2"

            rlLogInfo "Fetching Tang advertisement"
            rlRun "curl -sf http://${TANG_IP}/adv -o /tmp/adv.jws" 0 "Download Tang advertisement"
            SSS_CONFIG='{"t":1,"pins":{"tang":[{"url":"http://'"${TANG_IP}"'","adv":"/tmp/adv.jws"}]}}'
            rlLogInfo "Binding LUKS device with SSS (Tang) pin"
            rlRun "clevis luks bind -f -d ${DEVICE_TO_ENCRYPT} sss '${SSS_CONFIG}'" 0 "Bind with SSS Tang pin" <<< 'password'

            rlLogInfo "Configuring system for automatic boot-time unlock"
            # 1. Configure Dracut to include Clevis and networking in initramfs
            echo 'add_dracutmodules+=" clevis network network-manager "' > /etc/dracut.conf.d/99-clevis.conf
            echo 'kernel_cmdline+=" rd.neednet=1 ip=dhcp "' >> /etc/dracut.conf.d/99-clevis.conf

            # 2. Configure crypttab to automatically unlock the device at boot
            echo "${LUKS_DEV_NAME} ${DEVICE_TO_ENCRYPT} none _netdev" >> /etc/crypttab

            # 3. Configure fstab to automatically mount the device once unlocked
            rlRun "mkdir -p ${MOUNT_POINT}"
            echo "/dev/mapper/${LUKS_DEV_NAME} ${MOUNT_POINT} xfs defaults,nofail 0 0" >> /etc/fstab

            # 4. Pre-format the filesystem so it's ready to be mounted on the next boot
            rlRun "clevis luks unlock -d ${DEVICE_TO_ENCRYPT} -n ${LUKS_DEV_NAME}" 0 "Temporarily unlock for formatting"
            rlRun "mkfs.xfs /dev/mapper/${LUKS_DEV_NAME}" 0 "Create filesystem"
            rlRun "cryptsetup luksClose ${LUKS_DEV_NAME}" 0 "Re-lock the device"

            # 5. In Package Mode, manually regenerate initramfs. In Image Mode, this is handled by bootc.
            if ! $IMAGE_MODE; then
                rlRun "dracut -f --regenerate-all" 0 "Regenerate initramfs"
            fi

            rlRun "touch '$COOKIE_CONFIG'"
            tmt-reboot
        rlPhaseEnd
    else
        rlPhaseStartTest "Clevis Client: Verify Automatic Boot Unlock"
            # --- UNIFIED VERIFICATION ---
            # The test succeeds if the device was automatically unlocked and mounted by the system.
            rlRun "findmnt ${MOUNT_POINT}" 0 "Verify device was automatically mounted at boot"
            rlLog "Clevis correctly unlocked and mounted the device at boot time."

            rlRun "sync-set CLEVIS_TEST_DONE"
        rlPhaseEnd

        rlPhaseStartCleanup "Clevis Client: Cleanup"
            rlRun "umount ${MOUNT_POINT}" || rlLogInfo "Device not mounted"
            rlRun "cryptsetup luksClose ${LUKS_DEV_NAME}" || rlLogInfo "Device not open"

            rlRun "rm -f '${ENCRYPTED_FILE}' '$COOKIE_CONFIG' '$COOKIE_INSTALL' /etc/dracut.conf.d/99-clevis.conf /tmp/adv.jws"
            [ -f /etc/fstab ] && rlRun "sed -i '\|${MOUNT_POINT}|d' /etc/fstab"
            [ -f /etc/crypttab ] && rlRun "sed -i '\|${LUKS_DEV_NAME}|d' /etc/crypttab"
            rlRun "rmdir ${MOUNT_POINT}"

            # Only run dracut in Package Mode
            if ! $IMAGE_MODE; then
                rlRun "dracut -f --regenerate-all" 0 "Regenerate initramfs to remove Clevis hook"
            fi
            
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
        rlRun "systemctl status tangd.socket"
        rlRun "curl -sf http://${TANG_IP}/adv"
        rlRun "sync-set TANG_SETUP_DONE" 0 "Tang setup of the server is done"
    rlPhaseEnd
    rlPhaseStartTest "Tang Server: Awaiting Client Test Completion"
        rlRun "sync-block CLEVIS_TEST_DONE ${CLEVIS_IP}" 0 "Waiting for the Clevis client test to complete"
    rlPhaseEnd
    rlPhaseStartCleanup "Tang Server: Cleanup"
        rlRun "sync-block CLIENT_CLEANUP_DONE ${CLEVIS_IP}" 0 "Wait for Clevis client cleanup"
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