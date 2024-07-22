#!/bin/bash

create_hsm_config() {
<<<<<<< HEAD
    # Create a configuration file for the softhsm

    rlLog "Creating a softhsm configuration file"
=======
    # Create a configuration file
>>>>>>> 405c987 (Move functions into a separate lib file)
    cat > $TMPDIR/softhsm.conf << EOF
directories.tokendir = $TMPDIR
objectstore.backend = file
log.level = DEBUG
EOF
}

install_softhsm() {
    # TODO: the test may only run on latest Feodra and RHEL>9 versions:
    #   https://issues.redhat.com/browse/RHEL-34856
<<<<<<< HEAD
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
    rlRun "git clone https://github.com/sarroutbi/clevis -b 202405281240-clevis-pkcs11"
    pushd clevis
    rlRun "rm -fr build; mkdir build; pushd build; meson setup --prefix=/usr --wipe ..; meson compile -v; meson install; popd"
=======
    yum install softhsm -y
}

development_clevis() {
    # TODO: remove once the clevis pkcs11 feature development is done
    rlIsRHEL 9
    if [ $? -eq 0 ]; then
        dnf install python-pip gcc clang cmake jose libjose cryptsetup socat tpm2-tools luksmeta libluksmeta -y
    else
        dnf install python-pip gcc clang cmake jose libjose-devel cryptsetup-devel socat tpm2-tools luksmeta libluksmeta-devel -y
    fi

    pip3 install ninja meson
    git clone https://github.com/sarroutbi/clevis -b 202405281240-clevis-pkcs11
    pushd clevis
    rm -fr build; mkdir build; pushd build; meson setup --prefix=/usr --wipe ..; meson compile -v; meson install; popd
>>>>>>> 405c987 (Move functions into a separate lib file)
    popd
}