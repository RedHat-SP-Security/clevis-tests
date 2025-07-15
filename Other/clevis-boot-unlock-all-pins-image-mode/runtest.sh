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
    _luks_clevis_test_logic() {
      # ... (TPM2_AVAILABLE and SSS_THRESHOLD logic unchanged) ...

      if [ ! -e "$COOKIE" ]; then
        # ... (Loop device creation and initramfs hook script creation are unchanged) ...

        rlLogInfo "Binding Clevis to LUKS device ${TARGET_DISK} with dynamic pins: ${CLEVIS_PINS} (t=${SSS_THRESHOLD})."
        rlRun "clevis luks bind -d ${TARGET_DISK} sss '{\"t\":${SSS_THRESHOLD},\"pins\":${CLEVIS_PINS}}' <<< 'password'" 0 "Bind Clevis to LUKS device with dynamic pins"

        # Add entry to /etc/crypttab for automatic unlock at boot
        # CRUCIAL CHANGE: Use the *path* of the loopfile in crypttab, not the UUID.
        # This simplifies the early boot process as cryptsetup will use losetup to find it.
        rlLogInfo "Adding entry to /etc/crypttab for automatic LUKS unlock using loopfile path."
        rlRun "echo 'myluksdev ${PERSISTENT_LOOPFILE} none luks,clevis,nofail,x-systemd.device-timeout=120s' >> /etc/crypttab" 0 "Add crypttab entry with persistent file path"

        rlLogInfo "Enabling clevis-luks-askpass and configuring dracut for network."
        rlRun "mkdir -p /etc/dracut.conf.d/" 0 "Ensure dracut.conf.d exists (writable overlay expected)"

        # 1. Configure dracut modules in a config file
        cat << EOF > "/etc/dracut.conf.d/10-custom-modules.conf"
add_dracutmodules+=" network crypt clevis "
EOF
        rlRun "chmod +x /etc/dracut.conf.d/10-custom-modules.conf" 0 "Set permissions for custom modules config"

        # 2. Add kernel command line
        cat << EOF > "/etc/dracut.conf.d/10-clevis-net.conf"
kernel_cmdline="rd.neednet=1 rd.info rd.debug"
EOF
        rlRun "chmod +x /etc/dracut.conf.d/10-clevis-net.conf" 0 "Set permissions for clevis network config"

        # 3. Configure dracut to install the hook script and loopfile
        #    The hook script is copied to a standard cmdline hook location within initramfs.
        #    The loopfile is copied to its original persistent path within initramfs.
        cat << EOF > "/etc/dracut.conf.d/99-loopluks-install.conf"
install_items+="/var/opt/90luks-loop.sh /usr/lib/dracut/hooks/cmdline/90luks-loop.sh"
install_items+="${PERSISTENT_LOOPFILE} /${PERSISTENT_LOOPFILE#/}"
EOF
        rlRun "chmod +x /etc/dracut.conf.d/99-loopluks-install.conf" 0 "Set permissions for loopluks install config"

        # Regenerate initramfs. dracut will pick up all *.conf files from /etc/dracut.conf.d/.
        # Crucial: Use --force to rebuild.
        rlRun "dracut --force" 0 "Regenerate initramfs with all new configurations"

        rlRun "touch \"$COOKIE\"" 0 "Mark initial setup as complete"
        rlLogInfo "Initial setup complete. Triggering reboot via test runner."
        rhts-reboot

      else # Post-reboot verification
        rlLogInfo "Post-reboot: Verifying LUKS automatic unlock and mount."

        # Verify the loop device is active (should have been created by the initramfs hook)
        rlLogInfo "Verifying loop device and LUKS unlock status."
        # Use losetup -a to find the loop device associated with our persistent file path.
        LOOP_DEV=$(losetup -a | grep "${PERSISTENT_LOOPFILE}" | awk -F: '{print $1}')
        rlAssertNotEquals "Loop device for ${PERSISTENT_LOOPFILE} should be active" "" "${LOOP_DEV}"
        TARGET_DISK="${LOOP_DEV}"

        # ... (rest of verification and cleanup are the same) ...

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

    # Clean up initramfs hook script
    if [ -f "/var/opt/90luks-loop.sh" ]; then
        rlRun "rm -f /var/opt/90luks-loop.sh" ||: "Failed to remove initramfs hook script."
    fi

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