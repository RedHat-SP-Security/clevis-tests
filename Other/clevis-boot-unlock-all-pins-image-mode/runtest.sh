#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /clevis-tests/Otherl/tang-boot-unlock
#   Description: Test of clevis boot unlock via tang and tpm2 for Image Mode testing (bootc/ostree).
#   Author: Adam Prikryl <aprikryl@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2024 Red Hat, Inc.
#
#   This program is free software: you can redistribute and/or
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

# Define variables for this test
TANG_SERVER_PORT="8080" # Default Tang port
LUKS_INITIAL_PASSPHRASE="supersecretpassphrase" # MUST match the one used in luks-clevis-config.toml.template
BOOTC_INSTALL_CONFIG_TEMPLATE="luks-clevis-config.toml.template"
BOOTC_INSTALL_CONFIG_TARGET_FILENAME="10-luks-clevis.toml" # Name for the file inside the image at /usr/lib/bootc/install/

# Note: The `vm.sh` library is often used in Beakerlib for `__setup_ssh` etc.
# Ensure it's sourced if your Beakerlib environment doesn't load it by default.
# For Beakerlib environments, `rlImport --all` usually covers common helper libraries.
# If __setup_ssh is not found, you'd need to provide it (basic ssh-keygen).

rlJournalStart
  rlPhaseStartSetup
    rlImport --all || rlDie "Import failed"
    rlRun "rlImport --all" 0 "Import libraries" || rlDie "cannot continue"

    rlLogInfo "SELinux: $(getenforce)"

      rlRun "rlFileBackup --clean ~/.ssh/"
      mkdir -p ~/.ssh
      chmod 700 ~/.ssh
      ssh-keygen -q -t rsa -b 4096 -N '' -f ~/.ssh/id_rsa <<< y 2>&1 >/dev/null
      rm -f ~/.ssh/known_hosts
      cat << EOF > ~/.ssh/config
