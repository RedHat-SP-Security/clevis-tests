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

# Constants
TANG_SERVER_PORT="8080"
PERSISTENT_DATA_DIR="/etc/clevis-test-data"
PERSISTENT_TANG_IP_FILE="${PERSISTENT_DATA_DIR}/tang_ip.txt"

rlJournalStart
  rlPhaseStartSetup
    rlImport --all || rlDie "Import failed"

    rlLogInfo "SELinux: $(getenforce)"

    # SSH Setup
    rlRun "rlFileBackup --clean ~/.ssh/" 0
    rlRun "mkdir -p ~/.ssh"
    rlRun "chmod 700 ~/.ssh"
    rlRun "rm -f ~/.ssh/known_hosts"
    cat << EOF > ~/.ssh/config
Host *
  user root
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel QUIET
EOF
    rlRun "chmod 600 ~/.ssh/config"

    # Check for persisted Tang IP
    if [ ! -f "${PERSISTENT_TANG_IP_FILE}" ]; then
        echo "ERROR: ${PERSISTENT_TANG_IP_FILE} not found!"
    else
        echo "Found Tang IP file:"
        cat "${PERSISTENT_TANG_IP_FILE}"
    fi

    TANG_IP=$(cat "${PERSISTENT_TANG_IP_FILE}" 2>/dev/null)
    rlAssertNotEquals "Tang server IP not found in ${PERSISTENT_TANG_IP_FILE}." "" "$TANG_IP"
    rlLogInfo "Tang server: ${TANG_IP}:${TANG_SERVER_PORT}"
  rlPhaseEnd

  rlPhaseStartTest "Verify Boot Unlock (Post-Reboot)"
    # TPM2 detection
    if [ -e /dev/tpmrm0 ]; then
      TPM_DEVICE="/dev/tpmrm0"
    elif [ -e /dev/tpm0 ]; then
      TPM_DEVICE="/dev/tpm0"
    else
      rlDie "No TPM2 device found (neither /dev/tpmrm0 nor /dev/tpm0)"
    fi
    rlRun "ls -l ${TPM_DEVICE}" 0 "Check TPM2 device"

    # Journal checks
    if rlIsRHELLike '>=10'; then
      rlRun "journalctl -b | grep 'Finished systemd-cryptsetup'" 0
    else
      rlRun "journalctl -b | grep 'Finished Cryptography Setup for luks-'" 0
      rlRun "journalctl -b | grep 'clevis-luks-askpass.service: Deactivated successfully'" 0
    fi

    # Root LUKS detection
    rlRun "lsblk -no FSTYPE,MOUNTPOINT | grep 'crypto_LUKS /'" 0
    rlRun "sudo cryptsetup status root | grep 'cipher: aes-cbc-essiv:sha256'" 0
    rlRun "sudo cryptsetup status root | grep 'active one key slot'" 0

    ROOT_LUKS_DEV_CANDIDATE=$(lsblk -o NAME,TYPE,FSTYPE,MOUNTPOINT | awk '$2=="crypt" && $4=="/" {print "/dev/"$1}')
    if [ -z "$ROOT_LUKS_DEV_CANDIDATE" ]; then
        ROOT_LUKS_DEV_CANDIDATE=$(lsblk -o NAME,TYPE,MOUNTPOINT,PKNAME | grep ' / ' | awk '{print "/dev/"$4}' | xargs -I {} sh -c 'lsblk -no NAME,TYPE {} | grep crypt | awk "{print \"/dev/\"\$1}"')
    fi
    if [ -z "$ROOT_LUKS_DEV_CANDIDATE" ]; then
        rlLogWarning "Could not auto-detect LUKS device; fallback to /dev/vda2"
        ROOT_LUKS_DEV_CANDIDATE="/dev/vda2"
    else
        rlLogInfo "Detected root LUKS device: ${ROOT_LUKS_DEV_CANDIDATE}"
    fi

    rlRun "sudo clevis luks list -d ${ROOT_LUKS_DEV_CANDIDATE} | grep 'tang' | grep 'tpm2' | grep 't=2'" 0

    # Tang server test
    rlLogInfo "Testing reachability of Tang server at ${TANG_IP}:${TANG_SERVER_PORT}..."
    rlRun "curl -sfg http://${TANG_IP}:${TANG_SERVER_PORT}/adv -o /tmp/adv.jws" 0
    rlFileExists "/tmp/adv.jws" || rlDie "Tang advertisement not downloaded"
  rlPhaseEnd

  rlPhaseStartCleanup
    rlRun "rlFileRestore" 0 "Restore ~/.ssh/"
  rlPhaseEnd
rlJournalEnd