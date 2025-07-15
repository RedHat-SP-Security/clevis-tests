#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/clevis/Sanity/tang-pin-hybrid-TLS
#   Description: tests tang pin with a 3-way hybrid TLS setup
#                using Nginx and a socat-wrapped tangd.
#   Author: Patrik Koncity <pkoncity@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Include Beaker environment and utils library
. /usr/bin/rhts-environment.sh || :
. /usr/share/beakerlib/beakerlib.sh || exit 1

# Generates Tang's signing and exchange keys.
gen_tang_keys() {
    rlRun "jose jwk gen -i '{\"alg\":\"ES512\"}' -o \"$1/sig.jwk\""
    rlRun "jose jwk gen -i '{\"alg\":\"ECMR\"}' -o \"$1/exc.jwk\""
}

# Decrypts a base64 encoded file and checks for a string.
grep_b64() {
    rlRun "jose b64 dec -i \"$2\" -O - | grep -q \"$1\"" 0 \
        "File '$2' should contain '$1' when b64-decrypted" || \
            jose b64 dec -i "$2" -O -
}

# Copies ALL server certificates to the system trust store.
trust_certs() {
    rlRun "cp server_ecdsa.crt /etc/pki/ca-trust/source/anchors/temp-tang-ecdsa-$$.crt"
    rlRun "cp server_mldsa.crt /etc/pki/ca-trust/source/anchors/temp-tang-mldsa-$$.crt"
    rlRun "cp server_rsa.crt /etc/pki/ca-trust/source/anchors/temp-tang-rsa-$$.crt"
    rlRun "update-ca-trust"
}

# Removes ALL certificates from the system trust store.
untrust_certs() {
    rlRun "rm -f /etc/pki/ca-trust/source/anchors/temp-tang-ecdsa-$$.crt"
    rlRun "rm -f /etc/pki/ca-trust/source/anchors/temp-tang-mldsa-$$.crt"
    rlRun "rm -f /etc/pki/ca-trust/source/anchors/temp-tang-rsa-$$.crt"
    rlRun "update-ca-trust"
}

rlJournalStart
    rlPhaseStartSetup
        rlRun ". ../../TestHelpers/utils.sh" || rlDie "cannot import function script"
        rlRun "TmpDir=\$(mktemp -d)" 0 "Creating tmp directory"
        rlRun "pushd $TmpDir"
        # Generate all three types of TLS certificates using the function from utils.sh
        rlRun "gen_tls_cert 'ECDSA' 'server_ecdsa.key' 'server_ecdsa.crt'"
        rlRun "gen_tls_cert 'ML-DSA-65' 'server_mldsa.key' 'server_mldsa.crt'"
        rlRun "gen_tls_cert 'RSA' 'server_rsa.key' 'server_rsa.crt'"
        trust_certs
        # Prepare and start Tang server
        rlRun "mkdir -p tangd/db"
        gen_tang_keys "tangd/db"
        for i in {9000..9999}; do
            if ! ss -tlpn | grep -q ":$i\s"; then
                tang_http_port="$i"
                break
            fi
        done
        [ -n "$tang_http_port" ] || { rlLogFatal "No free port for tangd"; rlDie; }
        rlLog "Starting tangd wrapped in socat on port $tang_http_port"
        nohup socat "tcp-listen:$tang_http_port,fork,reuseaddr" "exec:/usr/libexec/tangd $(pwd)/tangd/db" >/dev/null 2>&1 &
        echo "$!" > tangd.pid
        rlWaitForSocket "localhost:$tang_http_port" -t 20
        rlLogInfo "Started tangd (HTTP via socat) on port $tang_http_port with PID $(cat tangd.pid)"
        # Prepare and start Nginx reverse proxy
        for i in {8000..8999}; do
            if ! ss -tlpn | grep -q ":$i\s"; then
                https_port="$i"
                break
            fi
        done
        [ -n "$https_port" ] || { rlLogFatal "No free port for Nginx"; rlDie; }
        cat > nginx.conf <<EOF
