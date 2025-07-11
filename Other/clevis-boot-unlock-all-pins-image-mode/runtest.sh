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

rlJournalStart
  rlPhaseStartSetup
    rlImport --all || rlDie "Import failed"
    rlRun "rlImport --all" 0 "Import libraries" || rlDie "cannot continue"

    # Define variables consistent with your setup scripts
    # These must match what's set up by setup_clevis_env_for_bootc.sh
    # and post_boot_luks_setup.sh
    LUKS_MAPPED_NAME="test_clevis_luks"
    LUKS_MOUNT_POINT="/mnt/luks_test" # This is just for temporary mount, not required to exist now.
    LUKS_IMAGE_FILENAME="test_luks_device.img" # If using sparse file
    LUKS_DEVICE_PATH_IN_IMAGE="/var/tmp/tmt/${LUKS_IMAGE_FILENAME}" # Where the sparse file is in the image
    LUKS_PASSPHRASE="testpassword" # The passphrase used to format the LUKS device

    # Check for SELinux status for informational purposes
    rlLogInfo "SELinux: $(getenforce)"
    if [ "$(getenforce)" = "Enforcing" ]; then
        rlLogWarn "SELinux is in Enforcing mode. Ensure policies allow LUKS operations."
    fi

  rlPhaseEnd

  rlPhaseStartTest "Verify LUKS Device Readiness"
    rlLogInfo "Checking for LUKS mapped device: /dev/mapper/${LUKS_MAPPED_NAME}"

    # We expect the 'post_boot_luks_setup.sh' to have already attached the loop device
    # and potentially opened it, or prepared the crypttab so it's ready.
    # We primarily need to confirm the LUKS device (whether mapped or underlying) is present and recognizable.

    DEVICE_TO_CHECK=""

    # First, check if the mapped device is already open. This is the ideal state if crypttab worked.
    if [ -b "/dev/mapper/${LUKS_MAPPED_NAME}" ]; then
        rlLogInfo "LUKS mapped device /dev/mapper/${LUKS_MAPPED_NAME} found."
        DEVICE_TO_CHECK="/dev/mapper/${LUKS_MAPPED_NAME}"
    fi

    # If the mapped device isn't directly found (e.g., if it wasn't opened via crypttab yet),
    # check for the underlying sparse file and its loop device.
    if [ -z "${DEVICE_TO_CHECK}" ] && [ -f "${LUKS_DEVICE_PATH_IN_IMAGE}" ]; then
        rlLogInfo "LUKS mapped device not found directly. Checking for underlying sparse image: ${LUKS_DEVICE_PATH_IN_IMAGE}"
        LOOP_DEVICE=$(sudo losetup -j "${LUKS_DEVICE_PATH_IN_IMAGE}" | awk -F: '{print $1}')
        if [ -n "${LOOP_DEVICE}" ]; then
            rlLogInfo "Sparse image is attached as loop device: ${LOOP_DEVICE}"
            DEVICE_TO_CHECK="${LOOP_DEVICE}"
        else
            rlFail "Sparse image file ${LUKS_DEVICE_PATH_IN_IMAGE} exists but is NOT attached as a loop device. This indicates post_boot_luks_setup.sh issue."
            exit 1
        fi
    fi

    # If no device was found to check, fail the test
    if [ -z "${DEVICE_TO_CHECK}" ]; then
        rlFail "Neither LUKS mapped device (/dev/mapper/${LUKS_MAPPED_NAME}) nor underlying loop device from sparse image (${LUKS_DEVICE_PATH_IN_IMAGE}) found."
        rlDie "Cannot proceed with LUKS verification."
    fi

    # Verify that the device is indeed a LUKS header
    rlLogInfo "Verifying ${DEVICE_TO_CHECK} is a LUKS device..."
    LUKS_HEADER_UUID=$(sudo cryptsetup luksUUID "${DEVICE_TO_CHECK}" 2>/dev/null)
    if [ -z "$LUKS_HEADER_UUID" ]; then
        rlFail "${DEVICE_TO_CHECK} is not identified as a LUKS device by cryptsetup."
        rlDie "LUKS header missing or corrupted."
    fi
    rlLogInfo "LUKS device header confirmed. UUID: ${LUKS_HEADER_UUID}"

    # Attempt to open it with the test passphrase to confirm it's functional
    # This also ensures the crypttab entry (if used for auto-open) is correct.
    rlLogInfo "Attempting to open LUKS device with test passphrase for functional check..."
    rlRun -s "echo -n \"${LUKS_PASSPHRASE}\" | sudo cryptsetup luksOpen \"${DEVICE_TO_CHECK}\" \"${LUKS_MAPPED_NAME}_temp_open\" -d -" 0 "Open LUKS device with passphrase" || {
        rlFail "Failed to open LUKS device with passphrase. LUKS setup is incorrect or device is corrupted."
        rlDie "LUKS device is not functional."
    }
    rlLogInfo "LUKS device successfully opened with test passphrase as /dev/mapper/${LUKS_MAPPED_NAME}_temp_open."

    # Verify filesystem (optional but good, ensures it's readable)
    rlLogInfo "Checking filesystem on /dev/mapper/${LUKS_MAPPED_NAME}_temp_open..."
    rlRun -s "sudo fsck -n \"/dev/mapper/${LUKS_MAPPED_NAME}_temp_open\"" 0 "Filesystem check on LUKS device" || {
        rlFail "Filesystem check failed on LUKS device."
        # Attempt to close it before exiting
        sudo cryptsetup luksClose "${LUKS_MAPPED_NAME}_temp_open" 2>/dev/null || true
        rlDie "Filesystem on LUKS device is corrupt."
    }
    rlLogInfo "Filesystem appears healthy."

    # Mount and verify test file (if it was placed there during setup)
    rlLogInfo "Mounting LUKS device and verifying test file..."
    rlRun -s "sudo mkdir -p \"${LUKS_MOUNT_POINT}\"" 0 "Create mount point"
    rlRun -s "sudo mount \"/dev/mapper/${LUKS_MAPPED_NAME}_temp_open\" \"${LUKS_MOUNT_POINT}\"" 0 "Mount LUKS device"
    rlRun -s "grep -q 'This is a test file for LUKS verification.' \"${LUKS_MOUNT_POINT}/luks_test_file.txt\"" 0 "Verify test file content"
    rlLogInfo "Test file verified in LUKS volume."
    rlRun -s "sudo umount \"${LUKS_MOUNT_POINT}\"" 0 "Unmount LUKS device"
    rlRun -s "sudo rmdir \"${LUKS_MOUNT_POINT}\"" 0 "Remove mount point"

    # Close the LUKS device to prepare for clevis unlock tests
    rlLogInfo "Closing LUKS device /dev/mapper/${LUKS_MAPPED_NAME}_temp_open to prepare for clevis boot unlock tests."
    rlRun -s "sudo cryptsetup luksClose \"${LUKS_MAPPED_NAME}_temp_open\"" 0 "Close LUKS device" || {
        rlFail "Failed to close LUKS device after verification."
        rlDie "LUKS device cleanup failed."
    }

    rlLogInfo "LUKS device setup confirmed to be correct and ready for clevis boot unlock with pins."
  rlPhaseEnd

  rlPhaseStartCleanup
    rlLogInfo "Cleanup phase for LUKS readiness check."
    # The vm library stuff from your example is not relevant here as we're on the booted bootc image.
    # The only cleanup needed might be for the loop device if you are using a sparse file
    # and it was left open, or if the test failed prematurely.
    # Ensure any temporary mapped devices are closed.
    sudo cryptsetup luksClose "${LUKS_MAPPED_NAME}_temp_open" 2>/dev/null || true
    sudo cryptsetup luksClose "${LUKS_MAPPED_NAME}" 2>/dev/null || true # In case it was opened by crypttab
    
    # If using a sparse file, ensure the loop device is detached
    LUKS_IMAGE_FILENAME="test_luks_device.img"
    LUKS_DEVICE_PATH_IN_IMAGE="/var/tmp/tmt/${LUKS_IMAGE_FILENAME}"
    if [ -f "${LUKS_DEVICE_PATH_IN_IMAGE}" ]; then
        LOOP_DEVICE=$(sudo losetup -j "${LUKS_DEVICE_PATH_IN_IMAGE}" | awk -F: '{print $1}')
        if [ -n "${LOOP_DEVICE}" ]; then
            rlLogInfo "Detaching loop device ${LOOP_DEVICE} from ${LUKS_DEVICE_PATH_IN_IMAGE}."
            sudo losetup -d "${LOOP_DEVICE}" || true
        fi
    fi

    rlRun "rlFileRestore" # Restore files if beakerlib created backups
  rlPhaseEnd
rlJournalEnd