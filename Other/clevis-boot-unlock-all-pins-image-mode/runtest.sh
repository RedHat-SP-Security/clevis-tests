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

# COOKIE will mark if the initial setup has run. This is key for reboot tests.
COOKIE="/var/opt/clevis_setup_done"
# Define persistent file locations
PERSISTENT_LOOPFILE="/var/opt/loopfile"
PERSISTENT_ADV_FILE="/var/opt/adv.jws"
# Define the name for our unlocked device
LUKS_DEV_NAME="myluksdev"

rlJournalStart
  rlPhaseStartSetup
    rlImport --all || rlDie "Import failed"
    rlRun "rlImport --all" 0 "Import libraries"

    # Ensure /var/opt exists for our persistent files
    rlRun "mkdir -p /var/opt"

    # In Image Mode, SELinux should ideally not be disabled, but we keep the option
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
    export TANG_SERVER=${TANG_IP}

    # Verify required packages are part of the image
    rlRun "rpm -q clevis-dracut cryptsetup" 0 "Verify required packages are installed" || rlDie "Missing core packages."
  rlPhaseEnd

  rlPhaseStartTest "Clevis Boot Unlock Test"
    # This `if/else` block is the core of a reboot test.
    # If the cookie doesn't exist, we are in the SETUP phase.
    # If it does, we are in the VERIFICATION phase (post-reboot).
    if [ ! -f "$COOKIE" ]; then
      rlLogInfo "PHASE 1: Initial Setup (Pre-Reboot)"

      # 1. Create the loop file that will act as our hard disk
      rlRun "dd if=/dev/zero of=${PERSISTENT_LOOPFILE} bs=1M count=100" 0 "Create 100MB loopfile"
      LOOP_DEV=$(losetup -f --show ${PERSISTENT_LOOPFILE})
      rlAssertNotEquals "Loop device should be created" "" "$LOOP_DEV"
      rlLogInfo "Using loop device ${LOOP_DEV} for LUKS."

      # 2. Format the device with LUKS
      rlRun "echo -n 'password' | cryptsetup luksFormat ${LOOP_DEV} --type luks2 -" 0 "Format disk with LUKS2"
      LUKS_UUID=$(cryptsetup luksUUID "${LOOP_DEV}")
      rlAssertNotEquals "LUKS UUID should not be empty" "" "${LUKS_UUID}"

      # 3. Bind Clevis to the LUKS device
      rlLogInfo "Downloading Tang advertisement."
      rlRun "curl -sfg http://${TANG_SERVER}/adv -o ${PERSISTENT_ADV_FILE}" 0 "Download Tang advertisement"

      # --- Dynamically build the Clevis pins configuration ---
      local TPM2_AVAILABLE=true
      if [ ! -e "/dev/tpm0" ] && [ ! -e "/dev/tpmrm0" ]; then
        rlLogInfo "TPM2 device not found. Proceeding with Tang pin only."
        TPM2_AVAILABLE=false
        SSS_THRESHOLD=1
        CLEVIS_PINS='{"tang":[{"url":"http://'"${TANG_SERVER}"'","adv":"'"${PERSISTENT_ADV_FILE}"'"}]}'
      else
        rlLogInfo "TPM2 device found. Using Tang and TPM2 pins."
        SSS_THRESHOLD=1 # Use 1 for "either/or" or 2 for "both required"
        CLEVIS_PINS='{"tang":[{"url":"http://'"${TANG_SERVER}"'","adv":"'"${PERSISTENT_ADV_FILE}"'"}], "tpm2": {"pcr_bank":"sha256", "pcr_ids":"0,7"}}'
      fi
      # --- End of dynamic pin building ---

      rlLogInfo "Binding Clevis with SSS (t=${SSS_THRESHOLD})."
      rlRun "clevis luks bind -d ${LOOP_DEV} sss '{\"t\":${SSS_THRESHOLD},\"pins\":${CLEVIS_PINS}}' <<< 'password'" 0 "Bind Clevis to LUKS device"

      # 4. Create the /etc/crypttab entry for automatic boot unlock
      # Using the UUID is the most robust method.
      rlLogInfo "Adding entry to /etc/crypttab for automatic unlock."
      rlRun "echo '${LUKS_DEV_NAME} UUID=${LUKS_UUID} none luks,clevis,nofail' >> /etc/crypttab"

      # 5. Create the Dracut hook and configuration to re-create the loop device inside initramfs
      # This is the magic that makes the test work.
      rlLogInfo "Creating dracut hook to set up loop device during boot."
      # The Hook Script itself
      cat << 'EOF_HOOK' > "/var/opt/90-luks-loop-hook.sh"
