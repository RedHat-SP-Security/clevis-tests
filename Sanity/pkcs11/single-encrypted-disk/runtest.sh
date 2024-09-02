#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/clevis/Sanity/pkcs11/single-encrypted-disk
#   Description: tests the clevis pkcs#11 luks functionality using a single encrypted disk
#   Author: Martin Litwora <mlitwora@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2024 Red Hat, Inc.
#
#   This copyrighted material is made available to anyone wishing
#   to use, modify, copy, or redistribute it subject to the terms
#   and conditions of the GNU General Public License version 2.
#
#   This program is distributed in the hope that it will be
#   useful, but WITHOUT ANY WARRANTY; without even the implied
#   warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
#   PURPOSE. See the GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public
#   License along with this program; if not, write to the Free
#   Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
#   Boston, MA 02110-1301, USA.
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Include Beaker environment
. /usr/bin/rhts-environment.sh || :
. /usr/share/beakerlib/beakerlib.sh || exit 1


setup_luks_encrypted_single_disk() {
    # Setup the system so it has encrypted secondary disk that can be used to verify the Clevis pkcs11 disk
    # decrypting functionality. The disk creation of the second disk is specified in the kickstart section
    # of the plan iin the "Plans/ci/pkcs11-single-encrypted-disk"

    rlAssertRpm "cryptsetup"
    # Get the name of the created disk (done by kickstart preparation) that is intended for the test.
    # This disk is a "sub disk" - its name is usually something like "/dev/vdb1"
    child_disk=$(lsblk -o NAME,MOUNTPOINT,PATH | grep "/encrypted_disk" | awk '{print $3}')

    # Get the name of the parent disk (save "/dev/vdb" out of "/dev/vdb1")
    parent_disk="/dev/$(lsblk -ndo pkname $child_disk)"

    rlRun "echo -n redhat123 > pwfile" 0 "Put disk passphrase into a file"
    # If mounted then unmount the disk
    rlRun "mountpoint -q /encrypted_disk && umount /encrypted_disk" "0,1" "Unmount the disk if it is mounted"

    rlRun "cryptsetup luksFormat --batch-mode --key-file pwfile $parent_disk"

    rlRun "cat pwfile | cryptsetup open $parent_disk disk_encrypted"
    rlRun "mkfs -t ext4 /dev/mapper/disk_encrypted"
    rlRun "mount /dev/mapper/disk_encrypted /encrypted_disk"

    # Get the UUID of the child disk and put it into the fstab file
    rlRun "sed -i '/encrypted_disk/d' /etc/fstab" 0 "Remove the previous fstab entry"
    disk_uuid=$(lsblk --nodeps -o uuid /dev/mapper/disk_encrypted | tail -1)
    rlRun "echo \"UUID=$disk_uuid    /encrypted_disk    ext4    defaults    0 0\" >> /etc/fstab"

    # Get the UUID of the parent disk and put it into the crypttab file
    disk_uuid=$(lsblk --nodeps -o uuid $parent_disk | tail -1)
    rlRun "echo \"luks-$disk_uuid    UUID=$disk_uuid    /run/systemd/clevis-pkcs11.sock    keyfile-timeout=90s\" >> /etc/crypttab"
}


PACKAGE="clevis"


# Test steps:
#   1. Install softhsm and create a software token (smartcard)
#   2. Encrypt the secondary disk on the system using the LUKS encryption
#   3. Put all the necessary information about the disk into the
#      /etc/crypttab and /etc/fstab files that are needed for the system to
#      load the disk during the boot time
#   4. Create a new initramfs that contains softhsm libraries and tokens so it
#      can be picked up by Clevis during the boot time
#   5. Use the TPM2 and the softhsm token as a 2 factor clevis encryption of the disk
#   6. Reboot the system and verify that the disk was successfully decrypted by Clevis
#      and mounted to the running system
rlJournalStart
    rlPhaseStartSetup
        if [ $TMT_REBOOT_COUNT == 0 ]; then
            rlAssertRpm $PACKAGE
            # Include utils library containing critical functions
            rlRun ". ../../../TestHelpers/utils.sh" || rlDie "cannot import function script"

            tpm_version=$(cat /sys/class/tpm/tpm*/tpm_version_major)
            rlAssertEquals "Check if the tpm2 version is present" $tpm_version "2"

            rlRun "packageVersion=$(rpm -q ${PACKAGE} --qf '%{name}-%{version}-%{release}\n')"
            # TODO: add correct version that will have the pkcs11 feature implemented
            rlTestVersion "${packageVersion}" '>=' 'clevis-20-1'

            install_softhsm

            TOKEN_LABEL="test_token"
            SOFTHSM_LIB="/usr/lib64/softhsm/libsofthsm.so"
            PINVALUE=1234
            ID="0001"
            rlRun -l "softhsm2-util --init-token --label $TOKEN_LABEL --free --pin $PINVALUE --so-pin $PINVALUE" 0 "Initialize token"
            rlRun -l "pkcs11-tool --keypairgen --key-type="rsa:2048" --login --pin=$PINVALUE --module=$SOFTHSM_LIB --label=$TOKEN_LABEL --id=$ID" 0 "Generating a new key pair"

            # Get serial number of the token
            TOKEN_SERIAL_NUM=$(pkcs11-tool --module $SOFTHSM_LIB -L | grep "serial num" | awk '{print $4}')
            rlAssertNotEquals "Test that the serial number is not empty" "" $TOKEN_SERIAL_NUM
            URI="{\"uri\": \"pkcs11:model=SoftHSM%20v2;serial=$TOKEN_SERIAL_NUM;token=$TOKEN_LABEL;id=$ID;module-path=$SOFTHSM_LIB?pin-value=$PINVALUE\", \"mechanism\": \"RSA-PKCS\"}"

            development_clevis

            setup_luks_encrypted_single_disk

            prepare_dracut
        fi
    rlPhaseEnd

    rlPhaseStart FAIL "clevis luks pkcs11 - disk encryption with a reboot"
        if [ $TMT_REBOOT_COUNT == 0 ]; then
            rlRun "clevis luks bind -k pwfile -d ${parent_disk} sss '{
                        \"t\": 2,
                        \"pins\": {
                            \"pkcs11\": $URI,
                            \"tpm2\": {}
                        }
                    }'"
            rlRun "systemctl enable clevis-luks-pkcs11-askpass.socket"

            rlRun "clevis luks list -d ${parent_disk}"
            rlRun "echo -n $disk_uuid > /encrypted_disk/secret_file"

            tmt-reboot -t 600

        elif [ $TMT_REBOOT_COUNT == 1 ]; then
            rlAssertExists /encrypted_disk/secret_file
            disk_uuid=$(cat /encrypted_disk/secret_file)
            rlRun "journalctl -u clevis-luks-pkcs11-askpass.service -b 0 | tee clevis-luks-service.log"
            rlAssertGrep "Device:/dev/disk/by-uuid/$disk_uuid unlocked successfully by clevis" "clevis-luks-service.log"
        fi
    rlPhaseEnd
rlJournalPrintText
rlJournalEnd
