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
DEVICE="/dev/loop7" # This loop device needs to be re-created
IMAGE_PATH="/var/lib/luks.img" # <--- Use the persistent path from prepare
MAPPER_NAME="luks-test"
MOUNT_POINT="/mnt/luks"
TANG_IP_FILE="/etc/clevis-test-data/tang_ip.txt"
TANG_PORT_FILE="/etc/clevis-test-data/tang_port.txt"
TANG_DIR="/var/db/tang" # <--- Use the standard, persistent Tang data directory

rlJournalStart
    rlPhaseStartSetup
        rlAssertExists "$IMAGE_PATH" "Assert the persistent LUKS image exists"
        rlAssertExists "$TANG_IP_FILE"
        rlAssertExists "$TANG_PORT_FILE"
        mkdir -p "$MOUNT_POINT"

        # Re-create the loop device
        rlRun "losetup $DEVICE $IMAGE_PATH" \
            "Create loop device for persistent LUKS image"

        # Read Tang info from files created by prepare script
        TANG_IP=$(cat "$TANG_IP_FILE")
        TANG_PORT=$(cat "$TANG_PORT_FILE")
        export TANG_URL="http://${TANG_IP}:${TANG_PORT}" # Construct the URL for clevis

        # Ensure systemd tangd.socket is active. The prepare script configured and enabled it.
        # This will also activate tangd.service if it's not already running.
        rlRun "systemctl is-active tangd.socket || systemctl start tangd.socket" \
            "Ensure tangd.socket is active"
        rlRun "sleep 2" # Give it a moment to become truly active

        # Optional: Verify Tang is reachable from the test context before bindings check
        rlRun "curl -s \"${TANG_URL}/adv\" -o /tmp/adv.json" \
            "Verify Tang server is up and reachable"
    rlPhaseEnd

    rlPhaseStartTest "Verify Clevis bindings and unlock ability"
        # Since TPM2 bind is optional, check its presence.
        # This test relies on whether TPM was present during prepare.
        # For simplicity, if you expect it to always be absent in this test run, just grep tang.
        # If TPM is truly optional, and you don't want the test to fail if it's missing,
        # then the `grep tpm2` should be removed or made truly optional.
        # For now, keeping the `|| rlLog`
        rlRun "clevis luks list -d $DEVICE | grep tpm2" || rlLog "TPM2 binding not found (expected if no TPM device during prepare)."
        rlRun "clevis luks list -d $DEVICE | grep tang"

        # The core of the test: Try to unlock the LUKS device using Clevis
        # This will use the bound keys.
        # This is where the image mode boot unlock would happen via dracut.
        # We are manually doing it here for the test.
        rlRun "clevis luks unlock -d $DEVICE" \
            "Unlock LUKS device using Clevis (Tang pin)"
    rlPhaseEnd

    rlPhaseStartTest "Verify content of unlocked device"
        # The device should now be open as /dev/mapper/luks-test implicitly by clevis unlock
        rlAssertExists "/dev/mapper/$MAPPER_NAME" "Verify LUKS device is open"
        rlRun "mount /dev/mapper/$MAPPER_NAME $MOUNT_POINT" \
            "Mount unlocked LUKS filesystem"
        rlAssertExists "$MOUNT_POINT/hello.txt"
        rlRun "grep -q 'Test file' $MOUNT_POINT/hello.txt" \
            "Verify content of test file"
        rlRun "umount $MOUNT_POINT"
        rlRun "cryptsetup close $MAPPER_NAME" \
            "Close LUKS device"
    rlPhaseEnd

    rlPhaseStartCleanup
        # Stop tangd.socket to clean up the service
        rlRun "systemctl stop tangd.socket || true"
        # Remove loop device
        rlRun "losetup -d $DEVICE || true"
        # Clean up /var/lib/luks.img and /var/db/tang/ (if they were created by this test)
        # Note: If these were created in PREPARE and are persistent, you might NOT want to remove them in Cleanup
        # unless this test is designed to completely reset the system state.
        # If the next test depends on the LUKS image, don't remove it.
        # Assuming you want cleanup after the entire TMT run, a separate `finish` phase cleanup might be better.
        # For now, let's keep the cleanup to just what this test *created* or modified in its own scope.
        # Since the .img and tang_dir were created in PREPARE, you'd usually clean those in the TMT finish phase.
        # If this is a self-contained test, uncomment:
        # rlRun "rm -f $IMAGE_PATH || true"
        # rlRun "rm -rf $TANG_DIR || true"
    rlPhaseEnd
rlJournalEnd