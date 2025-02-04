#!/bin/bash

create_hsm_config() {
    # Create a configuration file for the softhsm

    rlLog "Creating a softhsm configuration file"
    cat > $TMPDIR/softhsm.conf << EOF
directories.tokendir = $TMPDIR
objectstore.backend = file
log.level = DEBUG
EOF
}

install_softhsm() {
    # TODO: the test may only run on latest Feodra and RHEL>9 versions:
    #   https://issues.redhat.com/browse/RHEL-34856
    rlRun "dnf install softhsm -y"
}

install_clevis_pkcs11() {
    if rpm -qa | grep -q clevis-pin-pkcs11; then
        export PKCS11_IMPLEMENTED=1
        rlRun "rpm -q clevis-pin-pkcs11"
        rlLogInfo "Package is already installed on system!"
    else
        rlRun "dnf info clevis-pin-pkcs11 && dnf install -y clevis-pin-pkcs11 || :"
    fi
}

luks_setup() {
    # Create disk out of the file on the system.
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

prepare_dracut() {
    # Put the softhsm library and the configuration file to initramfs so it can be used
    # by Clevis to load the smartcard and decrypt the disk.
    rlPhaseStart FAIL "softhsm dracut setup"
        rlRun "dracut -f -v --include $SOFTHSM_LIB $SOFTHSM_LIB --include /etc/softhsm2.conf /etc/softhsm2.conf" 0 "Include softhsm libraries in initramfs"
    rlPhaseEnd
}

create_token() {
    # Create a softhsm token
    rlPhaseStart FAIL "create softhsm token"
        TOKEN_LABEL="test_token"
        SOFTHSM_LIB="/usr/lib64/softhsm/libsofthsm.so"
        PINVALUE=1234
        ID="0001"

        rlRun -l "softhsm2-util --init-token --label $TOKEN_LABEL --free --pin $PINVALUE --so-pin $PINVALUE" 0 "Initialize token"
        rlRun -l "pkcs11-tool --keypairgen --key-type="rsa:2048" --login --pin=$PINVALUE --module=$SOFTHSM_LIB --label=$TOKEN_LABEL --id=$ID" 0 "Generating a new key pair"

        rlRun -l "pkcs11-tool -L --module=$SOFTHSM_LIB"
    rlPhaseEnd
}
