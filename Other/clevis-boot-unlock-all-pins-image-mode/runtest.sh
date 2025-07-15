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

# Define path for the initramfs hook script (copied to /usr/lib/dracut/hooks/cmdline/)
INITRAMFS_HOOK_DEST="/usr/lib/dracut/hooks/cmdline/90luks-loop.sh"


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

        # --- START: Initramfs Hook Script preparation (for direct copy) ---
        rlLogInfo "Creating initramfs hook script to re-create loop device."
        # The hook script itself, written to a persistent location temporarily
        # Ensure 'EOF_HOOK' is on a line by itself with no leading/trailing whitespace
        cat << 'EOF_HOOK' > "/var/opt/90luks-loop.sh"
#!/bin/bash

# Redirect stdout/stderr to console and log for debugging
exec >/dev/kmsg 2>&1
echo "initramfs: Running 90luks-loop.sh hook..."
echo "initramfs: Current working directory: $(pwd)"
echo "initramfs: Listing root content:"
ls -F /
ls -l /var/opt/ || true # List contents of /var/opt in initramfs

# Check if the persistent loopfile actually exists in initramfs
if [ -f "${PERSISTENT_LOOPFILE}" ]; then
    echo "initramfs: ${PERSISTENT_LOOPFILE} found. Attempting losetup."
    # Create the loop device. It will find a free /dev/loopX.
    LDEV=\$(losetup -f --show "${PERSISTENT_LOOPFILE}")
    if [ -n "\$LDEV" ]; then
        echo "initramfs: losetup done: \$LDEV for ${PERSISTENT_LOOPFILE}"
        # Important: Inform udev that a new block device is ready.
        udevadm settle --timeout=30 # Increased udev settle timeout
        udevadm trigger --action=add --subsystem=block
        echo "initramfs: udevadm done. Current devices:"
        ls -l /dev/loop* || true
        ls -l /dev/mapper/ || true
    else
        echo "initramfs: ERROR: losetup failed for ${PERSISTENT_LOOPFILE}!"
    fi
else
    echo "initramfs: ERROR: ${PERSISTENT_LOOPFILE} not found in initramfs at all!"
fi
EOF_HOOK # Ensure no leading/trailing whitespace on this line
        rlRun "chmod +x /var/opt/90luks-loop.sh"
        # --- END: Initramfs Hook Script preparation ---

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
        rlLogInfo "Adding entry to /etc/crypttab for automatic LUKS unlock."
        rlRun "echo 'myluksdev UUID=${LUKS_UUID} none luks,clevis,nofail,x-systemd.device-timeout=120s' >> /etc/crypttab" 0 "Add crypttab entry with UUID"

        rlLogInfo "Enabling clevis-luks-askpass and configuring dracut for network."
        rlRun "mkdir -p /etc/dracut.conf.d/" 0 "Ensure dracut.conf.d exists (writable overlay expected)"

        # Dracut config files in /etc/dracut.conf.d/
        # 1. Add core dracut modules (network, crypt, clevis)
        # Ensure EOF_CONF_MODULES is on a line by itself with no leading/trailing whitespace
        cat << EOF_CONF_MODULES > "/etc/dracut.conf.d/10-custom-modules.conf"
add_dracutmodules+=" network crypt clevis "
EOF_CONF_MODULES
        rlRun "chmod +x /etc/dracut.conf.d/10-custom-modules.conf" 0 "Set permissions for custom modules config"

        # 2. Add kernel command line (rd.neednet=1 rd.info rd.debug)
        # Ensure EOF_CONF_NET is on a line by itself with no leading/trailing whitespace
        cat << EOF_CONF_NET > "/etc/dracut.conf.d/10-clevis-net.conf"
kernel_cmdline="rd.neednet=1 rd.info rd.debug"
EOF_CONF_NET
        rlRun "chmod +x /etc/dracut.conf.d/10-clevis-net.conf" 0 "Set permissions for clevis network config"

        # 3. Configure dracut to install the hook script and loopfile
        #    Use 'install_items+' to copy files to the exact paths in the initramfs.
        #    The hook script is copied to a standard cmdline hook location within initramfs.
        #    The loopfile is copied to its original persistent path within initramfs.
        # Ensure EOF_CONF_INSTALL is on a line by itself with no leading/trailing whitespace
        cat << EOF_CONF_INSTALL > "/etc/dracut.conf.d/99-loopluks-install.conf"