# Managed by BeakerLib test for 3-way HYBRID TLS
pid $(pwd)/nginx.pid;
error_log $(pwd)/nginx.error.log;
events { worker_connections 1024; }
http { server {
    listen ${https_port} ssl http2;
    server_name localhost;
    ssl_certificate     $(pwd)/server_ecdsa.crt;
    ssl_certificate_key $(pwd)/server_ecdsa.key;
    ssl_certificate     $(pwd)/server_mldsa.crt;
    ssl_certificate_key $(pwd)/server_mldsa.key;
    ssl_certificate     $(pwd)/server_rsa.crt;
    ssl_certificate_key $(pwd)/server_rsa.key;
    location / { proxy_pass http://localhost:${tang_http_port}; }
} }
EOF
        rlRun "nginx -c $(pwd)/nginx.conf"
        sleep 1
        rlWaitForSocket "localhost:$https_port" -t 20
        rlLogInfo "Started Nginx proxy (3-way HYBRID) on port $https_port with PID $(cat nginx.pid)"
    rlPhaseEnd

    rlPhaseStartTest "Clevis encrypt, confirmed interactively (Hybrid HTTPS)"
        echo -n "testing data string" > plain
        expect <<CLEVIS_END
            set timeout 60
            spawn sh -c "clevis encrypt tang '{ \"url\": \"https://localhost:$https_port\" }' < plain > enc"
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

    rlPhaseStartTest "Clevis encrypt, using known thumbprint (Hybrid HTTPS)"
        rlRun "thp=\$(jose jwk thp -i tangd/db/sig.jwk)"
        echo -n "testing data string" > plain
        rlRun "clevis encrypt tang '{ \"url\": \"https://localhost:$https_port\", \"thp\": \"$thp\" }' < plain > enc"
        grep_b64 "https:" enc
        rlRun "clevis decrypt < enc > plain2"
        rlAssertNotDiffer plain plain2
        rm -f adv plain enc plain2
    rlPhaseEnd

    rlPhaseStartTest "CURL connection verification"
        rlLog "Testing hybrid TLS negotiation with curl..."
        # ECDSA
        rlLog "Forcing ECDSA cipher..."
        rlRun "curl --cacert server_ecdsa.crt -v --tls-max 1.2 --ciphers ECDHE-ECDSA-AES256-GCM-SHA384 https://localhost:$https_port/adv/ 2> ecdsa_debug.log" \
            0 "Connect with ECDSA-only cipher"
        rlRun "grep 'SSL connection using.*ECDSA' ecdsa_debug.log" \
            0 "Verify ECDSA cipher was used"
        # RSA
        rlLog "Forcing RSA cipher..."
        rlRun "curl --cacert server_rsa.crt -v --tls-max 1.2 --ciphers ECDHE-RSA-AES256-GCM-SHA384 https://localhost:$https_port/adv/ 2> rsa_debug.log" \
            0 "Connect with RSA-only cipher"
        rlRun "grep 'SSL connection using.*RSA' rsa_debug.log" \
            0 "Verify RSA cipher was used"
        # ML-DSA-65
        rlRun "curl -v --cacert server_mldsa.crt  https://localhost:$https_port/adv/ 2> mldsa_debug.log" \
            0 "Connect with ML-DSA signature algorithm"
        rlRun "grep 'SSL connection using.*id-ml-dsa-65' mldsa_debug.log" \
            0 "Verify MLDSA65 cipher was used"
    rlPhaseEnd

    rlPhaseStartCleanup
        rlLog "Stopping services..."
        if [ -f nginx.pid ]; then
            rlRun "kill \$(cat nginx.pid)" 0 "Stopping Nginx"
        fi
        if [ -f tangd.pid ]; then
            rlRun "kill \$(cat tangd.pid)" 0 "Stopping socat/tangd"
        fi

        rlRun "popd"
        untrust_certs
        rlRun "rm -r $TmpDir" 0 "Removing tmp directory"
    rlPhaseEnd
rlJournalPrintText
rlJournalEnd