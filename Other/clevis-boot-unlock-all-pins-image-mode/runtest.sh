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

#!/bin/bash
# ... (BeakerLib boilerplate as before) ...

rlJournalStart
  rlPhaseStartSetup
    rlImport --all || rlDie "Import failed"
    rlRun "rlImport --all" 0 "Import libraries" || rlDie "cannot continue"

    LUKS_MAPPED_NAME="test_clevis_luks"
    LUKS_PASSPHRASE="testpassword" # Used for temporary open/close verification
    LUKS_MOUNT_POINT="/mnt/luks_test_verify"

    rlLogInfo "SELinux: $(getenforce)"
    if [ "$(getenforce)" = "Enforcing" ]; then
        rlLogInfo "Warning: SELinux is in Enforcing mode. Ensure policies allow LUKS operations."
    fi

  rlPhaseEnd

  rlPhaseStartTest "Verify Baked-in LUKS Device Readiness"
    rlLogInfo "Checking for LUKS mapped device: /dev/mapper/${LUKS_MAPPED_NAME}"

    # The LUKS device should be automatically opened by systemd-cryptsetup.service
    # due to the /etc/crypttab entry and luks-loop-setup.service
    # Check if the mapped device is active (cryptsetup status will indicate if open)
    rlRun -s "sudo cryptsetup status ${LUKS_MAPPED_NAME}" 0 "Verify LUKS device status" || {
        rlFail "LUKS device /dev/mapper/${LUKS_MAPPED_NAME} is not active. Check /etc/crypttab and luks-loop-setup.service."
        # For debugging, also check if the sparse file is attached as a loop device
        LUKS_IMAGE_PATH_IN_IMAGE="/var/lib/luks_test/test_luks_device.img"
        if [ -f "${LUKS_IMAGE_PATH_IN_IMAGE}" ]; then
            LOOP_DEV_STATUS=$(sudo losetup -j "${LUKS_IMAGE_PATH_IN_IMAGE}")
            rlLogInfo "Status of ${LUKS_IMAGE_PATH_IN_IMAGE}: ${LOOP_DEV_STATUS}"
        fi
        rlDie "Baked-in LUKS device is not ready."
    }
    rlLogInfo "LUKS device /dev/mapper/${LUKS_MAPPED_NAME} is active."

    # Verify filesystem
    rlLogInfo "Checking filesystem on /dev/mapper/${LUKS_MAPPED_NAME}..."
    rlRun -s "sudo fsck -n \"/dev/mapper/${LUKS_MAPPED_NAME}\"" 0 "Filesystem check on LUKS device" || {
        rlFail "Filesystem check failed on LUKS device /dev/mapper/${LUKS_MAPPED_NAME}."
        rlDie "Filesystem on baked-in LUKS device is corrupt."
    }
    rlLogInfo "Filesystem appears healthy."

    # Mount and verify test file
    rlLogInfo "Mounting LUKS device and verifying test file..."
    rlRun -s "sudo mkdir -p \"${LUKS_MOUNT_POINT}\"" 0 "Create mount point"
    rlRun -s "sudo mount \"/dev/mapper/${LUKS_MAPPED_NAME}\" \"${LUKS_MOUNT_POINT}\"" 0 "Mount LUKS device"
    rlRun -s "grep -q 'This is a test file for LUKS verification inside the image.' \"${LUKS_MOUNT_POINT}/luks_test_file.txt\"" 0 "Verify baked-in test file content"
    rlLogInfo "Test file verified in LUKS volume."
    rlRun -s "sudo umount \"${LUKS_MOUNT_POINT}\"" 0 "Unmount LUKS device"
    rlRun -s "sudo rmdir \"${LUKS_MOUNT_POINT}\"" 0 "Remove mount point"

    # For clevis boot unlock, the device should typically be closed.
    # If systemd-cryptsetup opened it, it might manage its state.
    # We explicitly close it here to ensure it's ready for clevis operations.
    rlLogInfo "Closing LUKS device ${LUKS_MAPPED_NAME} to prepare for clevis boot unlock tests."
    rlRun -s "sudo cryptsetup luksClose \"${LUKS_MAPPED_NAME}\"" 0 "Close LUKS device for clevis" || {
        rlFail "Failed to close LUKS device after verification. Clevis might not be able to unlock it."
        rlDie "LUKS device cleanup failed."
    }

    rlLogInfo "Baked-in LUKS device setup confirmed correct and ready for clevis boot unlock."
  rlPhaseEnd

  rlPhaseStartCleanup
    rlLogInfo "Cleanup phase for LUKS readiness check."
    sudo cryptsetup luksClose "${LUKS_MAPPED_NAME}" 2>/dev/null || true # Ensure it's closed
    rlRun "rlFileRestore"
  rlPhaseEnd
rlJournalEnd