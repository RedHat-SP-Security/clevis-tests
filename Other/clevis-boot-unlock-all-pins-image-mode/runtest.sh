#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /clevis-tests/luks-setup-check
#   Description: Checks if the LUKS device for clevis boot unlock is correctly set up and accessible
#                on a bootc Image Mode system.
#   Author: Karel Srot <ksrot@redhat.com>
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
#   PURPOSE.  See the GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program. If not, see http://www.gnu.org/licenses/.
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Include Beaker environment
. /usr/share/beakerlib/beakerlib.sh || exit 1

DEVICE="/dev/loop7"
MAPPER_NAME="luks-test"
MOUNT_POINT="/mnt/luks"
TANG_IP_FILE="/etc/clevis-test-data/tang_ip.txt"
TANG_PORT_FILE="/etc/clevis-test-data/tang_port.txt"
TANG_DIR="/var/tmp/tang"

rlJournalStart
    rlPhaseStartSetup
        rlAssertExists "$DEVICE"
        rlAssertExists "$TANG_IP_FILE"
        rlAssertExists "$TANG_PORT_FILE"
        mkdir -p "$MOUNT_POINT"
    rlPhaseEnd

    rlPhaseStartTest "Restart Tang server"
        TANG_IP=$(cat "$TANG_IP_FILE")
        TANG_PORT=$(cat "$TANG_PORT_FILE")
        export TANG_KEYS="${TANG_DIR}/db"
        rlRun "tangd $TANG_DIR $TANG_PORT &"
        rlRun "sleep 2"
    rlPhaseEnd

    rlPhaseStartTest "Verify Clevis bindings"
        rlRun "clevis luks list -d $DEVICE | grep tpm2"
        rlRun "clevis luks list -d $DEVICE | grep tang"
        rlRun "clevis luks list -d $DEVICE | grep sss"
    rlPhaseEnd

    rlPhaseStartTest "Unlock and verify content"
        rlRun "cryptsetup open $DEVICE $MAPPER_NAME"
        rlRun "mount /dev/mapper/$MAPPER_NAME $MOUNT_POINT"
        rlAssertExists "$MOUNT_POINT/hello.txt"
        rlRun "grep -q 'Test file' $MOUNT_POINT/hello.txt"
        rlRun "umount $MOUNT_POINT"
        rlRun "cryptsetup close $MAPPER_NAME"
    rlPhaseEnd

    rlPhaseStartCleanup
        killall tangd || true
    rlPhaseEnd
rlJournalEnd