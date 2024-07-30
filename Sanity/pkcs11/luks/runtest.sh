#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/clevis/Sanity/pkcs11/luks
#   Description: tests the basic pkcs11 luks functionality of clevis
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
    rlRun "dd if=/dev/zero of=loopfile bs=100M count=1"
    rlRun "lodev=\$(losetup -f --show loopfile)"
    echo -n redhat123 > pwfile
    rlRun "cryptsetup luksFormat --batch-mode --key-file pwfile \"$lodev\""
}
luks_destroy() {
    rlRun "losetup -d \"$lodev\""
    rlRun "rm -f loopfile pwfile"
}


PACKAGE="clevis"

rlJournalStart
    rlPhaseStartSetup
        rlAssertRpm $PACKAGE
        # Include utils library containing critical functions
        rlRun ". ../../../TestHelpers/utils.sh" || rlDie "cannot import function script"
        rlRun "TMPDIR=\$(mktemp -d)" 0 "Creating tmp directory"
        rlRun "pushd $TMPDIR"

        rlRun "packageVersion=$(rpm -q ${PACKAGE} --qf '%{name}-%{version}-%{release}\n')"
        # TODO: add correct version that will have the pkcs11 feature implemented
        rlTestVersion "${packageVersion}" '>=' 'clevis-20-1'

        install_softhsm

        create_hsm_config

        export SOFTHSM2_CONF=$TMPDIR/softhsm.conf
        TOKEN_LABEL="test_token"
        SOFTHSM_LIB="/usr/lib64/softhsm/libsofthsm.so"
        PINVALUE=1234
        ID="0001"

        rlRun -l "softhsm2-util --init-token --label $TOKEN_LABEL --free --pin $PINVALUE --so-pin $PINVALUE" 0 "Initialize token"
        rlRun -l "pkcs11-tool --keypairgen --key-type="rsa:2048" --login --pin=$PINVALUE --module=$SOFTHSM_LIB --label=$TOKEN_LABEL --id=$ID" 0 "Generating a new key pair"

        # Get serial number of the token
        TOKEN_SERIAL_NUM=$(pkcs11-tool --module $SOFTHSM_LIB -L | grep "serial num" | awk '{print $4}')
        rlAssertNotEquals "Test that the serial number is not empty" "" $TOKEN_SERIAL_NUM
        URI="{\"uri\": \"pkcs11:model=SoftHSM%20v2;manufacturer=SoftHSM%20project;serial=$TOKEN_SERIAL_NUM;token=$TOKEN_LABEL;id=$ID;module-path=$SOFTHSM_LIB?pin-value=$PINVALUE\", \"mechanism\": \"RSA-PKCS\"}"

        development_clevis

        luks_setup
    rlPhaseEnd

    rlPhaseStart FAIL "clevis luks pkcs11 - Simple disk binding"
        rlRun "clevis luks bind -k pwfile -d ${lodev} pkcs11 '$URI'" 0 "Binding the luks encrypted disk"
        rlRun "clevis luks unlock -d ${lodev} -n test_disk" 0 "Unlock the binded disk"

        rlRun "lsblk | grep test_disk > grep_output" 0 "Check that the encrypted disk is visible"
        rlAssertGrep "crypt" grep_output
        rlRun "cryptsetup close test_disk"

        # Verify that it is not possible to unlock the disk if the card is not present
        rlRun "softhsm2-util --delete-token --token $TOKEN_LABEL" 0 "Delete the token to simulate card removal"
        rlRun "clevis luks unlock -d ${lodev} -n test_disk" 1 "Unlocking the disk should fail as the card is not present"

        rlRun "clevis luks unbind -d ${lodev} -s 1 -f"
        rlRun "rm grep_output"
    rlPhaseEnd

    rlPhaseStart FAIL "clevis luks pkcs11 - two factor disk encryption"
        Create a token as it was removed in previous test case
        rlRun -l "softhsm2-util --init-token --label $TOKEN_LABEL --free --pin $PINVALUE --so-pin $PINVALUE" 0 "Initialize token"
        rlRun -l "pkcs11-tool --keypairgen --key-type="rsa:2048" --login --pin=$PINVALUE --module=$SOFTHSM_LIB --label=$TOKEN_LABEL --id=$ID" 0 "Generating a new key pair"
        rlRun -l "pkcs11-tool -L --module=$SOFTHSM_LIB"
        Get serial number of the token
        TOKEN_SERIAL_NUM=$(pkcs11-tool --module $SOFTHSM_LIB -L | grep "serial num" | awk '{print $4}')
        rlAssertNotEquals "Test that the serial number is not empty" "" $TOKEN_SERIAL_NUM
        URI="{\"uri\": \"pkcs11:model=SoftHSM%20v2;manufacturer=SoftHSM%20project;serial=$TOKEN_SERIAL_NUM;token=$TOKEN_LABEL;id=$ID;module-path=$SOFTHSM_LIB?pin-value=$PINVALUE\", \"mechanism\": \"RSA-PKCS\"}"

        rlRun -l "lsblk"
        rlRun "clevis luks bind -k pwfile -d ${lodev} sss '{
                        \"t\": 2,
                        \"pins\": {
                            \"pkcs11\": $URI,
                            \"tpm2\": {}
                        }
                    }'"
        rlRun "clevis luks unlock -d ${lodev} -n test_disk" 0 "Unlock the binded disk"
        rlRun "lsblk | grep test_disk > grep_output" 0 "Check that the encrypted disk is visible"
        rlAssertGrep "crypt" grep_output
        rlRun "cryptsetup close test_disk"

         # Verify that it is not possible to unlock the disk if one of the the factors is not present (the card is not present)
        rlRun "softhsm2-util --delete-token --token $TOKEN_LABEL" 0 "Delete the token to simulate card removal"as
        rlRun "clevis luks unlock -d ${lodev} -n test_disk" 1 "Unlocking the disk should fail as the card is not present"

        rlRun "clevis luks unbind -d ${lodev} -s 1 -f"
        rlRun "rm grep_output"
    rlPhaseEnd

    rlPhaseStartCleanup
        luks_destroy
        rlRun "softhsm2-util --delete-token --token $TOKEN_LABEL" 0,1
        rlRun "popd"
        rlRun "rm -r $TMPDIR" 0 "Removing tmp directory"
    rlPhaseEnd
rlJournalPrintText
rlJournalEnd
