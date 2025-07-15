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

COOKIE=/var/opt/clevis_setup_done
LOOP_DEV=""
PERSISTENT_LOOPFILE="/var/opt/loopfile"
PERSISTENT_ADV_FILE="/var/opt/adv.jws"
INITRAMFS_HOOK_DEST="/usr/lib/dracut/hooks/cmdline/90luks-loop.sh"

rlJournalStart
  rlPhaseStartSetup
    rlImport --all || rlDie "Import failed"

    rlLogInfo "DISABLE_SELINUX(${DISABLE_SELINUX})"
    if [ -n "${DISABLE_SELINUX}" ]; then
      rlRun "setenforce 0"
    fi
    rlLogInfo "SELinux: $(getenforce)"

    rlServiceStart tangd.socket
    rlServiceStatus tangd.socket

    TANG_IP=$(ip addr show $(ip route get 1 | awk '{print $5; exit}') | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    rlLog "Tang IP: ${TANG_IP}"
    export TANG_SERVER=${TANG_IP}

    rlRun "rpm -q clevis-dracut" 0 "Verify clevis-dracut is installed"
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
        rlLogInfo "TPM2 device found."
      fi

      if [ ! -e "$COOKIE" ]; then
        rlLogInfo "Initial setup: Creating loop device and configuring Clevis binding."

        rlRun "mkdir -p /var/opt" 0 "Ensure /var/opt exists"
        rlRun "dd if=/dev/zero of=${PERSISTENT_LOOPFILE} bs=1M count=50" 0 "Create loopfile"
        rlRun "LOOP_DEV=\$(losetup -f --show ${PERSISTENT_LOOPFILE})" 0 "Attach loop device"
        TARGET_DISK="${LOOP_DEV}"

        cat << 'EOF_HOOK' > "/var/opt/90luks-loop.sh"
#!/bin/bash
exec >/dev/kmsg 2>&1
echo "initramfs: Running 90luks-loop.sh..."
if [ -f "/var/opt/loopfile" ]; then
    echo "initramfs: Found /var/opt/loopfile"
    LDEV=\$(losetup -f --show "/var/opt/loopfile")
    if [ -n "\$LDEV" ]; then
        echo "initramfs: Attached \$LDEV"
        udevadm settle --timeout=30
        udevadm trigger --action=add --subsystem=block
        ls -l /dev/loop* || true
        ls -l /dev/mapper/ || true
    else
        echo "initramfs: ERROR: losetup failed"
    fi
else
    echo "initramfs: ERROR: /var/opt/loopfile not found"
fi
EOF_HOOK
        rlRun "chmod +x /var/opt/90luks-loop.sh"

        rlLogInfo "Formatting ${TARGET_DISK} with LUKS2"
        rlRun "echo -n 'password' | cryptsetup luksFormat ${TARGET_DISK} --type luks2 -" 0
        LUKS_UUID=$(cryptsetup luksUUID "${TARGET_DISK}")
        rlAssertNotEquals "LUKS UUID should not be empty" "" "${LUKS_UUID}"

        rlRun "echo -n 'password' | cryptsetup luksOpen ${TARGET_DISK} myluksdev -" 0
        rlRun "mkfs.ext4 /dev/mapper/myluksdev" 0
        rlRun "mkdir -p /mnt/luks_test"
        rlRun "mount /dev/mapper/myluksdev /mnt/luks_test"
        rlRun "echo 'test' > /mnt/luks_test/testfile.txt"
        rlRun "umount /mnt/luks_test"
        rlRun "cryptsetup luksClose myluksdev"

        rlRun "curl -sfg http://${TANG_SERVER}/adv -o ${PERSISTENT_ADV_FILE}" 0 "Fetch Tang adv"

        CLEVIS_PINS='{"tang":[{"url":"http://'"${TANG_SERVER}"'","adv":"'"${PERSISTENT_ADV_FILE}"'"}]'
        if ${TPM2_AVAILABLE}; then
          CLEVIS_PINS+=',"tpm2":{"pcr_bank":"sha256","pcr_ids":"0,7"}'
        fi
        CLEVIS_PINS+='}'

        rlRun "clevis luks bind -d ${TARGET_DISK} sss '{\"t\":${SSS_THRESHOLD},\"pins\":${CLEVIS_PINS}}' <<< 'password'" 0

        rlRun "echo 'myluksdev UUID=${LUKS_UUID} none luks,clevis,nofail,x-systemd.device-timeout=120s' >> /etc/crypttab" 0

        rlRun "mkdir -p /etc/dracut.conf.d/" 0

        cat << 'EOF_CONF_MODULES' > "/etc/dracut.conf.d/10-custom-modules.conf"
add_dracutmodules+=" network crypt clevis "
EOF_CONF_MODULES

        cat << 'EOF_CONF_NET' > "/etc/dracut.conf.d/10-clevis-net.conf"
kernel_cmdline="rd.neednet=1 rd.info rd.debug"
EOF_CONF_NET

        cat << EOF_CONF_INSTALL > "/etc/dracut.conf.d/99-loopluks-install.conf"
install_items+="${PERSISTENT_LOOPFILE} /var/opt/90luks-loop.sh /etc/crypttab"
EOF_CONF_INSTALL

        rlRun "cp /var/opt/90luks-loop.sh ${INITRAMFS_HOOK_DEST}" 0 "Install initramfs hook"

        rlRun "touch ${COOKIE}" 0 "Mark setup done"
        rlRun "dracut -f --regenerate-all" 0 "Rebuild initramfs"

        rlLogInfo "Initial setup done. System ready for reboot test."
      else
        rlLogInfo "Setup already done. Skipping initial setup."
      fi
    }

    _luks_clevis_test_logic
  rlPhaseEnd

  rlPhaseStartCleanup
    rlLogInfo "Cleanup is intentionally minimal due to image mode persistence model."
    # If necessary, clean temporary mounts or close open devices
    rlRun "cryptsetup luksClose myluksdev" 0 "Ensure LUKS device is closed" || true
    rlRun "losetup -D" 0 "Detach all loop devices" || true
  rlPhaseEnd
rlJournalEnd