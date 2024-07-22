#!/bin/bash

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
    popd
}