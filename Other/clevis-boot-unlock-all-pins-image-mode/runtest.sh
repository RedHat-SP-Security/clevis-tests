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
#   This program is free software: you can redistribute it and/or
#   modify it under the terms of the GNU General Public License as
#   published by the Free Software Foundation, either version 2 of the
#   License, or (at your option) any later version.
#
#   This program is distributed in the hope that it will be
#   useful, but WITHOUT ANY WARRANTY; without even the implied
#   warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
#   See the GNU General Public License for more details.
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
        rlDie "ERROR: ${PERSISTENT_TANG_IP_FILE} not found!"
    fi

    rlLogInfo "Found Tang IP file:"
    cat "${PERSISTENT_TANG_IP_FILE}"

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
    rlRun "ls -l ${TPM_DEVICE}" 0 "Check TPM2_