Host *
  user root
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel QUIET
EOF
      chmod 600 ~/.ssh/config

    # Start Tang server on the test host.
    # This Tang server will be accessed by `bootc install` during the "pre-reboot phase"
    # to bind the Clevis Tang pin to the LUKS device.
    rlLogInfo "Starting Tang server on host for bootc installation."
    rlRun "sudo systemctl enable --now tangd.socket" 0 "Enable and start tangd.socket"
    rlRun "sudo systemctl status tangd.socket" 0 "Check tangd.socket status"
    TANG_IP=$(ip addr show $(ip route get 1 | awk '{print $5; exit}') | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    rlAssertNotEquals "Tang server IP must not be empty" "" "$TANG_IP"
    rlLogInfo "Tang server running at: ${TANG_IP}:${TANG_SERVER_PORT}"

    # Prepare the `bootc-install-config.toml` file.
    # This file will be copied into the `bootc` image during its build,
    # and then processed by `bootc install` to configure LUKS and Clevis.
    rlLogInfo "Preparing bootc install config file: ${BOOTC_INSTALL_CONFIG_FILENAME}"
    rlRun "cp ${BOOTC_INSTALL_CONFIG_TEMPLATE} ${BOOTC_INSTALL_CONFIG_FILENAME}" 0 "Copy bootc install config template"
    # Substitute dynamic values into the TOML file
    rlRun "sed -i 's|\${TANG_SERVER}|${TANG_IP}|g' ${BOOTC_INSTALL_CONFIG_FILENAME}" 0 "Substitute TANG_IP in install config"
    rlRun "sed -i 's|\${TANG_SERVER_PORT}|${TANG_SERVER_PORT}|g' ${BOOTC_INSTALL_CONFIG_FILENAME}" 0 "Substitute TANG_SERVER_PORT in install config"
    rlRun "sed -i 's|\${LUKS_INITIAL_PASSPHRASE}|${LUKS_INITIAL_PASSPHRASE}|g' ${BOOTC_INSTALL_CONFIG_FILENAME}" 0 "Substitute initial LUKS passphrase in install config"
    rlFileSubmit "${BOOTC_INSTALL_CONFIG_FILENAME}" "${BOOTC_INSTALL_CONFIG_FILENAME}" # Make it available in tmt's artifacts/test directory for copying by BOOTC_RUN_CMD

    # Set environment variables that the `bootc_test_prepare` orchestrator will read.

    # 1. BOOTC_INSTALL_PACKAGES: Essential Clevis/LUKS/TPM tools installed *into the image*.
    export BOOTC_INSTALL_PACKAGES="clevis clevis-luks luksmeta tang expect socat psmisc curl softhsm opensc jose cryptsetup openssl git python3-pip clevis-pin-pkcs11 python-pip libjose-devel cryptsetup-devel tpm2-tools libluksmeta-devel"

    # 2. BOOTC_RUN_CMD: Command to be run *inside the Containerfile build*.
    # This command copies our templated `luks-clevis-config.toml` into
    # `/usr/lib/bootc/install/` within the image's filesystem.
    # The `bootc_test_prepare` script copies the entire tmt run directory (which includes our test dir and its files)
    # into its build context, typically under `/var/tmp/tmt/run-.../path/to/my/test/`.
    # So, `cp ${BOOTC_INSTALL_CONFIG_FILENAME}` from the current Containerfile build context
    # correctly refers to our file.
    export BOOTC_RUN_CMD="mkdir -p /usr/lib/bootc/install && cp ${BOOTC_INSTALL_CONFIG_FILENAME} /usr/lib/bootc/install/${BOOTC_INSTALL_CONFIG_FILENAME} && chmod 644 /usr/lib/bootc/install/${BOOTC_INSTALL_CONFIG_FILENAME}"

    # 3. BOOTC_KERNEL_ARGS: Ensure `rd.neednet=1` for network access early in boot.
    export BOOTC_KERNEL_ARGS='["rd.neednet=1"]'

    rlLogInfo "Environment variables set for `bootc_test_prepare` orchestrator:"
    rlRun "env | grep BOOTC_"

    # No explicit `bootc build` or `bootc install` here.
    # These actions are handled by the `bootc_test_prepare` script based on the
    # environment variables we've just exported.

  rlPhaseEnd

  rlPhaseStartTest "Verify Boot Unlock (Post-Reboot)"
    # This phase runs AFTER the system has rebooted into the newly installed
    # `bootc` image, which should now have LUKS and Clevis configured.

    # Ensure TPM device is present on the booted system.
    rlRun "ls /dev/tpm0" 0 "Verify TPM device exists on the booted system"

    # Verify journalctl for successful LUKS decryption and Clevis askpass deactivation.
    if rlIsRHELLike '>=10'; then
      rlRun "journalctl -b | grep \"Finished systemd-cryptsetup\"" 0 "Verify systemd-cryptsetup finished"
    else
      rlRun "journalctl -b | grep \"Finished Cryptography Setup for luks-\"" 0 "Verify Cryptography Setup finished"
      rlRun "journalctl -b | grep \"clevis-luks-askpass.service: Deactivated successfully\"" 0 "Verify clevis-luks-askpass deactivated"
    fi

    # Verify that the root filesystem is indeed mounted via LUKS.
    # The `luks-clevis-config.toml` will create a LUKS volume on /dev/vda (or specified disk).
    # Assuming the root partition is /dev/vda2 (common for OS installs on a single disk).
    rlRun "lsblk -no FSTYPE,MOUNTPOINT,ROUTEPATH | grep 'crypto_LUKS / /dev/mapper/root'" 0 "Verify root is LUKS-mounted"
    rlRun "sudo cryptsetup status root | grep 'cipher: aes-cbc-essiv:sha256'" 0 "Verify LUKS cipher"
    rlRun "sudo cryptsetup status root | grep 'active one key slot'" 0 "Verify LUKS active key slot (by Clevis)"
    # IMPORTANT: Adjust /dev/vda2 if your actual root partition device node differs.
    # You might need to add a step to dynamically determine the root LUKS device,
    # e.g., `ROOT_LUKS_DEV=$(lsblk -no PKNAME $(findmnt -no SOURCE / | cut -d'[' -f1) | grep -E '^sd[a-z][0-9]+|^nvme[0-9]+n[0-9]+p[0-9]+')`
    rlRun "sudo clevis luks list /dev/vda2 | grep 'tang' | grep 'tpm2' | grep 't=2'" 0 "Verify Clevis binding is present on /dev/vda2"

    # Verify Tang server reachability from the *booted system*.
    # This confirms network connectivity and successful interaction with Tang.
    rlLogInfo "Verifying Tang server reachability from the booted system..."
    # Use the TANG_IP (which was captured in setup) of the system where Tang is running.
    # This assumes the test host's IP is reachable from the *newly booted* bootc system.
    rlRun "curl -sfg http://${TANG_IP}:${TANG_SERVER_PORT}/adv -o /tmp/adv.jws" 0 "Download Tang advertisement from booted system"
    rlFileExists "/tmp/adv.jws" || rlDie "Tang advertisement not downloaded on booted system"

  rlPhaseEnd

  rlPhaseStartCleanup
    # Stop Tang server on the host (where this script originally ran and where the bootc install connected to it).
    rlRun "sudo systemctl stop tangd.socket" 0-1 "Stop tangd.socket"
    rlRun "sudo systemctl disable tangd.socket" 0-1 "Disable tangd.socket"

    # Clean up the generated install config file.
    rlRun "rm -f ${BOOTC_INSTALL_CONFIG_FILENAME}" 0-1 "Remove generated bootc install config"

    # No other cleanup needed, as the `bootc_test_prepare` orchestrator handles
    # resetting the test system for subsequent tests (e.g., re-imaging).
  rlPhaseEnd
rlJournalEnd