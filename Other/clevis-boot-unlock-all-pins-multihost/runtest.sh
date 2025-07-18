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
SYNC_GET_PORT=2134
SYNC_SET_PORT=2135
SETUP_LOOP_SERVICE="/etc/systemd/system/setup-loop-for-luks.service"
TANG_IP_FILE="/etc/clevis-test-data/tang_ip.txt"

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

            rlRun "mkdir -p /var/opt"
            rlRun "dd if=/dev/zero of=${PERSISTENT_LOOPFILE} bs=1M count=512" 0 "Create 512MB loopfile"
            LOOP_DEV=$(losetup -f --show "${PERSISTENT_LOOPFILE}")
            rlAssertNotEquals "Loop device should be created" "" "$LOOP_DEV"

            rlRun "echo -n 'password' | cryptsetup luksFormat ${LOOP_DEV} --type luks2 -" 0 "Format disk with LUKS2"
            LUKS_UUID=$(cryptsetup luksUUID "${LOOP_DEV}")
            rlAssertNotEquals "LUKS UUID should not be empty" "" "${LUKS_UUID}"

            # 1. Download the advertisement to a file.
            rlRun "curl -sfgo /tmp/adv.jws http://${TANG_IP}/adv" 0 "Download Tang advertisement"

            # 2. Check for a TPM device.
            TPM_PRESENT=0
            if [ -c /dev/tpmrm0 ] || [ -c /dev/tpm0 ]; then
                TPM_PRESENT=1
            fi

            # 3. Bind using the simple "file path" method.
            if [ $TPM_PRESENT -eq 1 ]; then
                rlLogInfo "TPM2 present. Binding with Tang and TPM2 (t=2)."
                SSS_CONFIG='{"t":2,"pins":{"tang":[{"url":"http://'"${TANG_IP}"'","adv":"/tmp/adv.jws"}],"tpm2":{}}}'
                # ✅ FIX 1: Use a here-string '<<<' to pass the password, matching the working example.
                rlRun "clevis luks bind -f -d \"${LOOP_DEV}\" sss '${SSS_CONFIG}'" 0 "Bind with TPM2 + Tang" <<< 'password'
            else
                rlLogWarning "No TPM2 detected. Binding with Tang only (t=1)."
                SSS_CONFIG='{"t":1,"pins":{"tang":[{"url":"http://'"${TANG_IP}"'","adv":"/tmp/adv.jws"}]}}'
                # ✅ FIX 1: Use a here-string '<<<' to pass the password, matching the working example.
                rlRun "clevis luks bind -f -d \"${LOOP_DEV}\" sss '${SSS_CONFIG}'" 0 "Bind with Tang only" <<< 'password'
            fi

            # ✅ FIX 2: Add the missing /etc/crypttab entry so the system knows to unlock the device at boot.
            rlLogInfo "Adding entry to /etc/crypttab for automatic unlock."
            grep -q "UUID=${LUKS_UUID}" /etc/crypttab || echo "${LUKS_DEV_NAME} UUID=${LUKS_UUID} none luks,clevis,nofail" >> /etc/crypttab

            # 5. Create a systemd service to set up the loop device inside the initramfs
            cat << 'EOF' > "${SETUP_LOOP_SERVICE}"
[Unit]
Description=Set up loop device for LUKS
DefaultDependencies=no
Before=cryptsetup.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/losetup -f --show /var/opt/loopfile

[Install]
WantedBy=cryptsetup.target
EOF

            # 6. Configure dracut to install all necessary files and services into the initramfs.
            cat << EOF > /etc/dracut.conf.d/99-clevis-loop.conf
install_items+=" ${PERSISTENT_LOOPFILE} /tmp/adv.jws ${SETUP_LOOP_SERVICE} "
dracut_systemd_enable+=" setup-loop-for-luks.service "
add_dracutmodules+=" network clevis systemd "
kernel_cmdline+=" rd.neednet=1 "
EOF
            rlRun "dracut --force --verbose" 0 "Regenerate initramfs"
            rlRun "touch '$COOKIE'"
            tmt-reboot
        rlPhaseEnd
    else
        rlPhaseStartTest "Clevis Client: Verify Auto-Unlock"
            rlRun "lsblk" 0 "Display block devices"
            rlRun "cryptsetup status ${LUKS_DEV_NAME}" 0 "Verify LUKS device is unlocked"
            rlRun "journalctl -b | grep 'clevis-luks-askpass.service: Deactivated successfully.'" 0
            rlRun "journalctl -b | grep 'Finished Cryptography Setup for ${LUKS_DEV_NAME}'" 0
            rlLog "LUKS device was unlocked via Clevis + Tang at boot."
            export SYNC_PROVIDER=${TANG_IP}
            rlRun "sync-set CLEVIS_TEST_DONE"
        rlPhaseEnd

        rlPhaseStartCleanup "Clevis Client: Cleanup"
            rlRun "cryptsetup luksClose ${LUKS_DEV_NAME}" || rlLogInfo "Not open"
            loop_dev=$(losetup -j ${PERSISTENT_LOOPFILE} | cut -d: -f1)
            [ -n "$loop_dev" ] && rlRun "losetup -d $loop_dev"
            rlRun "rm -f '$COOKIE' '${PERSISTENT_LOOPFILE}' /etc/dracut.conf.d/99-clevis-loop.conf /tmp/adv.jws /tmp/trust.jwk '$TANG_IP_FILE'"
            rlRun "sed -i \"/${LUKS_UUID}/d\" /etc/crypttab"
            rlRun "dracut --force"
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
        WAIT_TIMEOUT=900
        while [[ $WAIT_TIMEOUT -gt 0 ]]; do
            if grep -q "CLEVIS_TEST_DONE" "/var/tmp/sync-status"; then
                rlLog "Client completed"
                break
            fi
            sleep 10
            WAIT_TIMEOUT=$((WAIT_TIMEOUT - 10))
        done
        [ "$WAIT_TIMEOUT" -le 0 ] && rlFail "Timed out waiting for client"
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