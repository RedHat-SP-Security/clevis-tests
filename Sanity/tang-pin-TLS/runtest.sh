#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/clevis/Sanity/tang-pin-TLS
#   Description: tests the tang pin functionality of clevis.
#                This version requires a TLS connection.
#   Author: Patrik Koncity <pkoncity@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Include Beaker environment
. /usr/bin/rhts-environment.sh || :
. /usr/share/beakerlib/beakerlib.sh || exit 1

# --- Configuration ---
# Set the TLS certificate algorithm via the CRYPTO_ALG environment variable.
CRYPTO_ALG=${CRYPTO_ALG:-RSA}
# Use the Process ID to create a unique name for the trusted certificate
UNIQUE_CERT_FILE="temp-tang-cert-$$.crt"

gen_tang_keys() {
    rlRun "jose jwk gen -i '{\"alg\":\"ES512\"}' -o \"$1/sig.jwk\""
    rlRun "jose jwk gen -i '{\"alg\":\"ECMR\"}' -o \"$1/exc.jwk\""
}

gen_tang_cache() {
    rlRun "/usr/libexec/tangd-update \"$1\" \"$2\""
}


grep_b64() {
    rlRun "jose b64 dec -i \"$2\" -O - | grep -q \"$1\"" 0 \
        "File '$2' should contain '$1' when b64-decrypted" || \
            jose b64 dec -i "$2" -O -
}

# Copies the certificate to the system trust store with a unique name.
trust_cert() {
    rlRun "cp server.crt /etc/pki/ca-trust/source/anchors/$UNIQUE_CERT_FILE"
    rlRun "update-ca-trust"
}

# Removes the unique certificate from the system trust store.
untrust_cert() {
    rlRun "rm -f /etc/pki/ca-trust/source/anchors/$UNIQUE_CERT_FILE"
    rlRun "update-ca-trust"
}

PACKAGE="clevis"

rlJournalStart
    rlPhaseStartSetup
        rlRun ". ../../TestHelpers/utils.sh" || rlDie "cannot import function script"
        rlLog "TLS Certificate Algorithm: $CRYPTO_ALG"
        rlLog "TLS is ENABLED for this run."
        rlRun "TmpDir=\$(mktemp -d)" 0 "Creating tmp directory"
        rlRun "pushd $TmpDir"
        rlRun "gen_tls_cert ${CRYPTO_ALG}"
        trust_cert
    rlPhaseEnd

    rlPhaseStart FAIL "tangd setup"
        # NOTE: This 'legacy_tang' check is from an old script version and will likely fail.
        # It's better to remove this if/else block if you only support modern tang.
        if [ -x /usr/libexec/tangd-update ]; then
            rlRun "mkdir -p tangd/db tangd/cache"
            gen_tang_keys "tangd/db"
            gen_tang_cache "tangd/db" "tangd/cache"
            port=$(start_tang_fn "tangd/cache")
        else
            rlRun "mkdir -p tangd/db"
            gen_tang_keys "tangd/db"
            port=$(start_tang_fn "tangd/db")
        fi
    rlPhaseEnd

    rlPhaseStart FAIL "clevis encrypt, confirmed interactively (HTTPS)"
        echo -n "testing data string" > plain
        expect <<CLEVIS_END
            set timeout 60
            spawn sh -c "clevis encrypt tang '{ \"url\": \"https://localhost:$port\" }' < plain > enc"
            expect {
                {*Do you wish to trust these keys} {send y\\r}
            }
            expect eof
            wait
CLEVIS_END
        rlAssert0 "expect spawning clevis" $?
        grep_b64 "https:" enc
        rlRun "clevis decrypt < enc > plain2"
        rlAssertNotDiffer plain plain2
        rm -f plain enc plain2
    rlPhaseEnd

    rlPhaseStart FAIL "clevis encrypt, using known thumbprint (HTTPS)"
        rlRun "thp=\$(jose jwk thp -i tangd/db/sig.jwk)"
        echo -n "testing data string" > plain
        rlRun "clevis encrypt tang '{ \"url\": \"https://localhost:$port\", \"thp\": \"$thp\" }' < plain > enc"
        grep_b64 "https:" enc
        rlRun "clevis decrypt < enc > plain2"
        rlAssertNotDiffer plain plain2
        rm -f adv plain enc plain2
    rlPhaseEnd

    rlPhaseStartCleanup
        stop_tang_fn "$port"
        rlRun "popd"
        untrust_cert
        rlRun "rm -r $TmpDir" 0 "Removing tmp directory"
    rlPhaseEnd
rlJournalPrintText
rlJournalEnd