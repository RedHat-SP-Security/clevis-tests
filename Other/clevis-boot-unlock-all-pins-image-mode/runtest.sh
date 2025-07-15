#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /clevis-tests/Otherl/tang-boot-unlock-all-pins-image-mode
#   Description: Test of clevis boot unlock via all possible pins (tang, tpm2) and using sss on Image Mode.
#   Author: Adam Prikryl <aprikryl@redhat.com>
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
. /usr/share/beakerlib/beakerlib.sh || exit 1

# COOKIE will mark if the initial setup (LUKS format, Clevis bind) has run
# This cookie needs to be in a persistent location across reboots.
COOKIE=/var/opt/clevis_setup_done

# Global variable to store the loop device path.
# This variable's value is transient for each script execution,
# but the underlying /var/opt/loopfile provides persistence.
LOOP_DEV=""

rlJournalStart
  rlPhaseStartSetup
    rlImport --all || rlDie "Import failed"
    rlRun "rlImport --all" 0 "Import libraries" || rlDie "cannot continue"

    rlLogInfo "DISABLE_SELINUX(${DISABLE_SELINUX})"
    if [ -n "${DISABLE_SELINUX}" ]; then
      rlRun "setenforce 0" 0 "Putting SELinux in Permissive mode"
    fi
    rlLogInfo "SELinux: $(getenforce)"

    # Set up Tang server
    rlServiceStart tangd.socket
    rlServiceStatus tangd.socket
    # Determine Tang IP dynamically
    TANG_IP=$(ip addr show $(ip route get 1 | awk '{print $5; exit}') | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    rlLog "Tang IP: ${TANG_IP}"
    export TANG_SERVER=${TANG_IP} # Export for the clevis-boot-unlock-all-pins script

    # Ensure clevis-dracut is available. In Image Mode, this usually means it's part of the base image.
    rlRun "rpm -q clevis-dracut" 0 "Verify clevis-dracut is installed (expected in image)" || rlDie "clevis-dracut not found, ensure it's in the base image."
  rlPhaseEnd

  rlPhaseStartTest "LUKS and Clevis Setup and Verification"
    # This block runs the initial setup. It should execute only once.
    if [ ! -e "$COOKIE" ]; then
      # Check for TPM2 availability. If not present, skip the core LUKS setup.
      if [ ! -e "/dev/tpm0" ] && [ ! -e "/dev/tpmrm0" ]; then
        rlLogInfo "TPM2 device not found (/dev/tpm0 or /dev/tpmrm0). Skipping LUKS setup and Clevis binding with TPM2."
        rlJournalReport
        return 0 # Exit the phase successfully, but effectively skip the core logic.
      fi

      rlLogInfo "Initial run: Setting up LUKS device and Clevis binding."

      # --- START: Loop device setup ---
      rlLogInfo "Creating loop device for LUKS testing."
      # Ensure /var/opt exists and is writable for persistent files.
      rlRun "mkdir -p /var/opt" 0 "Ensure /var/opt directory exists for persistent data"
      # Create the backing file for the loop device in /var/opt/.
      rlRun "dd if=/dev/zero of=/var/opt/loopfile bs=1M count=50" 0 "Create loopfile in persistent storage"
      # Attach the loop device and capture its path.
      rlRun "LOOP_DEV=\$(losetup -f --show /var/opt/loopfile)" 0 "Create loop device from file"
      # Use the obtained loop device path as the target for LUKS.
      TARGET_DISK="${LOOP_DEV}"
      rlLogInfo "Using loop device ${TARGET_DISK} for LUKS."
      # --- END: Loop device setup ---

      rlLogInfo "Formatting ${TARGET_DISK} with LUKS2."
      rlRun "echo -n 'password' | cryptsetup luksFormat ${TARGET_DISK} --type luks2 -" 0 "Format disk with LUKS2"

      rlLogInfo "Opening LUKS device and creating filesystem."
      rlRun "echo -n 'password' | cryptsetup luksOpen ${TARGET_DISK} myluksdev -" 0 "Open LUKS device"
      rlRun "mkfs.ext4 /dev/mapper/myluksdev" 0 "Create ext4 filesystem on LUKS device"
      rlRun "mkdir -p /mnt/luks_test" 0 "Create mount point for LUKS device"
      rlRun "mount /dev/mapper/myluksdev /mnt/luks_test" 0 "Mount LUKS device"
      rlRun "echo 'Test data for LUKS device' > /mnt/luks_test/testfile.txt" 0 "Write test data to LUKS device"
      rlRun "umount /mnt/luks_test" 0 "Unmount LUKS device"
      rlRun "cryptsetup luksClose myluksdev" 0 "Close LUKS device after initial setup"

      rlLogInfo "Downloading Tang advertisement."
      # Save Tang advertisement to a persistent location like /var/opt/.
      rlRun "curl -sfg http://${TANG_SERVER}/adv -o /var/opt/adv.jws" 0 "Download Tang advertisement"

      rlLogInfo "Binding Clevis to LUKS device ${TARGET_DISK} with Tang and TPM2 pins."
      # Ensure correct JSON syntax and use persistent adv path.
      rlRun "clevis luks bind -d ${TARGET_DISK} sss '{\"t\":2,\"pins\":{\"tang\":[{\"url\":\"http://${TANG_SERVER}\",\"adv\":\"/var/opt/adv.jws\"}], \"tpm2\": {\"pcr_bank\":\"sha256\", \"pcr_ids\":\"0,7\"}}}' <<< 'password'" 0 "Bind Clevis to LUKS device with Tang and TPM2"

      rlLogInfo "Enabling clevis-luks-askpass and configuring dracut for network."
      # These changes are expected to persist across reboots, ideally baked into the image
      # or handled by a persistent post-install script for Image Mode.
      rlRun "systemctl enable clevis-luks-askpass.path" 0 "Enable clevis-luks-askpass (if not already enabled by snippet)"
      rlRun "mkdir -p /etc/dracut.conf.d/" 0 "Ensure dracut.conf.d exists (writable overlay expected)"
      rlRun "echo 'kernel_cmdline=\"rd.neednet=1\"' > /etc/dracut.conf.d/10-clevis-net.conf" 0 "Add kernel command line for network to dracut (writable overlay expected)"
      rlRun "dracut -f --regenerate-all" 0 "Regenerate initramfs to include Clevis and network settings"

      rlRun "touch \"$COOKIE\"" 0 "Mark initial setup as complete"
      rlLogInfo "Initial setup complete. Triggering reboot via test runner."
      # Exit successfully. Your test runner (tmt/rhts) should be configured
      # to perform the reboot and re-execute this test script afterward.
      rhts-reboot # Keeping rhts-reboot as per your last snippet.

    else # This block runs on subsequent boots after the initial setup
      rlLogInfo "Post-reboot: Verifying LUKS automatic unlock and mount."

      # Re-create the loop device from its persistent backing file.
      rlLogInfo "Re-creating loop device for verification."
      rlRun "LOOP_DEV=\$(losetup -f --show /var/opt/loopfile)" 0 "Re-create loop device from persistent file for verification"
      TARGET_DISK="${LOOP_DEV}" # Ensure TARGET_DISK is set for verification steps.

      # Verify the LUKS device is automatically unlocked and mounted.
      rlRun "lsblk | grep myluksdev" 0 "Verify myluksdev is present and unlocked"
      rlRun "mount | grep /mnt/luks_test" 0 "Verify /mnt/luks_test is mounted"
      rlRun "cat /mnt/luks_test/testfile.txt | grep 'Test data for LUKS device'" 0 "Verify data integrity on LUKS device"

      # Check journal for successful clevis-luks-askpass operation.
      if rlIsRHELLike '>=10'; then
        rlRun "journalctl -b | grep \"Finished systemd-cryptsetup\"" 0 "Check journal for cryptsetup finish (RHEL10+)"
      else
        rlRun "journalctl -b | grep \"Finished Cryptography Setup for luks-\"" 0 "Check journal for cryptsetup finish"
        rlRun "journalctl -b | grep \"clevis-luks-askpass.service: Deactivated successfully\"" 0 "Check journal for clevis-luks-askpass deactivation"
      fi

      rlLogInfo "LUKS device successfully unlocked and mounted via Clevis with Tang/TPM2 pins."
    fi
  rlPhaseEnd

  rlPhaseStartCleanup
    rlLogInfo "Starting cleanup phase."
    # Unmount and close LUKS device if it's still active
    if mountpoint -q /mnt/luks_test; then
      rlRun "umount /mnt/luks_test" ||: "Failed to unmount /mnt/luks_test, continuing cleanup."
    fi
    if cryptsetup status myluksdev &>/dev/null; then
      rlRun "cryptsetup luksClose myluksdev" ||: "Failed to close myluksdev, continuing cleanup."
    fi

    # Clean up loop device if it exists
    if [ -n "${LOOP_DEV}" ] && losetup "${LOOP_DEV}" &>/dev/null; then
      rlRun "losetup -d ${LOOP_DEV}" ||: "Failed to detach loop device ${LOOP_DEV}."
    fi
    rlRun "rm -f /var/opt/loopfile" ||: "Failed to remove loopfile."

    # Clean up cookies and temporary files in /var/opt/
    rlRun "rm -f \"$COOKIE\"" ||: "Failed to remove COOKIE."
    # REBOOT_COOKIE removed from script, no need to clean up here.
    rlRun "rm -f /var/opt/adv.jws" ||: "Failed to remove /var/opt/adv.jws."
    rlRun "rm -f /etc/dracut.conf.d/10-clevis-net.conf" ||: "Failed to remove dracut config."
    # Regenerate initramfs to remove changes made by the test for clean state.
    rlRun "dracut -f --regenerate-all" ||: "Failed to regenerate initramfs during cleanup."
  rlPhaseEnd
rlJournalEnd