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
    TANG_IP=$(ip addr show $(ip route get 1 | awk '{print $5; exit}') | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    export TANG_SERVER=${TANG_IP} # Export for the post-install script
  rlPhaseEnd

  rlPhaseStartTest "LUKS and Clevis Setup"
    # This section runs after the initial bootc_prepare_test and subsequent reboot.
    # We check for a "first_boot_done" cookie to ensure LUKS setup happens only once.
    if [ ! -f /var/tmp/first_boot_done ]; then
      rlLogInfo "First boot after image preparation. Setting up LUKS device."

      # Find a suitable disk for LUKS setup. Exclude the root device.
      # This example assumes /dev/vdb is available and suitable. Adjust as needed.
      # In a real scenario, you might need more robust disk selection.
      TARGET_DISK="/dev/vdb" # Replace with the actual disk you want to use
      if [ ! -b "${TARGET_DISK}" ]; then
        rlDie "Target disk ${TARGET_DISK} not found or not a block device."
      fi

      rlRun "echo -n 'password' | cryptsetup luksFormat ${TARGET_DISK} --type luks2 -" 0 "Format disk with LUKS2"
      rlRun "echo -n 'password' | cryptsetup luksOpen ${TARGET_DISK} myluksdev -" 0 "Open LUKS device"
      rlRun "mkfs.ext4 /dev/mapper/myluksdev" 0 "Create filesystem on LUKS device"
      rlRun "mkdir -p /mnt/luks_test" 0 "Create mount point"
      rlRun "mount /dev/mapper/myluksdev /mnt/luks_test" 0 "Mount LUKS device"

      # Install clevis-dracut if not already present
      rlRun "dnf -y install clevis-dracut" 0 "Install clevis-dracut"

      # Download Tang advertisement
      rlRun "curl -sfg http://${TANG_SERVER}/adv -o /adv.jws" 0 "Download Tang advertisement"

      # Bind LUKS device with Tang and TPM2
      # This part replicates the logic from the clevis-boot-unlock-all-pins script.
      # We assume the LUKS device is named 'myluksdev' from the luksOpen command above.
      rlRun "clevis luks bind -d ${TARGET_DISK} sss '{\"t\":2,\"pins\":{\"tang\":[{\"url\":\"http://\"\"${TANG_SERVER}\"\"\",\"adv\":\"/adv.jws\"}], \"tpm2\": {\"pcr_bank\":\"sha256\", \"pcr_ids\":\"0,7\"}}}' <<< 'password'" 0 "Bind clevis to LUKS device"

      # Enable clevis-luks-askpass
      rlRun "systemctl enable clevis-luks-askpass.path" 0 "Enable clevis-luks-askpass"

      # Configure dracut for network access
      rlRun "mkdir -p /etc/dracut.conf.d/" 0 "Create dracut.conf.d"
      rlRun "echo 'kernel_cmdline=\"rd.neednet=1\"' > /etc/dracut.conf.d/10mt-ks-post-clevis.conf" 0 "Add kernel command line for network"
      rlRun "dracut -f --regenerate-all" 0 "Regenerate initramfs"

      rlRun "touch /var/tmp/first_boot_done" 0 "Mark first boot as done"
      rlLogInfo "LUKS device and Clevis setup complete. Rebooting to test unlock."
      rlRun "systemctl reboot" 0 "Rebooting system"
      rlWait 300 # Give system time to reboot
      # After reboot, the test will restart from setup, but this time
      # /var/tmp/first_boot_done will exist, skipping this block.
    else
      rlLogInfo "Post-reboot: Verifying LUKS unlock and Clevis status."

      # Check if the LUKS device is unlocked and mounted
      rlRun "lsblk | grep myluksdev" 0 "Verify myluksdev is present"
      rlRun "mount | grep /mnt/luks_test" 0 "Verify /mnt/luks_test is mounted"

      # Check journal for successful clevis-luks-askpass operation
      if rlIsRHELLike '>=10'; then
        rlRun "journalctl -b | grep \"Finished systemd-cryptsetup\"" 0 "Check journal for cryptsetup finish (RHEL10+)"
      else
        rlRun "journalctl -b | grep \"Finished Cryptography Setup for luks-\"" 0 "Check journal for cryptsetup finish"
        rlRun "journalctl -b | grep \"clevis-luks-askpass.service: Deactivated successfully\"" 0 "Check journal for clevis-luks-askpass deactivation"
      fi

      rlLogInfo "LUKS device successfully unlocked and mounted via Clevis with Tang/TPM2."
    fi
  rlPhaseEnd

  rlPhaseStartCleanup
    rlLogInfo "Starting cleanup phase."
    # Unmount and close LUKS device if it's still active
    if mountpoint -q /mnt/luks_test; then
      rlRun "umount /mnt/luks_test" ||:
    fi
    if cryptsetup status myluksdev &>/dev/null; then
      rlRun "cryptsetup luksClose myluksdev" ||:
    fi

    # Remove the first boot cookie
    rlRun "rm -f /var/tmp/first_boot_done" ||:
    rlRun "rm -f /adv.jws" ||:
    rlRun "rm -f /etc/dracut.conf.d/10mt-ks-post-clevis.conf" ||:
    rlRun "dracut -f --regenerate-all" ||: # Regenerate initramfs to clean up
  rlPhaseEnd
rlJournalEnd