#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/clevis/Sanity/basic/luks
#   Description: tests the pkcs11 luks functionality of clevis
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

# Include utils library containing critical functions
lib_path="${PWD%$TMT_TEST_NAME}/lib/utils.sh"
. $lib_path || exit 1

luks_setup() {
    rlAssertRpm "cryptsetup"
    # Get the name of the created disk (done by kickstart preparation) that is intended for the test.
    # This disk is a "sub disk" - its name is usually something like "/dev/vdb1"
    child_disk=$(lsblk -o NAME,MOUNTPOINT,PATH | grep "/encrypted_disk" | awk '{print $3}')

    # Get the name of the parent disk (save "/dev/vdb" out of "/dev/vdb1")
    parent_disk="/dev/$(lsblk -ndo pkname $child_disk)"

    rlRun "echo -n redhat123 > pwfile" 0 "Put disk passphrase into a file"
    # If mounted then unmount the disk
    rlRun "mountpoint -q /encrypted_disk && unmount /encrypted_disk" "Unmount the disk if it is mounted"
    #TODO: IF on RHEL-9 use the --keyfile option instead
    rlRun "cryptsetup luksFormat --batch-mode --key-file pwfile $parent_disk"
    rlRun "cat pwfile | cryptsetup open $parent_disk disk_encrypted"
    rlRun "mkfs -t ext4 /dev/mapper/disk_encrypted"
    rlRun "mount /dev/mapper/disk_encrypted /encrypted_disk"

    # Get the UUID of the parent disk and put it into the crypttab file
    disk_uuid=$(lsblk --nodeps -o uuid $parent_disk | tail -1)
    echo "luks-$disk_uuid UUID=$disk_uuid /run/systemd/clevis-pkcs11.sock keyfile-timeout=90s" >> /etc/crypttab

    # Get the UUID of the child disk and put it into the fstab file
    sed -i '/encrypted_disk/d' /etc/fstab
    disk_uuid=$(lsblk --nodeps -o uuid /dev/mapper/disk_encrypted | tail -1)
    echo "UUID=$disk_uuid /encrypted_disk ext4 defaults 0 0" >> /etc/fstab
}

prepare_dracut() {
    rlRun "dracut -f -v --include $SOFTHSM_LIB $SOFTHSM_LIB --include /etc/softhsm2.conf /etc/softhsm2.conf"
}

luks_destroy() {
    rlRun "losetup -d \"$lodev\""
    rlRun "rm -f loopfile pwfile"
}


PACKAGE="clevis"

rlJournalStart
    rlPhaseStartSetup
        if [ $TMT_REBOOT_COUNT == 0 ]; then
            rlAssertRpm $PACKAGE
            rlRun "TMPDIR=\$(mktemp -d)" 0 "Creating tmp directory"
            rlRun "pushd $TMPDIR"

            rlRun "packageVersion=$(rpm -q ${PACKAGE} --qf '%{name}-%{version}-%{release}\n')"
            # TODO: add correct version that will have the pkcs11 feature implemented
            rlTestVersion "${packageVersion}" '>=' 'clevis-20-1'

            install_softhsm

            # TODO: do we need to modify the /etc/softhsm2.conf?

            TOKEN_LABEL="test_token"
            SOFTHSM_LIB="/usr/lib64/softhsm/libsofthsm.so"
            PINVALUE=1234
            ID="0001"

            rlRun -l "softhsm2-util --init-token --label $TOKEN_LABEL --free --pin $PINVALUE --so-pin $PINVALUE" 0 "Initialize token"
            rlRun -l "pkcs11-tool --keypairgen --key-type="rsa:2048" --login --pin=$PINVALUE --module=$SOFTHSM_LIB --label=$TOKEN_LABEL --id=$ID" 0 "Generating a new key pair"

            # Get serial number of the token
            TOKEN_SERIAL_NUM=$(pkcs11-tool --module $SOFTHSM_LIB -L | grep "serial num" | awk '{print $4}')
            rlAssertNotEquals "Test that the serial number is not empty" "" $TOKEN_SERIAL_NUM
            URI="{\"uri\": \"pkcs11:model=SoftHSM%20v2;slot=0;serial=$TOKEN_SERIAL_NUM;token=$TOKEN_LABEL;id=$ID;module-path=$SOFTHSM_LIB?pin-value=$PINVALUE\", \"mechanism\": \"RSA-PKCS\"}"

            development_clevis

            luks_setup

            prepare_dracut
        fi
    rlPhaseEnd

    rlPhaseStart FAIL "clevis luks pkcs11 - disk encryption with a reboot"
        if [ $TMT_REBOOT_COUNT == 0 ]; then
            rlRun "clevis luks bind -k pwfile -d ${parent_disk} pkcs11 '$URI'" 0 "Binding the luks encrypted disk"
            rlRun "systemctl enable clevis-luks-pkcs11-askpass.socket"

            #TODO: grep the pkcs11
            rlRun "clevis luks list -d ${parent_disk}"
            rlRun "touch /encrypted_disk/secret_file"

        elif [ $TMT_REBOOT_COUNT == 1 ]; then
            # TODO: check that the disk was decrypted by the correct token (Clevis)
            rlAssertExists /encrypted_disk/secret_file
        fi
    rlPhaseEnd

    rlPhaseStartCleanup
        rlRun "softhsm2-util --delete-token --token $TOKEN_LABEL" 0,1
        rlRun "popd"
        rlRun "rm -r $TMPDIR" 0 "Removing tmp directory"
    rlPhaseEnd
rlJournalPrintText
rlJournalEnd
