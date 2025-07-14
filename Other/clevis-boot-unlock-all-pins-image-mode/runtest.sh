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
LUKS_IMAGE_PATH="/var/lib/luks.img"
DEVICE="/dev/loop7" # Still need a loop device, will find an available one.
MAPPER_NAME="luks-test"
MOUNT_POINT="/mnt/luks"
TANG_IP_FILE="/etc/clevis-test-data/tang_ip.txt"
TANG_PORT_FILE="/etc/clevis-test-data/tang_port.txt"
TANG_DIR="/var/db/tang" # Use the standard, persistent Tang data directory

rlJournalStart
    rlPhaseStartSetup
        # Assert persistent files exist on the new image
        rlAssertExists "$LUKS_IMAGE_PATH" "Assert the persistent LUKS image exists"
        rlAssertExists "$TANG_IP_FILE" "Assert tang_ip.txt exists in /etc"
        rlAssertExists "$TANG_PORT_FILE" "Assert tang_port.txt exists in /etc"
        mkdir -p "$MOUNT_POINT"

        # Dynamically create the loop device on the *booted image*
        # This is essential because loop devices are transient.
        OLD_DEVICE="$DEVICE" # Store old hardcoded value just in case
        DEVICE=$(losetup --find --show "$LUKS_IMAGE_PATH") || {
            rlFail "Failed to set up loop device for $LUKS_IMAGE_PATH on booted image."
            exit 1
        }
        rlLog "Loop device created on booted image: $DEVICE"


        # Read Tang info from files baked into the image
        TANG_IP=$(cat "$TANG_IP_FILE") || rlFail "Failed to read Tang IP."
        TANG_PORT=$(cat "$TANG_PORT_FILE") || rlFail "Failed to read Tang Port."
        export TANG_URL="http://${TANG_IP}:${TANG_PORT}" # Construct the URL for clevis

        # Ensure systemd tangd.socket is active and listening on the configured port.
        # This will trigger tangd.service if it's not already running.
        rlRun "systemctl is-active tangd.socket || systemctl start tangd.socket" \
            "Ensure tangd.socket is active on the booted image"
        rlRun "sleep 2" # Give it a moment to become truly active

        # Verify Tang is reachable from the test context (on the booted image)
        rlRun "curl -s \"${TANG_URL}/adv\" -o /tmp/adv.json" \
            "Verify Tang server is up and reachable on ${TANG_URL}"
    rlPhaseEnd

    rlPhaseStartTest "Verify Clevis bindings and unlock ability"
        # Open LUKS device for clevis commands to work on it
        rlRun "echo -n 'password' | cryptsetup open $DEVICE $MAPPER_NAME" \
            "Open LUKS device for clevis list/unlock"

        # Check for TPM2 binding (optional - depends on host TPM presence during prepare)
        # We allow this to fail if TPM was not present during prepare.
        rlRun "clevis luks list -d /dev/mapper/$MAPPER_NAME | grep tpm2" || \
            rlLog "TPM2 binding not found (expected if no TPM device during prepare)."
        rlRun "clevis luks list -d /dev/mapper/$MAPPER_NAME | grep tang" \
            "Verify Tang binding is present"

        # The core of the test: Try to unlock the LUKS device using Clevis
        # This simulates the boot unlock process.
        rlRun "clevis luks unlock -d /dev/mapper/$MAPPER_NAME" \
            "Unlock LUKS device using Clevis (Tang pin) after image boot"
    rlPhaseEnd

    rlPhaseStartTest "Verify content of unlocked device"
        # The device should now be open as /dev/mapper/luks-test implicitly by clevis unlock
        rlAssertExists "/dev/mapper/$MAPPER_NAME" "Verify LUKS device is open after clevis unlock"
        rlRun "mount /dev/mapper/$MAPPER_NAME $MOUNT_POINT" \
            "Mount unlocked LUKS filesystem"
        rlAssertExists "$MOUNT_POINT/hello.txt"
        rlRun "grep -q 'Test file' $MOUNT_POINT/hello.txt" \
            "Verify content of test file"
        rlRun "umount $MOUNT_POINT" \
            "Unmount LUKS filesystem"
        rlRun "cryptsetup close $MAPPER_NAME" \
            "Close LUKS device"
    rlPhaseEnd

    rlPhaseStartCleanup
        # Stop tangd.socket to clean up the service
        rlRun "systemctl stop tangd.socket || true" \
            "Stop tangd.socket for cleanup"
        # Detach loop device if still active
        rlRun "losetup -d $DEVICE || true" \
            "Detach loop device for cleanup"
        # Clean up temporary files created by the test script itself, if any.
        # No need to remove /var/lib/luks.img or /var/db/tang
        # as they are now part of the persistent image and managed by its lifecycle.
    rlPhaseEnd
rlJournalEnd