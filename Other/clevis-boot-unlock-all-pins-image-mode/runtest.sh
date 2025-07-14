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
. /usr/share/beakerlib/beakerlib.sh || exit 1

# CHANGE: Use /var/lib/ for persistent image
DEVICE="/dev/loop7"
IMAGE_PATH="/var/lib/luks.img"
MAPPER_NAME="luks-test"
MOUNT_POINT="/mnt/luks"
TANG_IP_FILE="/etc/clevis-test-data/tang_ip.txt"
TANG_PORT_FILE="/etc/clevis-test-data/tang_port.txt"

rlJournalStart
    rlPhaseStartSetup
        rlAssertExists "$IMAGE_PATH"
        rlAssertExists "$TANG_IP_FILE"
        rlAssertExists "$TANG_PORT_FILE"
        mkdir -p "$MOUNT_POINT"

        rlRun "losetup $DEVICE $IMAGE_PATH"

        TANG_IP=$(cat "$TANG_IP_FILE")
        TANG_PORT=$(cat "$TANG_PORT_FILE")
        TANG_URL="http://$TANG_IP:$TANG_PORT"

        rlRun "systemctl start tangd.socket || true"
        rlRun "sleep 2"
        rlRun "curl -s \"$TANG_URL/adv\" -o /tmp/adv.json"
    rlPhaseEnd

    rlPhaseStartTest "Verify Clevis bindings and unlock"
        rlRun "clevis luks list -d $DEVICE | grep -q tang"
        rlRun "clevis luks unlock -d $DEVICE"

        rlAssertExists "/dev/mapper/$MAPPER_NAME"
        rlRun "mount /dev/mapper/$MAPPER_NAME $MOUNT_POINT"
        rlAssertExists "$MOUNT_POINT/hello.txt"
        rlRun "grep -q 'Test file' $MOUNT_POINT/hello.txt"
        rlRun "umount $MOUNT_POINT"
        rlRun "cryptsetup close $MAPPER_NAME"
    rlPhaseEnd

    rlPhaseStartCleanup
        rlRun "losetup -d $DEVICE || true"
        rlRun "systemctl stop tangd.socket || true"
    rlPhaseEnd
rlJournalEnd