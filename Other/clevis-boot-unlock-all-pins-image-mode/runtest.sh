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

# Define persistent file locations
PERSISTENT_LOOPFILE="/var/opt/loopfile"
PERSISTENT_ADV_FILE="/var/opt/adv.jws"

# Define paths for custom dracut module
DRACUT_CUSTOM_MODULE_DIR="/usr/lib/dracut/modules.d/99loopluks"
DRACUT_MODULE_SETUP_SCRIPT="${DRACUT_CUSTOM_MODULE_DIR}/module-setup.sh"
DRACUT_INITRAMFS_HOOK_SCRIPT="${DRACUT_CUSTOM_MODULE_DIR}/90luks-loop.sh"


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
    # Wrap the entire phase logic in a function to allow 'return' to exit gracefully on fatal errors.
    _luks_clevis_test_logic() {
      local TPM2_AVAILABLE=true # Flag to track TPM2 presence
      local CLEVIS_PINS=""      # Variable to build dynamic Clevis pin configuration
      local SSS_THRESHOLD=2     # Default SSS threshold (for Tang + TPM2)
      local LUKS_UUID=""        # Declare LUKS_UUID here for broader scope if needed for debug

      # Check for TPM2 availability
      if [ ! -e "/dev/tpm0" ] && [ ! -e "/dev/tpmrm0" ]; then
        rlLogInfo "TPM2 device not found (/dev/tpm0 or /dev/tpmrm0). Will proceed without TPM2 binding."
        TPM2_AVAILABLE=false
        SSS_THRESHOLD=1 # Adjust threshold since only Tang pin will be used
      else
        rlLogInfo "TPM2 device found. Will include TPM2 binding."
        # SSS_THRESHOLD remains 2
      fi

      # This block runs the initial setup. It should execute only once.
      if [ ! -e "$COOKIE" ]; then
        rlLogInfo "Initial run: Setting up LUKS device and Clevis binding."

        # --- START: Loop device setup ---
        rlLogInfo "Creating loop device for LUKS testing."
        # Ensure /var/opt exists and is writable for persistent files.
        rlRun "mkdir -p /var/opt" 0 "Ensure /var/opt directory exists for persistent data"
        # Create the backing file for the loop device in /var/opt/.
        rlRun "dd if=/dev/zero of=${PERSISTENT_LOOPFILE} bs=1M count=50" 0 "Create loopfile in persistent storage"
        # Attach the loop device and capture its path.
        rlRun "LOOP_DEV=\$(losetup -f --show ${PERSISTENT_LOOPFILE})" 0 "Create loop device from file"
        # Use the obtained loop device path as the target for LUKS.
        TARGET_DISK="${LOOP_DEV}"
        rlLogInfo "Using loop device ${TARGET_DISK} for LUKS."
        # --- END: Loop device setup ---

        # --- START: Custom Dracut Module for Initramfs Loop Device ---
        rlLogInfo "Setting up custom Dracut module to re-create loop device in initramfs."
        rlRun "mkdir -p ${DRACUT_CUSTOM_MODULE_DIR}" 0 "Create custom Dracut module directory"

        # module-setup.sh: Tells dracut what to include
        cat << EOF > "${DRACUT_MODULE_SETUP_SCRIPT}"
#!/bin/bash
check() { return 0; } # Always include this module
depends() { echo "crypt network"; return 0; } # Ensure crypt and network modules are included
install() {
    inst_hook cmdline 90 "${DRACUT_INITRAMFS_HOOK_SCRIPT##*/}" # Run early
    inst_simple "${PERSISTENT_LOOPFILE}" "/${PERSISTENT_LOOPFILE#/}" # Copy the persistent loopfile
    inst_dir "$(dirname ${PERSISTENT_LOOPFILE})" # Ensure /var/opt exists in initramfs
}
EOF
        rlRun "chmod +x ${DRACUT_MODULE_SETUP_SCRIPT}"

        # 90luks-loop.sh: The script that runs in initramfs
        cat << EOF > "${DRACUT_INITRAMFS_HOOK_SCRIPT}"
#!/bin/bash

echo "initramfs: Running 90luks-loop.sh hook..." >> /run/initramfs/debug_loop.log

# Ensure the directory exists as it's copied into the initramfs
mkdir -p "$(dirname ${PERSISTENT_LOOPFILE})"

# Check if the persistent loopfile actually exists in initramfs
if [ -f "${PERSISTENT_LOOPFILE}" ]; then
    # Create the loop device. It will find a free /dev/loopX.
    # It must happen before systemd-cryptsetup runs.
    LDEV=\$(losetup -f --show "${PERSISTENT_LOOPFILE}")
    echo "initramfs: losetup done: \$LDEV for ${PERSISTENT_LOOPFILE}" >> /run/initramfs/debug_loop.log

    # Important: Inform udev that a new block device is ready.
    # This is critical for systemd-cryptsetup to see it.
    udevadm settle --timeout=30 # Increased udev settle timeout
    udevadm trigger --action=add --subsystem=block

    echo "initramfs: udevadm done." >> /run/initramfs/debug_loop.log
else
    echo "initramfs: ERROR: ${PERSISTENT_LOOPFILE} not found in initramfs!" >> /run/initramfs/debug_loop.log
fi
EOF
        rlRun "chmod +x ${DRACUT_INITRAMFS_HOOK_SCRIPT}"
        # --- END: Custom Dracut Module ---


        rlLogInfo "Formatting ${TARGET_DISK} with LUKS2."
        rlRun "echo -n 'password' | cryptsetup luksFormat ${TARGET_DISK} --type luks2 -" 0 "Format disk with LUKS2"

        # Get the UUID of the LUKS device for crypttab
        LUKS_UUID=$(cryptsetup luksUUID "${TARGET_DISK}")
        rlAssertNotEquals "LUKS UUID should not be empty" "" "${LUKS_UUID}"

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
        rlRun "curl -sfg http://${TANG_SERVER}/adv -o ${PERSISTENT_ADV_FILE}" 0 "Download Tang advertisement"

        # Dynamically build the Clevis pins configuration JSON
        CLEVIS_PINS='{"tang":[{"url":"http://'"${TANG_SERVER}"'","adv":"'"${PERSISTENT_ADV_FILE}"'"}]' # Adv path needs to be absolute
        if ${TPM2_AVAILABLE}; then
          CLEVIS_PINS+=', "tpm2": {"pcr_bank":"sha256", "pcr_ids":"0,7"}'
        fi
        CLEVIS_PINS+='}' # Close the pins object

        rlLogInfo "Binding Clevis to LUKS device ${TARGET_DISK} with dynamic pins: ${CLEVIS_PINS} (t=${SSS_THRESHOLD})."
        rlRun "clevis luks bind -d ${TARGET_DISK} sss '{\"t\":${SSS_THRESHOLD},\"pins\":${CLEVIS_PINS}}' <<< 'password'" 0 "Bind Clevis to LUKS device with dynamic pins"

        # Add entry to /etc/crypttab for automatic unlock at boot
        # Use UUID for crypttab - it's the stable identifier of the LUKS header, regardless of loop device path.
        rlLogInfo "Adding entry to /etc/crypttab for automatic LUKS unlock."
        rlRun "echo 'myluksdev UUID=${LUKS_UUID} none luks,clevis,nofail,x-systemd.device-timeout=120s' >> /etc/crypttab" 0 "Add crypttab entry with UUID"

        rlLogInfo "Enabling clevis-luks-askpass and configuring dracut for network."
        # Use NetworkManager module if your Image Mode system relies on it, otherwise 'network' is generally fine.
        # Check `systemctl is-active NetworkManager` or `systemctl is-active systemd-networkd` on your system.
        # If NetworkManager is used, change 'network' to 'network-manager'.
        rlRun "echo 'add_dracutmodules+=\" network crypt clevis \"' > /etc/dracut.conf.d/10-custom-modules.conf" 0 "Add custom dracut modules"
        rlRun "systemctl enable clevis-luks-askpass.path" 0 "Enable clevis-luks-askpass (if not already enabled by snippet)"
        rlRun "mkdir -p /etc/dracut.conf.d/" 0 "Ensure dracut.conf.d exists (writable overlay expected)"
        rlRun "echo 'kernel_cmdline=\"rd.neednet=1 rd.info rd.debug\"' > /etc/dracut.conf.d/10-clevis-net.conf" 0 "Add kernel command line for network and debug to dracut"
        # Crucial: Regenerate initramfs to include crypttab, custom loop module, and updated Clevis modules
        rlRun "dracut -f --regenerate-all" 0 "Regenerate initramfs to include Clevis and network settings"

        rlRun "touch \"$COOKIE\"" 0 "Mark initial setup as complete"
        rlLogInfo "Initial setup complete. Triggering reboot via test runner."
        rhts-reboot # Keeping rhts-reboot as per your last snippet.

      else # This block runs on subsequent boots after the initial setup
        rlLogInfo "Post-reboot: Verifying LUKS automatic unlock and mount."

        # The custom dracut module should have already re-created the loop device
        # and systemd-cryptsetup should have unlocked it using the crypttab entry.
        # We just need to verify its state and get its current path for cleanup.
        rlLogInfo "Verifying loop device and LUKS unlock status."
        # This will get the current /dev/loopX path for the persistent file.
        LOOP_DEV=$(losetup -a | grep "${PERSISTENT_LOOPFILE}" | awk -F: '{print $1}')
        rlAssertNotEquals "Loop device for ${PERSISTENT_LOOPFILE} should be active" "" "${LOOP_DEV}"
        TARGET_DISK="${LOOP_DEV}" # Set TARGET_DISK for the rest of this phase and cleanup.

        # Verify the LUKS device is automatically unlocked and mounted.
        rlRun "lsblk | grep myluksdev" 0 "Verify myluksdev is present and unlocked"
        rlRun "mount | grep /mnt/luks_test" 0 "Verify /mnt/luks_test is mounted"
        rlRun "cat /mnt/luks_test/testfile.txt | grep 'Test data for LUKS device'" 0 "Verify data integrity on LUKS device"

        # Check journal for successful cryptsetup operation (regardless of TPM2 presence)
        if rlIsRHELLike '>=10'; then
          rlRun "journalctl -b | grep \"Finished systemd-cryptsetup\"" 0 "Check journal for cryptsetup finish (RHEL10+)"
        else
          rlRun "journalctl -b | grep \"Finished Cryptography Setup for luks-\"" 0 "Check journal for cryptsetup finish"
        fi
        # Optional: Check /run/initramfs/debug_loop.log for initramfs specific debug info.
        rlRun "cat /run/initramfs/debug_loop.log || true" 0 "Display initramfs loop debug log (if available)"

        rlLogInfo "LUKS device successfully unlocked and mounted via Clevis with Tang and (optionally) TPM2 pins."
      fi
    }
    # Call the function that contains the phase logic.
    _luks_clevis_test_logic
  rlPhaseEnd

  rlPhaseStartCleanup
    rlLogInfo "Starting cleanup phase."
    # Ensure /var/opt exists so cleanup files can be written/deleted.
    rlRun "mkdir -p /var/opt" ||:

    # Unmount and close LUKS device if it's still active
    # Note: umount might fail if already unmounted, so use ||:
    rlRun "umount /mnt/luks_test" ||: "Failed to unmount /mnt/luks_test, continuing cleanup."

    # Close LUKS device (it might be open if the test failed before auto-unlock or during verification)
    # Check if 'myluksdev' is an active crypt device before trying to close.
    if cryptsetup status myluksdev &>/dev/null; then
      rlRun "cryptsetup luksClose myluksdev" ||: "Failed to close myluksdev, continuing cleanup."
    fi

    # Clean up loop device if it exists
    # Use 'losetup -a' to find if the loopfile is still associated with a loop device
    current_loop_dev=$(losetup -a | grep "${PERSISTENT_LOOPFILE}" | awk -F: '{print $1}')
    if [ -n "${current_loop_dev}" ]; then
      rlRun "losetup -d ${current_loop_dev}" ||: "Failed to detach loop device ${current_loop_dev}."
    fi
    rlRun "rm -f ${PERSISTENT_LOOPFILE}" ||: "Failed to remove loopfile."

    # Clean up custom Dracut module
    if [ -d "${DRACUT_CUSTOM_MODULE_DIR}" ]; then
        rlRun "rm -rf ${DRACUT_CUSTOM_MODULE_DIR}" ||: "Failed to remove custom dracut module directory."
    fi

    # Clean up cookies and other persistent temporary files
    rlRun "rm -f \"$COOKIE\"" ||: "Failed to remove COOKIE."
    rlRun "rm -f ${PERSISTENT_ADV_FILE}" ||: "Failed to remove persistent advertisement file."
    rlRun "rm -f /etc/dracut.conf.d/10-clevis-net.conf" ||: "Failed to remove dracut network config."
    rlRun "rm -f /etc/dracut.conf.d/10-custom-modules.conf" ||: "Failed to remove custom dracut modules config."
    # Remove the crypttab entry created by the test
    # Get the UUID from the disk if it still exists (for robustness)
    local LUKS_CLEANUP_UUID=""
    if cryptsetup luksUUID "${TARGET_DISK}" &>/dev/null; then
        LUKS_CLEANUP_UUID=$(cryptsetup luksUUID "${TARGET_DISK}")
    fi

    if [ -n "${LUKS_CLEANUP_UUID}" ]; then
        rlRun "sed -i '\_myluksdev UUID=${LUKS_CLEANUP_UUID} none luks,clevis,nofail,x-systemd.device-timeout=120s_d' /etc/crypttab" ||: "Failed to remove specific crypttab entry by UUID."
    else
        # Fallback to generic removal if UUID not found (e.g., if format failed)
        rlRun "sed -i '\_myluksdev .* none luks,clevis,nofail,x-systemd.device-timeout=120s_d' /etc/crypttab" ||: "Failed to remove generic crypttab entry."
    fi

    # Regenerate initramfs to remove changes made by the test for clean state.
    rlRun "dracut -f --regenerate-all" ||: "Failed to regenerate initramfs during cleanup."
  rlPhaseEnd
rlJournalEnd