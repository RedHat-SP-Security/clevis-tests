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

development_clevis() {
    # TODO: remove this whole function once the clevis pkcs11 feature development is done
    rlIsRHEL 9
    if [ $? -eq 0 ]; then
        rlRun "dnf install python-pip gcc clang cmake jose libjose cryptsetup socat tpm2-tools luksmeta libluksmeta -y"
    else
        rlRun "dnf install python-pip gcc clang cmake jose libjose-devel cryptsetup-devel socat tpm2-tools luksmeta libluksmeta-devel -y"
    fi

    rlRun "pip3 install ninja meson"
    rlRun "git clone https://github.com/latchset/clevis"
    rlRun "pushd clevis"
    rlRun "rm -fr build; mkdir build; pushd build; meson setup --prefix=/usr --wipe ..; meson compile -v; meson install; popd"
    rlRun "popd"
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
