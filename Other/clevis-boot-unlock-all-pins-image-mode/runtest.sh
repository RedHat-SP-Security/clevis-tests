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
COOKIE=/var/tmp/clevis_setup_done
# REBOOT_COOKIE will mark if the system has already rebooted after setup
REBOOT_COOKIE=/var/tmp/rebooted_after_clevis_setup

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
    # TANG_PORT is often dynamic for tangd.socket, but if it's explicitly set, use it.
    # Otherwise, assume default HTTP/HTTPS ports (80/443) or check `tangd.socket` unit for actual port.
    # For simplicity, if not explicitly defined, we will use HTTP 80 later.
    # If your tangd.socket is truly dynamic and only accessible via a specific port in Beaker,
    # you might need a way to extract it here, e.g., from `journalctl -u tangd.socket`.
    # For now, let's just ensure TANG_IP is correct.
    rlLog "Tang IP: ${TANG_IP}"
    export TANG_SERVER=${TANG_IP} # Export for the clevis-boot-unlock-all-pins script

    # Ensure clevis-dracut is available. In Image Mode, this usually means it's part of the base image.
    # If not, this step would fail or be ineffective across reboots.
    rlRun "rpm -q clevis-dracut" 0 "Verify clevis-dracut is installed (expected in image)" || rlDie "clevis-dracut not found, ensure it's in the base image."
  rlPhaseEnd

  rlPhaseStartTest "LUKS and Clevis Setup and Verification"
    # This block runs the initial setup. It should execute only once.
    if [ ! -e "$COOKIE" ]; then
      rlLogInfo "Initial run: Setting up LUKS device and Clevis binding."

      # Find a suitable disk for LUKS setup. Exclude the root device.
      # IMPORTANT: Replace "/dev/vdb" with the actual path to your target disk.
      # This disk must be available and safe to wipe.
      TARGET_DISK="/dev/vdb"
      if [ ! -b "${TARGET_DISK}" ]; then
        rlDie "Target disk ${TARGET_DISK} not found or not a block device. Please configure TARGET_DISK."
      fi

      rlLogInfo "Formatting ${TARGET_DISK} with LUKS2."
      # Use a simple password for testing. In production, use strong, random passwords.
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
      # Ensure tangd is listening on the correct port and accessible. Default HTTP port is 80.
      rlRun "curl -sfg http://${TANG_SERVER}/adv -o /adv.jws" 0 "Download Tang advertisement"

      rlLogInfo "Binding Clevis to LUKS device ${TARGET_DISK} with Tang and TPM2 pins."
      # This command requires the LUKS device to be closed for binding to persist in initramfs.
      # The password "password" is for the initial Clevis binding, not for unlocking.
      rlRun "clevis luks bind -d ${TARGET_DISK} sss '{\"t\":2,\"pins\":{\"tang\":[{\"url\":\"http://\"\"${TANG_SERVER}\"\"\",\"adv\":\"/adv.jws\"}], \"tpm2\": {\"pcr_bank\":\"sha256\", \"pcr_ids\":\"0,7\"}}}' <<< 'password'" 0 "Bind Clevis to LUKS device with Tang and TPM2"

      rlLogInfo "Enabling clevis-luks-askpass and configuring dracut for network."
      # These changes *must* be persistent for Image Mode. If not, they need to be part of the image build.
      # Assumed that `clevis-boot-unlock-all-pins` snippet (which includes these steps)
      # is executed during `bootc install`. If not, manual `systemctl enable` and `dracut -f` might not persist.
      rlRun "systemctl enable clevis-luks-askpass.path" 0 "Enable clevis-luks-askpass (if not already enabled by snippet)"
      rlRun "mkdir -p /etc/dracut.conf.d/" 0 "Ensure dracut.conf.d exists"
      rlRun "echo 'kernel_cmdline=\"rd.neednet=1\"' > /etc/dracut.conf.d/10-clevis-net.conf" 0 "Add kernel command line for network to dracut"
      rlRun "dracut -f --regenerate-all" 0 "Regenerate initramfs to include Clevis and network settings"

      rlLogInfo "Initial setup complete. Rebooting to test automatic unlock."
      rlRun "systemctl reboot" 0 "Trigger system reboot"
      rlWait 300 # Wait for the system to reboot
      rlRun "touch \"$COOKIE\"" 0 "Mark that system has rebooted after setup" # This will run on the first boot after the reboot
    else # This block runs on subsequent boots after the initial setup

      rlLogInfo "Post-reboot: Verifying LUKS automatic unlock and mount."

      # Verify the LUKS device is automatically unlocked and mounted.
      # We check for the device mapper name 'myluksdev' and its mount point.
      rlRun "lsblk | grep myluksdev" 0 "Verify myluksdev is present and unlocked"
      rlRun "mount | grep /mnt/luks_test" 0 "Verify /mnt/luks_test is mounted"
      rlRun "cat /mnt/luks_test/testfile.txt | grep 'Test data for LUKS device'" 0 "Verify data integrity on LUKS device"

      # Check journal for successful clevis-luks-askpass operation.
      # The messages might differ slightly based on RHEL/Fedora versions.
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

    # Clean up cookies and temporary files
    rlRun "rm -f \"$COOKIE\"" ||: "Failed to remove COOKIE."
    rlRun "rm -f /adv.jws" ||: "Failed to remove /adv.jws."
    rlRun "rm -f /etc/dracut.conf.d/10-clevis-net.conf" ||: "Failed to remove dracut config."
    # Regenerate initramfs to remove changes made by the test for clean state.
    # This might fail on read-only root filesystems, but it's good practice.
    rlRun "dracut -f --regenerate-all" ||: "Failed to regenerate initramfs during cleanup."
    rlRun "rm -f /loopfile" ||: "Failed to remove loopfile."
  rlPhaseEnd
rlJournalEnd