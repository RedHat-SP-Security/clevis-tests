#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/clevis/Sanity/pkcs11
#   Description: tests the pkcs11 functionality of clevis
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
    # Because there is not softhsm package in the RHEL repositories (or I haven't found one)
    yum install https://kojipkgs.fedoraproject.org//packages/softhsm/2.6.1/5.el8.1/x86_64/softhsm-2.6.1-5.el8.1.x86_64.rpm -y
}

development_clevis() {
    git clone https://github.com/sarroutbi/clevis-pkcs11-pin.git
}

luks_setup() {
    rlPhaseStart FAIL "cryptsetup setup"
        rlRun "dd if=/dev/zero of=loopfile bs=100M count=1"
        rlRun "lodev=\$(losetup -f --show loopfile)"
        echo -n redhat123 > pwfile
        rlRun "cryptsetup luksFormat --batch-mode --key-file pwfile \"$lodev\""
    rlPhaseEnd
}
luks_destroy() {
    rlPhaseStart FAIL "cryptsetup destroy"
        rlRun "losetup -d \"$lodev\""
        rlRun "rm -f loopfile pwfile"
    rlPhaseEnd
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
        development_clevis

        export SOFTHSM2_CONF=$TMPDIR/softhsm.conf

        TOKEN_LABEL="test_token"
        SOFTHSM_LIB="/usr/lib64/softhsm/libsofthsm.so"
        SOFTHSM_LIB="/usr/lib64/pkcs11/libsofthsm2.so"
        PINVALUE=1234
        ID="0001"
        rlRun -l "softhsm2-util --init-token --label $TOKEN_LABEL --free --pin $PINVALUE --so-pin $PINVALUE"
        rlRun -l "pkcs11-tool --keypairgen --key-type="EC:secp256r1" --login --pin=$PINVALUE --module=$SOFTHSM_LIB --label=$TOKEN_LABEL --id=0001"
        rlRun -l "pkcs11-tool -O --module $SOFTHSM_LIB --login --pin=$PINVALUE"
        rlRun -l "pkcs11-tool -L --module $SOFTHSM_LIB"
        # Get serial number of the token
        TOKEN_SERIAL_NUM=$(pkcs11-tool --module $SOFTHSM_LIB -L | grep "serial num" | awk '{print $4}')

        # Make sure the softhsm module is loaded on initramfs
        dracut -v -f --include $SOFTHSM_LIB $SOFTHSM_LIB
        grub2-mkconfig -o /boot/grub2/grub.cfg

        #luks_setup
    rlPhaseEnd
    
    rlPhaseStart FAIL "clevis pkcs11 - Customer scenario two factor"
        rlRun "cat \$TMPDIR/softhsm.conf"
        rlRun "echo 'this is a secret' > plain_text"
        #clevis encrypt pkcs11 CONFIG < PLAINTEXT > JWE"
        #TODO: module-path may need to be percent encoded as well
        uri="{\"uri\": \"pkcs11:model=SoftHSM%20v2;manufacturer=SoftHSM%20project;serial=$TOKEN_SERIAL_NUM;token=$TOKEN_LABEL;id=$ID;module-path=$SOFTHSM_LIB?pin-value=$PINVALUE\"}"
        #rlRun clevis encrypt sss '{
        #            \"t\": 2,
        #            \"pins\": {
        #                \"pkcs11\": $uri,
        #                \"tpm2\"
        #            }
        #        }' $uri < plain_text > JWE
        #clevis luks bind
        # reboot?
        #rlRun clevis decrypt pkcs11 < JWE > decrypted_message"
        # assert diff decrypted_message plain_text
        #rlRun rm plain_text decrypted_message JWE
    rlPhaseEnd

    rlPhaseStartCleanup
        rlRun "softhsm2-util --delete-token --token $TOKEN_LABEL"
        rlRun "popd"
        rlRun "rm -r $TMPDIR" 0 "Removing tmp directory"
        #luks_destroy
    rlPhaseEnd
rlJournalPrintText
rlJournalEnd
