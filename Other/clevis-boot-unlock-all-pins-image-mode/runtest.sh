#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /clevis-tests/Otherl/tang-boot-unlock
#   Description: Test of clevis boot unlock via tang and tpm2 for Image Mode testing (bootc/ostree).
#   Author: Adam Prikryl <aprikryl@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2024 Red Hat, Inc.
#
#   This program is free software: you can redistribute and/or
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

# Define variables for this test (only constants, dynamic values read from persistent storage)
TANG_SERVER_PORT="8080" # Consistent port

PERSISTENT_DATA_DIR="/var/lib/clevis-test-data" # Must match prepare script
PERSISTENT_TANG_IP_FILE="${PERSISTENT_DATA_DIR}/tang_ip.txt"

rlJournalStart
  rlPhaseStartSetup
    rlImport --all || rlDie "Import failed"
    rlRun "rlImport --all" 0 "Import libraries" || rlDie "cannot continue"

    rlLogInfo "SELinux: $(getenforce)"

    # SSH setup: ensure ~/.ssh/config is set up.
    rlRun "rlFileBackup --clean ~/.ssh/" 0 "Backup and clean ~/.ssh/"
    rlRun "mkdir -p ~/.ssh" 0 "Create ~/.ssh directory"
    rlRun "chmod 700 ~/.ssh" 0 "Set permissions for ~/.ssh"
    rlRun "rm -f ~/.ssh/known_hosts" 0 "Remove known_hosts"
    cat << EOF > ~/.ssh/config
Host *
  user root
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel QUIET
EOF
    rlRun "chmod 600 ~/.ssh/config" 0 "Set permissions for ~/.ssh/config"

    echo "Checking for Tang IP file after reboot..."
    if [ ! -f "${PERSISTENT_TANG_IP_FILE}" ]; then
        echo "ERROR: ${PERSISTENT_TANG_IP_FILE} not found!"
    else
        echo "Found Tang IP file:"
        cat "${PERSISTENT_TANG_IP_FILE}"
    fi

    # Get the Tang server IP from the file created by the 'prepare' phase.
    TANG_IP=$(cat "${PERSISTENT_TANG_IP_FILE}" 2>/dev/null)
    rlAssertNotEquals "Tang server IP not found in ${PERSISTENT_TANG_IP_FILE}. Prepare phase failed or file not persistent?" "" "$TANG_IP"
    rlLogInfo "Tang server for verification is at: ${TANG_IP}:${TANG_SERVER_PORT}"

  rlPhaseEnd

  rlPhaseStartTest "Verify Boot Unlock (Post-Reboot)"
    # This phase runs AFTER the system has rebooted into the newly installed
    # `bootc` image, which should now have LUKS and Clevis configured.

    # TPM2 device may appear as /dev/tpmrm0 or /dev/tpm0.
    if [ -e /dev/tpmrm0 ]; then
      TPM_DEVICE="/dev/tpmrm0"
    elif [ -e /dev/tpm0 ]; then
      TPM_DEVICE="/dev/tpm0"
    else
      rlDie "No TPM2 device found (neither /dev/tpmrm0 nor /dev/tpm0)"
    fi
    rlRun "ls -l ${TPM_DEVICE}" 0 "Verify TPM2 device exists on the booted system"

    # Verify journalctl for successful LUKS decryption and Clevis askpass deactivation.
    if rlIsRHELLike '>=10'; then
      rlRun "journalctl -b | grep \"Finished systemd-cryptsetup\"" 0 "Verify systemd-cryptsetup finished"
    else
      rlRun "journalctl -b | grep \"Finished Cryptography Setup for luks-\"" 0 "Verify Cryptography Setup finished"
      rlRun "journalctl -b | grep \"clevis-luks-askpass.service: Deactivated successfully\"" 0 "Verify clevis-luks-askpass deactivated"
    fi

    # Verify that the root filesystem is indeed mounted via LUKS.
    rlRun "lsblk -no FSTYPE,MOUNTPOINT | grep 'crypto_LUKS /'" 0 "Verify root is LUKS-mounted"

    # Check cryptsetup status for the root device "root" mapper
    rlRun "sudo cryptsetup status root | grep 'cipher: aes-cbc-essiv:sha256'" 0 "Verify LUKS cipher"
    rlRun "sudo cryptsetup status root | grep 'active one key slot'" 0 "Verify LUKS active key slot (by Clevis)"

    # Dynamically find the root LUKS device for `clevis luks list`.
    ROOT_LUKS_DEV_CANDIDATE=$(lsblk -o NAME,TYPE,FSTYPE,MOUNTPOINT | awk '$2=="crypt" && $4=="/" {print "/dev/"$1}')
    if [ -z "$ROOT_LUKS_DEV_CANDIDATE" ]; then
        # Fallback for complex layouts or if the root is on an LVM that's on LUKS.
        ROOT_LUKS_DEV_CANDIDATE=$(lsblk -o NAME,TYPE,MOUNTPOINT,PKNAME | grep ' / ' | awk '{print "/dev/"$4}' | xargs -I {} sh -c 'lsblk -no NAME,TYPE {} | grep crypt | awk "{print \"/dev/\"\$1}"')
    fi

    if [ -z "$ROOT_LUKS_DEV_CANDIDATE" ]; then
        rlLogWarning "Could not determine root LUKS device automatically. Falling back to /dev/vda2 for clevis luks list."
        ROOT_LUKS_DEV_CANDIDATE="/dev/vda2"
    else
        rlLogInfo "Detected root LUKS device for clevis list: ${ROOT_LUKS_DEV_CANDIDATE}"
    fi

    rlRun "sudo clevis luks list -d ${ROOT_LUKS_DEV_CANDIDATE} | grep 'tang' | grep 'tpm2' | grep 't=2'" 0 "Verify Clevis binding is present on root LUKS device"

    # Verify Tang server reachability from the *booted system*.
    rlLogInfo "Verifying Tang server reachability from the booted system (at ${TANG_IP})..."
    rlRun "curl -sfg http://${TANG_IP}:${TANG_SERVER_PORT}/adv -o /tmp/adv.jws" 0 "Download Tang advertisement from booted system"
    rlFileExists "/tmp/adv.jws" || rlDie "Tang advertisement not downloaded on booted system"

  rlPhaseEnd

  rlPhaseStartCleanup
    # Restore .ssh directory from backup
    rlRun "rlFileRestore" 0 "Restore ~/.ssh/"

    # No other cleanup needed in this test script, as Tang server and temporary
    # files are handled by the FMF plan's 'finish' phase or the overall TMT cleanup.
  rlPhaseEnd
rlJournalEnd