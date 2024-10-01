#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/clevis/Sanity/basic/pkcs11
#   Description: tests the basic pkcs11 functionality of clevis
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

PACKAGE="clevis"

rlJournalStart
    rlPhaseStartSetup
        rlAssertRpm $PACKAGE
        # Include utils library containing critical functions
        rlRun ". ../../../TestHelpers/utils.sh" || rlDie "cannot import function script"
        rlRun "TMPDIR=\$(mktemp -d)" 0 "Creating tmp directory"
        rlRun "pushd $TMPDIR"

        rlRun "packageVersion=$(rpm -q ${PACKAGE} --qf '%{name}-%{version}-%{release}\n')"
        rlTestVersion "${packageVersion}" '>=' 'clevis-20-2'

        install_softhsm

        create_hsm_config

        export SOFTHSM2_CONF=$TMPDIR/softhsm.conf
        create_token

        # Get serial number of the token
        TOKEN_SERIAL_NUM=$(pkcs11-tool --module $SOFTHSM_LIB -L | grep "serial num" | awk '{print $4}')
        rlAssertNotEquals "Test that the serial number is not empty" "" $TOKEN_SERIAL_NUM
        URI="{\"uri\": \"pkcs11:model=SoftHSM%20v2;manufacturer=SoftHSM%20project;serial=$TOKEN_SERIAL_NUM;token=$TOKEN_LABEL;id=$ID;module-path=$SOFTHSM_LIB?pin-value=$PINVALUE\", \"mechanism\": \"RSA-PKCS\"}"

        development_clevis
    rlPhaseEnd

    rlPhaseStart FAIL "clevis pkcs11 - Simple text encryption and decryption"
        rlRun "echo 'this is a secret 1' > plain_text" 0 "Create a file to encrypt"
        rlRun "clevis encrypt pkcs11 '$URI' < plain_text > JWE" 0 "Encrypting the plain text"

        rlAssertDiffer JWE plain_text

        rlRun "clevis decrypt pkcs11 < JWE > decrypted_message" 0 "Decrypting the JWE"
        rlAssertNotDiffer decrypted_message plain_text
        rlRun "rm plain_text decrypted_message JWE"
    rlPhaseEnd

    rlPhaseStart FAIL "Simple text encryption and decryption (pin-source)"
        # TODO: Uncomment once implemention is finished:
        #   - THE PIN-SOURCE attribute not yet implemented

        # rlRun "echo $PINVALUE > $PWD/pin"
        # URI="{\"uri\": \"pkcs11:model=SoftHSM%20v2;manufacturer=SoftHSM%20project;serial=$TOKEN_SERIAL_NUM;token=$TOKEN_LABEL;id=$ID;module-path=$SOFTHSM_LIB?pin-source=$PWD/pin\", \"mechanism\": \"RSA-PKCS\"}"
        # rlRun "echo 'this is a secret 2' > plain_text" 0 "Create a file to encrypt"
        # rlRun "clevis encrypt pkcs11 '$URI' < plain_text > JWE" 0 "Encrypting the plain text"

        # rlAssertDiffer JWE plain_text

        # rlRun "clevis decrypt pkcs11 < JWE > decrypted_message" 0 "Decrypting the JWE"
        # rlAssertNotDiffer decrypted_message plain_text
        # rlRun "rm plain_text decrypted_message JWE $PWD/pin"
    rlPhaseEnd

    rlPhaseStart FAIL "clevis pkcs11 - Simple text encryption and decryption (empty pkcs11 URI)"
        # TODO: Uncomment once implemention is finished:
        #   - Clevis does not ask for a password when encrypting/decrypting thus failing to decrypt the message

        # rlRun "echo 'this is secret 3' > plain_text" 0 "Create a file to encrypt"
        # # (the module-path should be used because softhsm is a software token and not hardware one)
        # URI="{\"uri\": \"pkcs11:module-path=$SOFTHSM_LIB\", \"mechanism\": \"RSA-PKCS\"}"
        # rlRun "clevis encrypt pkcs11 '$URI' < plain_text > JWE" 0 "Encrypting the plain text"

        # rlAssertDiffer JWE plain_text

        # # The clevis should also ask for a password
        # rlRun "clevis decrypt pkcs11 < JWE > decrypted_message" 0 "Decrypting the JWE"
        # rlAssertNotDiffer decrypted_message plain_text
        # rlRun "rm plain_text decrypted_message JWE"
    rlPhaseEnd

    rlPhaseStart FAIL "Simple text encryption and decryption (RSA-PKCS-OAEP mechanism)"
        # TODO: Uncomment once implemention is finished:
        #   - THE RSA-PKCS-OAEP mechanism is not implemented in the softhsm
        # URI="{\"uri\": \"pkcs11:model=SoftHSM%20v2;manufacturer=SoftHSM%20project;serial=$TOKEN_SERIAL_NUM;token=$TOKEN_LABEL;id=$ID;module-path=$SOFTHSM_LIB?pin-value=$PINVALUE\", \"mechanism\": \"RSA-PKCS-OAEP\"}"
        # rlRun "echo 'this is a secret 4' > plain_text" 0 "Create a file to encrypt"
        # rlRun "clevis encrypt pkcs11 '$URI' < plain_text > JWE" 0 "Encrypting the plain text"

        #  rlAssertDiffer JWE plain_text

        # rlRun "clevis decrypt pkcs11 < JWE > decrypted_message" 0 "Decrypting the JWE"
        # rlAssertNotDiffer decrypted_message plain_text
        # rlRun "rm plain_text decrypted_message JWE $PWD/pin"
    rlPhaseEnd

    rlPhaseStart FAIL "Simple text encryption and decryption (card removal before decryption)"
        rlRun "echo 'this is a secret 5' > plain_text" 0 "Create a file to encrypt"
        URI="{\"uri\": \"pkcs11:model=SoftHSM%20v2;manufacturer=SoftHSM%20project;serial=$TOKEN_SERIAL_NUM;token=$TOKEN_LABEL;id=$ID;module-path=$SOFTHSM_LIB?pin-value=$PINVALUE\", \"mechanism\": \"RSA-PKCS\"}"
        rlRun "clevis encrypt pkcs11 '$URI' < plain_text > JWE"

        rlAssertDiffer JWE plain_text

        rlRun "softhsm2-util --delete-token --token $TOKEN_LABEL" 0 "Delete the token to simulate card removal"
        rlRun -l "clevis decrypt pkcs11 < JWE" 1 "It is expected to fail the decryption as the token card was deleted"
        rlRun "rm plain_text JWE"
    rlPhaseEnd

    rlPhaseStartCleanup
        rlRun "softhsm2-util --delete-token --token $TOKEN_LABEL" 0,1
        rlRun "popd"
        rlRun "rm -r $TMPDIR" 0 "Removing tmp directory"
    rlPhaseEnd
rlJournalPrintText
rlJournalEnd
