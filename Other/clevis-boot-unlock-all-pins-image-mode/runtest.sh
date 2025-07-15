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
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
. /usr/share/beakerlib/beakerlib.sh || exit 1

COOKIE=/var/opt/clevis_setup_done
LOOP_DEV=""
PERSISTENT_LOOPFILE="/var/opt/loopfile"
PERSISTENT_ADV_FILE="/var/opt/adv.jws"
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

    rlServiceStart tangd.socket
    rlServiceStatus tangd.socket
    TANG_IP=$(ip addr show $(ip route get 1 | awk '{print $5; exit}') | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    rlLog "Tang IP: ${TANG_IP}"
    export TANG_SERVER=${TANG_IP}
    rlRun "rpm -q clevis-dracut" 0 "Verify clevis-dracut is installed (expected in image)" || rlDie "clevis-dracut not found, ensure it's in the base image."
  rlPhaseEnd

  rlPhaseStartTest "LUKS and Clevis Setup and Verification"
    _luks_clevis_test_logic() {
      local TPM2_AVAILABLE=true
      local CLEVIS_PINS=""
      local SSS_THRESHOLD=2
      local LUKS_UUID=""

      if [ ! -e "/dev/tpm0" ] && [ ! -e "/dev/tpmrm0" ]; then
        rlLogInfo "TPM2 device not found. Will proceed without TPM2 binding."
        TPM2_AVAILABLE=false
        SSS_THRESHOLD=1
      else
        rlLogInfo "TPM2 device found. Will include TPM2 binding."
      fi

      if [ ! -e "$COOKIE" ]; then
        rlLogInfo "Initial run: Setting up LUKS device and Clevis binding."

        rlRun "mkdir -p /var/opt"
        rlRun "dd if=/dev/zero of=${PERSISTENT_LOOPFILE} bs=1M count=50"
        rlRun "LOOP_DEV=\$(losetup -f --show ${PERSISTENT_LOOPFILE})"
        TARGET_DISK="${LOOP_DEV}"
        rlLogInfo "Using loop device ${TARGET_DISK}"

        cat << 'EOF_HOOK' > "/var/opt/90luks-loop.sh"
#!/bin/bash
exec >/dev/kmsg 2>&1
echo "initramfs: Running 90luks-loop.sh hook..."
ls -F /
ls -l /var/opt/ || true
if [ -f "${PERSISTENT_LOOPFILE}" ]; then
    echo "initramfs: ${PERSISTENT_LOOPFILE} found."
    LDEV=\$(losetup -f --show "${PERSISTENT_LOOPFILE}")
    if [ -n "\$LDEV" ]; then
        echo "initramfs: losetup done: \$LDEV"
        udevadm settle --timeout=30
        udevadm trigger --action=add --subsystem=block
        ls -l /dev/loop* || true
        ls -l /dev/mapper/ || true
    else
        echo "initramfs: ERROR: losetup failed!"
    fi
else
    echo "initramfs: ERROR: loopfile not found!"
fi
EOF_HOOK
        rlRun "chmod +x /var/opt/90luks-loop.sh"

        rlRun "echo -n 'password' | cryptsetup luksFormat ${TARGET_DISK} --type luks2 -"
        LUKS_UUID=$(cryptsetup luksUUID "${TARGET_DISK}")
        rlAssertNotEquals "LUKS UUID should not be empty" "" "${LUKS_UUID}"

        rlRun "echo -n 'password' | cryptsetup luksOpen ${TARGET_DISK} myluksdev -"
        rlRun "mkfs.ext4 /dev/mapper/myluksdev"
        rlRun "mkdir -p /mnt/luks_test"
        rlRun "mount /dev/mapper/myluksdev /mnt/luks_test"
        rlRun "echo 'Test data for LUKS device' > /mnt/luks_test/testfile.txt"
        rlRun "umount /mnt/luks_test"
        rlRun "cryptsetup luksClose myluksdev"

        rlRun "curl -sfg http://${TANG_SERVER}/adv -o ${PERSISTENT_ADV_FILE}"

        CLEVIS_PINS='{"tang":[{"url":"http://'"${TANG_SERVER}"'","adv":"'"${PERSISTENT_ADV_FILE}"'"}]'
        if ${TPM2_AVAILABLE}; then
          CLEVIS_PINS+=', "tpm2": {"pcr_bank":"sha256", "pcr_ids":"0,7"}'
        fi
        CLEVIS_PINS+='}'

        rlRun "clevis luks bind -d ${TARGET_DISK} sss '{\"t\":${SSS_THRESHOLD},\"pins\":${CLEVIS_PINS}}' <<< 'password'"

        rlRun "echo 'myluksdev UUID=${LUKS_UUID} none luks,clevis,nofail,x-systemd.device-timeout=120s' >> /etc/crypttab"

        rlRun "mkdir -p /etc/dracut.conf.d/"
        cat << 'EOF_CONF_MODULES' > "/etc/dracut.conf.d/10-custom-modules.conf"
add_dracutmodules+=" network crypt clevis "
EOF_CONF_MODULES

        cat << 'EOF_CONF_NET' > "/etc/dracut.conf.d/10-clevis-net.conf"
kernel_cmdline="rd.neednet=1 rd.info rd.debug"
EOF_CONF_NET

        cat << EOF_CONF_INSTALL > "/etc/dracut.conf.d/99-loopluks-install.conf"
install_items+="/var/opt/90luks-loop.sh ${INITRAMFS_HOOK_DEST} ${PERSISTENT_LOOPFILE}"
EOF_CONF_INSTALL

        rlRun "touch $COOKIE"
        rlRun "dracut -f --regenerate-all"
        rlRun "sync"
        rlRun "reboot"
      else
        rlLogInfo "Post-reboot: Verifying device unlock and data availability"
        rlRun "lsblk" 0 "List block devices"
        rlRun "mkdir -p /mnt/luks_test"
        rlRun "mount /dev/mapper/myluksdev /mnt/luks_test"
        rlAssertExists "/mnt/luks_test/testfile.txt"
        rlRun "grep -q 'Test data for LUKS device' /mnt/luks_test/testfile.txt"
        rlRun "umount /mnt/luks_test"
      fi
    }

    _luks_clevis_test_logic
  rlPhaseEnd

  rlPhaseStartCleanup
    rlLogInfo "Test complete. Manual cleanup skipped to preserve persistent state across reboots."
  rlPhaseEnd
rlJournalEnd