install_items+="/var/opt/90luks-loop.sh ${INITRAMFS_HOOK_DEST}" # Explicitly copy to the correct hook path
install_items+="${PERSISTENT_LOOPFILE} /${PERSISTENT_LOOPFILE#/}"
EOF_CONF_INSTALL
        rlRun "chmod +x /etc/dracut.conf.d/99-loopluks-install.conf" 0 "Set permissions for loopluks install config"

        # Regenerate initramfs. dracut will pick up all *.conf files from /etc/dracut.conf.d/.
        # Use --force to rebuild the current kernel's initramfs.
        rlRun "dracut --force" 0 "Regenerate initramfs with all new configurations"

        rlRun "touch \"$COOKIE\"" 0 "Mark initial setup as complete"
        rlLogInfo "Initial setup complete. Triggering reboot via test runner."
        rhts-reboot # Keeping rhts-reboot as per your last snippet.

      else # This block runs on subsequent boots after the initial setup
        rlLogInfo "Post-reboot: Verifying LUKS automatic unlock and mount."

        # Verify the loop device is active (should have been created by the initramfs hook)
        rlLogInfo "Verifying loop device and LUKS unlock status."
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
        # Check /run/initramfs/debug_loop.log for initramfs specific debug info.
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
    rlRun "umount /mnt/luks_test" ||: "Failed to unmount /mnt/luks_test, continuing cleanup."

    # Close LUKS device (it might be open if the test failed before auto-unlock or during verification)
    if cryptsetup status myluksdev &>/dev/null; then
      rlRun "cryptsetup luksClose myluksdev" ||: "Failed to close myluksdev, continuing cleanup."
    fi

    # Clean up loop device if it exists
    current_loop_dev=$(losetup -a | grep "${PERSISTENT_LOOPFILE}" | awk -F: '{print $1}')
    if [ -n "${current_loop_dev}" ]; then
      rlRun "losetup -d ${current_loop_dev}" ||: "Failed to detach loop device ${current_loop_dev}."
    fi
    rlRun "rm -f ${PERSISTENT_LOOPFILE}" ||: "Failed to remove loopfile."

    # Clean up initramfs hook script from /var/opt/
    rlRun "rm -f /var/opt/90luks-loop.sh" ||: "Failed to remove initramfs hook script from /var/opt/."
    # Also clean up from where dracut might have copied it in initramfs itself.
    # This might not be writable on the live system, so use ||:
    rlRun "rm -f ${INITRAMFS_HOOK_DEST}" ||: "Failed to remove hook script from standard dracut location."


    # Clean up cookies and other persistent temporary files
    rlRun "rm -f \"$COOKIE\"" ||: "Failed to remove COOKIE."
    rlRun "rm -f /var/opt/adv.jws" ||: "Failed to remove persistent advertisement file."
    # Clean up dracut config files
    rlRun "rm -f /etc/dracut.conf.d/10-custom-modules.conf" ||: "Failed to remove custom dracut modules config."
    rlRun "rm -f /etc/dracut.conf.d/10-clevis-net.conf" ||: "Failed to remove clevis network config."
    rlRun "rm -f /etc/dracut.conf.d/99-loopluks-install.conf" ||: "Failed to remove loopluks install config."

    # Remove the crypttab entry created by the test
    # This sed now uses the file path for robustness in cleanup if UUID isn't easily retrieved.
    rlRun "sed -i '\_myluksdev ${PERSISTENT_LOOPFILE} none luks,clevis,nofail,x-systemd.device-timeout=120s_d' /etc/crypttab" ||: "Failed to remove crypttab entry."

    # Regenerate initramfs to remove changes made by the test for clean state.
    rlRun "dracut -f --regenerate-all" ||: "Failed to regenerate initramfs during cleanup."
  rlPhaseEnd
rlJournalEnd