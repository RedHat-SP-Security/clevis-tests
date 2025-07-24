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
DEVICE="/dev/vdb"
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

    if [ ! -f "$COOKIE_CONFIG" ]; then
        rlPhaseStartSetup "Clevis Client: Initial Setup"
            if $IMAGE_MODE && [ ! -f "$COOKIE_INSTALL" ]; then
                rlLog "Image Mode - Phase 1: Installing packages. Rebooting to apply."
                rlRun "touch $COOKIE_INSTALL"
                tmt-reboot
            fi

            rlLogInfo "Configuring client firewall"
            rlRun "systemctl enable --now firewalld"
            rlRun "firewall-cmd --add-port=${SYNC_GET_PORT}/tcp --permanent"
            rlRun "firewall-cmd --reload"

            rlLogInfo "Creating and binding LUKS device"
            rlRun "wipefs -a ${DEVICE}" 0 "Wipe any old signatures"
            rlRun "echo -n 'password' | cryptsetup luksFormat ${DEVICE} -" 0 "Format with LUKS2"

            ADV=$(curl -sf "http://${TANG_IP}/adv")
            SSS_CONFIG="{\"t\":1,\"pins\":{\"tang\":[{\"url\":\"http://${TANG_IP}\",\"adv\":${ADV}}]}}"
            rlRun "clevis luks bind -f -d ${DEVICE} sss '${SSS_CONFIG}'" 0 "Bind with Tang pin" <<< 'password'

            rlLog "Configuring system for automatic boot-time unlock"
            echo 'add_dracutmodules+=" clevis network network-manager "' > /etc/dracut.conf.d/99-clevis.conf
            echo 'kernel_cmdline+=" rd.neednet=1 ip=dhcp "' >> /etc/dracut.conf.d/99-clevis.conf

            echo "${LUKS_DEV_NAME} ${DEVICE} none _netdev,initramfs" >> /etc/crypttab

            rlRun "mkdir -p ${MOUNT_POINT}"
            echo "/dev/mapper/${LUKS_DEV_NAME} ${MOUNT_POINT} xfs defaults,nofail 0 0" >> /etc/fstab

            rlRun "clevis luks unlock -d ${DEVICE} -n ${LUKS_DEV_NAME}" 0 "Temporarily unlock"
            rlRun "mkfs.xfs /dev/mapper/${LUKS_DEV_NAME}" 0 "Format with XFS"
            rlRun "cryptsetup luksClose ${LUKS_DEV_NAME}" 0 "Re-lock"

            if ! $IMAGE_MODE; then
                rlRun "dracut -f --regenerate-all" 0 "Regenerate initramfs"
            else
                rlLog "Image Mode - rebooting to apply dracut config"
                tmt-reboot
            fi

            rlRun "touch '$COOKIE_CONFIG'"
            tmt-reboot
        rlPhaseEnd
    else
        rlPhaseStartTest "Clevis Client: Verify Automatic Boot Unlock"
            rlRun "findmnt ${MOUNT_POINT}" 0 "Verify device was automatically mounted"
            rlLog "Success: Device was decrypted and mounted at boot"
            rlRun "sync-set CLEVIS_TEST_DONE"
        rlPhaseEnd

        rlPhaseStartCleanup "Clevis Client: Cleanup"
            rlRun "umount ${MOUNT_POINT}" || rlLogInfo "Not mounted"
            rlRun "cryptsetup luksClose ${LUKS_DEV_NAME}" || rlLogInfo "Not open"

            rlRun "rm -f '$COOKIE_CONFIG' '$COOKIE_INSTALL'"
            rlRun "rm -f /etc/dracut.conf.d/99-clevis.conf"
            [ -f /etc/fstab ] && rlRun "sed -i '\|${MOUNT_POINT}|d' /etc/fstab"
            [ -f /etc/crypttab ] && rlRun "sed -i '\|${LUKS_DEV_NAME}|d' /etc/crypttab"
            rlRun "rmdir ${MOUNT_POINT}" || rlLogInfo "Already removed"

            if ! $IMAGE_MODE; then
                rlRun "dracut -f --regenerate-all"
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