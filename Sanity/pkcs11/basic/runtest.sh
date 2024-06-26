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
#   Copyright (c) 2017 Red Hat, Inc.
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


create_hsm_config() {
    # Create a configuration file
    cat > $TMPDIR/softhsm.conf << EOF
directories.tokendir = $TMPDIR
objectstore.backend = file
log.level = DEBUG
EOF
}

install_softhsm() {
    # TODO: the test may only run on latest Feodra and RHEL>9 versions:
    #   https://issues.redhat.com/browse/RHEL-34856

    # On RHEL8 there is no softhsm package in the repositories (or I haven't found one)
    # Also the pkcs11 may work
    if [ rlIsRHEL '8']; then
        yum install https://kojipkgs.fedoraproject.org//packages/softhsm/2.6.1/5.el8.1/x86_64/softhsm-2.6.1-5.el8.1.x86_64.rpm -y
    else
        yum install softhsm -y
    fi
}

development_clevis() {
    # TODO: remove once the development is done
    git clone https://github.com/sarroutbi/clevis -b 202405281240-clevis-pkcs11
}


PACKAGE="clevis"

rlJournalStart
    rlPhaseStartSetup
        rlAssertRpm $PACKAGE
        rlRun "TMPDIR=\$(mktemp -d)" 0 "Creating tmp directory"
        rlRun "pushd $TMPDIR"

        rlRun "packageVersion=$(rpm -q ${PACKAGE} --qf '%{name}-%{version}-%{release}\n')"
        rlTestVersion "${packageVersion}" '>=' 'clevis-15-8'

        install_softhsm
        rlLog "Creating a softhsm configuration file"
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
        URI="{\"uri\": \"pkcs11:model=SoftHSM%20v2;manufacturer=SoftHSM%20project;serial=$TOKEN_SERIAL_NUM;token=$TOKEN_LABEL;id=$ID;module-path=$SOFTHSM_LIB?pin-value=$PINVALUE\"}"
    rlPhaseEnd

    rlPhaseStart FAIL "clevis pkcs11 - Simple text encryption and decryption"
        rlRun "echo 'this is a secret' > plain_text" 0 "Create a file to encrypt"
        rlRun "clevis encrypt pkcs11 '$URI' < plain_text > JWE" 0 "Encrypting the plain text"

        rlAssertDiffer JWE plain_text

        rlRun "clevis decrypt pkcs11 < JWE > decrypted_message" 0 "Decrypting the JWE"
        rlAssertNotDiffer decrypted_message plain_text
        rlRun "rm plain_text decrypted_message JWE"
    rlPhaseEnd

    rlPhaseStart FAIL "Simple text encryption and decryption (pin-source)"
        # TODO:
        # THE PIN-SOURCE attribute not yet implemented so this test case will fail
        rlRun "echo $PINVALUE > $PWD/pin"
        URI="{\"uri\": \"pkcs11:model=SoftHSM%20v2;manufacturer=SoftHSM%20project;serial=$TOKEN_SERIAL_NUM;token=$TOKEN_LABEL;id=$ID;module-path=$SOFTHSM_LIB?pin-source=$PWD/pin\"}"
        rlRun "echo 'this is a second secret' > plain_text" 0 "Create a file to encrypt"
        rlRun "clevis encrypt pkcs11 '$URI' < plain_text > JWE" 0 "Encrypting the plain text"

         rlAssertDiffer JWE plain_text

        rlRun "clevis decrypt pkcs11 < JWE > decrypted_message" 0 "Decrypting the JWE"
        rlAssertNotDiffer decrypted_message plain_text
        rlRun "rm plain_text decrypted_message JWE $PWD/pin"
    rlPhaseEnd

    rlPhaseStart FAIL "Simple text encryption and decryption (card removal before decryption)"
        rlRun "echo 'this is a third secret' > plain_text" 0 "Create a file to encrypt"
        URI="{\"uri\": \"pkcs11:model=SoftHSM%20v2;manufacturer=SoftHSM%20project;serial=$TOKEN_SERIAL_NUM;token=$TOKEN_LABEL;id=$ID;module-path=$SOFTHSM_LIB?pin-value=$PINVALUE\"}"
        rlRun "clevis encrypt pkcs11 '$URI' < plain_text > JWE"

        rlAssertDiffer JWE plain_text

        rlRun "softhsm2-util --delete-token --token $TOKEN_LABEL" 0 "Delete the token to simulate card removal"
        rlRun -l "clevis decrypt pkcs11 < JWE" 1 "It is expected to fail the decryption as the card token was deleted"
        rlRun "rm plain_text JWE"
    rlPhaseEnd

    rlPhaseStartCleanup
        rlRun "softhsm2-util --delete-token --token $TOKEN_LABEL" 0,1
        rlRun "popd"
        rlRun "rm -r $TMPDIR" 0 "Removing tmp directory"
    rlPhaseEnd
rlJournalPrintText
rlJournalEnd