#!/bin/bash
# This script runs inside the initramfs to set up our loop device
# before systemd-cryptsetup tries to unlock it.
echo "LUKS Loop Hook: Setting up ${PERSISTENT_LOOPFILE}..." > /dev/kmsg
losetup $(losetup -f) "${PERSISTENT_LOOPFILE}"
echo "LUKS Loop Hook: losetup complete. Triggering udev." > /dev/kmsg
udevadm settle
EOF_HOOK
      chmod +x /var/opt/90-luks-loop-hook.sh

      # The Dracut configuration file that installs the hook and the loopfile into the initramfs
      cat << 'EOF_CONF' > "/etc/dracut.conf.d/99-loopluks.conf"
# Add our hook script and the actual loopfile to the initramfs image
install_items+=" /var/opt/90-luks-loop-hook.sh /usr/lib/dracut/hooks/pre-udev/90-luks-loop-hook.sh "
install_items+=" ${PERSISTENT_LOOPFILE} "
# Also ensure network modules are included for Tang
add_dracutmodules+=" network clevis "
kernel_cmdline="rd.neednet=1"
EOF_CONF

      # 6. Regenerate initramfs to include all our changes
      rlRun "dracut --force" 0 "Regenerate initramfs with new hook and files"

      # 7. Create the cookie and reboot
      rlLogInfo "Initial setup complete. Triggering reboot."
      rlRun "touch '$COOKIE'"
      tmt-reboot # Use the standard tmt reboot command

    else
      # This block runs AFTER the reboot
      rlLogInfo "PHASE 2: Verification (Post-Reboot)"

      # The single most important check: Is our LUKS device unlocked?
      # The `cryptsetup status` command is the most reliable way to check.
      rlRun "cryptsetup status ${LUKS_DEV_NAME}" 0 "Verify '${LUKS_DEV_NAME}' is active and unlocked"

      # Additionally, check the journal for the success message
      rlRun "journalctl -b | grep 'Finished Cryptography Setup for ${LUKS_DEV_NAME}'" 0 "Verify journal for successful cryptsetup"

      # Optional: Mount the device and check data for full confidence
      rlLogInfo "Mounting unlocked device to verify data."
      rlRun "echo -n 'password' | cryptsetup luksOpen UUID=${LUKS_UUID} ${LUKS_DEV_NAME} -" 0 "Open device to mount"
      rlRun "mkdir -p /mnt/luks_test"
      rlRun "mount /dev/mapper/${LUKS_DEV_NAME} /mnt/luks_test" 0 "Mount unlocked device"
      # We didn't write data in setup, so we just check mount success.

      rlLogPass "Test passed: Clevis successfully unlocked the device during boot."
    fi
  rlPhaseEnd

  rlPhaseStartCleanup
    rlLogInfo "Starting cleanup phase."
    # Use ||: to prevent the cleanup from failing if a resource doesn't exist
    rlRun "umount /mnt/luks_test" ||:
    rlRun "cryptsetup luksClose ${LUKS_DEV_NAME}" ||:

    # Detach loop device if it's still attached
    current_loop_dev=$(losetup -j ${PERSISTENT_LOOPFILE} | awk -F: '{print $1}')
    if [ -n "${current_loop_dev}" ]; then
      rlRun "losetup -d ${current_loop_dev}" ||:
    fi

    # Remove all created files
    rlRun "rm -f '${COOKIE}'" ||:
    rlRun "rm -f '${PERSISTENT_LOOPFILE}'" ||:
    rlRun "rm -f '${PERSISTENT_ADV_FILE}'" ||:
    rlRun "rm -f /var/opt/90-luks-loop-hook.sh" ||:
    rlRun "rm -f /etc/dracut.conf.d/99-loopluks.conf" ||:

    # Remove the crypttab entry
    rlRun "sed -i \"/${LUKS_DEV_NAME}/d\" /etc/crypttab" ||:

    # Regenerate initramfs to leave the system clean
    rlRun "dracut --force" 0 "Regenerate initramfs to restore clean state"
  rlPhaseEnd
rlJournalEnd