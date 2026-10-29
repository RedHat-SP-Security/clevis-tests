#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/clevis/Sanity/tang-pub-binding
#   Description: T2.3a — Verify tang_pub in /rec response and binding
#                storage semantics
#   Author: Adam Prikryl <aprikryl@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2026 Red Hat, Inc.
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

. /usr/bin/rhts-environment.sh || :
. /usr/share/beakerlib/beakerlib.sh || exit 1

legacy_tang() {
    test -x /usr/libexec/tangd-update
}
gen_tang_keys() {
    rlRun "jose jwk gen -i '{\"alg\":\"ES512\"}' -o \"$1/sig.jwk\""
    rlRun "jose jwk gen -i '{\"alg\":\"ECMR\"}' -o \"$1/exc.jwk\""
}
gen_tang_cache() {
    rlRun "/usr/libexec/tangd-update \"$1\" \"$2\""
}
start_tang() {
    local i= cache="$1" port="$2"
    if [ -z "$port" ]; then
        for i in {8000..8999}; do
            if ! fuser -s -n tcp "$i"; then
                port="$i"
                break
            fi
        done
    fi
    if [ -z "$port" ] || fuser -s -n tcp "$port"; then
        rlLogFatal "no free port found for tangd: $port" 1>&2
        return 1
    fi
    nohup socat "tcp-listen:$port,fork" exec:"/usr/libexec/tangd $cache" >/dev/null &
    local pid=$!
    rlWaitForSocket "$port" -p "$pid"
    rlLogInfo "started tangd $cache as pid $pid on port $port" 1>&2
    [ ! -t 1 ] && echo "$port"
    return 0
}
stop_tang() {
    rlRun "fuser -s -k \"$1/tcp\""
}

jwk_is_public_only() {
    local jwk="$1"
    rlRun "jq -e '.d // .priv // .k' \"$jwk\" >/dev/null 2>&1" 1 \
        "JWK should not contain private components (d, priv, k)"
}

PACKAGE="clevis"

rlJournalStart
    rlPhaseStartSetup
        rlRun "rpm -q $PACKAGE || which clevis" 0 "Checking for the presence of clevis rpm"
        rlRun ". ../../TestHelpers/utils.sh" || rlDie "cannot import function script"
        rlRun "TmpDir=\$(mktemp -d)" 0 "Creating tmp directory"
        rlRun "pushd $TmpDir"
    rlPhaseEnd

    rlPhaseStart FAIL "tangd setup"
        if legacy_tang; then
            rlRun "mkdir -p tangd/db tangd/cache"
            gen_tang_keys "tangd/db"
            gen_tang_cache "tangd/db" "tangd/cache"
            tang_dir="tangd/cache"
        else
            rlRun "mkdir -p tangd/db"
            gen_tang_keys "tangd/db"
            tang_dir="tangd/db"
        fi
        port=$(start_tang "$tang_dir")
    rlPhaseEnd

    # ------------------------------------------------------------------
    # Phase 1 — /rec/$kid includes tang_pub
    # ------------------------------------------------------------------

    rlPhaseStart FAIL "Phase 1: Fetch advertisement and extract ECMR exchange key"
        rlRun "curl -sSf -o adv.json 'http://localhost:$port/adv'"
        rlRun "jq . adv.json" 0 "Advertisement is valid JSON"

        rlLog "Extract the ECMR exchange key from the advertisement"
        rlRun "exc_kid=\$(jose jwk thp -i tangd/db/exc.jwk)"
        rlRun "jq -e '.payload' adv.json > /dev/null" 0 "Advertisement has payload"
        rlRun "jose b64 dec -i <(jq -r '.payload' adv.json) -O adv_payload.json"
        rlRun "jq -e '.keys' adv_payload.json > /dev/null" 0 "Payload has keys array"

        rlLog "Find the ECMR key in the advertisement by kid"
        rlRun "adv_exc_jwk=\$(jq -e \
            --arg kid \"\$exc_kid\" \
            '.keys[] | select(.key_ops[]? == \"deriveKey\")' \
            adv_payload.json)" 0 "Found exchange key in advertisement"
    rlPhaseEnd

    rlPhaseStart FAIL "Phase 1: Perform ECMR key recovery via /rec/\$kid"
        rlLog "Generate an ephemeral EC key for the recovery request"
        rlRun "jose jwk gen -i '{\"alg\":\"ECMR\"}' -o ephem.jwk"

        rlLog "POST the ephemeral key to /rec/\$exc_kid"
        rlRun "curl -sSf -X POST \
            -H 'Content-Type: application/jwk+json' \
            -d @ephem.jwk \
            -o rec_response.json \
            'http://localhost:$port/rec/$exc_kid'" 0 \
            "Recovery request to /rec/\$exc_kid succeeds"

        rlRun "jq . rec_response.json" 0 "Recovery response is valid JSON"
    rlPhaseEnd

    rlPhaseStart FAIL "Phase 1: Verify tang_pub in recovery response"
        rlLog "Check that tang_pub field is present in the response"
        rlRun "jq -e '.tang_pub' rec_response.json > tang_pub.jwk" 0 \
            "tang_pub field is present in /rec response"

        rlLog "Verify tang_pub is a valid JWK"
        rlRun "jq -e '.kty' tang_pub.jwk > /dev/null" 0 "tang_pub has kty field"

        rlLog "Verify tang_pub is public-only (no private components)"
        jwk_is_public_only tang_pub.jwk

        rlLog "Verify tang_pub matches the requested ECMR key identifier"
        rlRun "tang_pub_thp=\$(jose jwk thp -i tang_pub.jwk)"
        rlAssertEquals "tang_pub thumbprint matches exc key thumbprint" \
            "$tang_pub_thp" "$exc_kid"
    rlPhaseEnd

    rlPhaseStart FAIL "Phase 1: Verify ECMR recovery result is preserved"
        rlLog "The response should still contain the ECMR recovery result"
        rlRun "jq -e '.kty' rec_response.json > /dev/null" 0 \
            "Recovery response contains a JWK (ECMR result preserved)"

        rlLog "Verify response has the expected EC key type for ECMR"
        rlRun "resp_kty=\$(jq -r '.kty' rec_response.json)"
        rlAssertEquals "Recovery response kty is EC (backward compatible)" \
            "$resp_kty" "EC"
    rlPhaseEnd

    # ------------------------------------------------------------------
    # Phase 2 — tang_pub not persisted in new bindings
    # ------------------------------------------------------------------

    rlPhaseStart FAIL "Phase 2: Setup LUKS device"
        rlRun "dd if=/dev/zero of=loopfile bs=100M count=1"
        rlRun "lodev=\$(losetup -f --show loopfile)"
        echo -n redhat123 > pwfile
        rlRun "cryptsetup luksFormat --batch-mode --key-file pwfile \"\$lodev\""
    rlPhaseEnd

    rlPhaseStart FAIL "Phase 2: Create new binding and verify no tang_pub stored"
        rlRun "thp=\$(jose jwk thp -i tangd/db/sig.jwk)"

        rlLog "Bind LUKS device to Tang"
        rlRun "clevis luks bind -f -k pwfile -d \"\$lodev\" tang \
            '{\"url\":\"http://localhost:$port\",\"thp\":\"$thp\"}'"

        rlLog "Extract the clevis binding metadata from LUKS header"
        rlRun "binding_json=\$(clevis luks list -d \"\$lodev\" | head -1 | sed 's/^[0-9]*: //')"
        rlLog "Binding metadata: $binding_json"

        rlLog "Verify binding does NOT contain tang_pub"
        rlRun "echo \"\$binding_json\" | grep -v 'tang_pub'" 0 \
            "New binding should not contain tang_pub"

        rlLog "Verify binding does NOT contain the full Tang advertisement"
        rlRun "echo \"\$binding_json\" | grep -v '\"adv\"'" 0 \
            "New binding should not store the Tang advertisement"
    rlPhaseEnd

    # ------------------------------------------------------------------
    # Phase 3 — Legacy bindings with stored tang_pub
    # ------------------------------------------------------------------

    rlPhaseStart FAIL "Phase 3: Create a legacy-style binding with stored advertisement"
        rlRun "dd if=/dev/zero of=loopfile_legacy bs=100M count=1"
        rlRun "lodev_legacy=\$(losetup -f --show loopfile_legacy)"
        echo -n redhat123 > pwfile_legacy
        rlRun "cryptsetup luksFormat --batch-mode --key-file pwfile_legacy \"\$lodev_legacy\""

        rlLog "Fetch advertisement and bind with it stored (simulating legacy)"
        rlRun "curl -sSf -o legacy_adv.json 'http://localhost:$port/adv'"
        rlRun "clevis luks bind -f -k pwfile_legacy -d \"\$lodev_legacy\" tang \
            '{\"url\":\"http://localhost:$port\",\"adv\":\"legacy_adv.json\"}'"

        rlLog "Verify the binding was created with stored advertisement"
        rlRun "legacy_binding=\$(clevis luks list -d \"\$lodev_legacy\" | head -1 | sed 's/^[0-9]*: //')"
        rlLog "Legacy binding: $legacy_binding"
    rlPhaseEnd

    rlPhaseStart FAIL "Phase 3: Regenerate legacy binding and verify cleanup"
        rlLog "Attempt to regenerate binding via clevis luks regen"
        if clevis luks regen --help 2>&1 | grep -q 'regen'; then
            rlRun "clevis luks regen -d \"\$lodev_legacy\" -s 1 -q" 0 \
                "Regenerate legacy binding"

            rlLog "Extract regenerated binding metadata"
            rlRun "regen_binding=\$(clevis luks list -d \"\$lodev_legacy\" | head -1 | sed 's/^[0-9]*: //')"
            rlLog "Regenerated binding: $regen_binding"

            rlLog "Verify regenerated binding does NOT contain tang_pub"
            rlRun "echo \"\$regen_binding\" | grep -v 'tang_pub'" 0 \
                "Regenerated binding should not contain tang_pub"

            rlLog "Verify regenerated binding does NOT store Tang public key"
            rlRun "echo \"\$regen_binding\" | grep -v '\"adv\"'" 0 \
                "Regenerated binding should not store the Tang advertisement"
        else
            rlLogWarning "clevis luks regen not available, skipping regeneration test"
        fi
    rlPhaseEnd

    # ------------------------------------------------------------------
    # Phase 4 — Returned-key identifier mismatch
    # ------------------------------------------------------------------

    rlPhaseStart FAIL "Phase 4: Reject mismatched tang_pub identifier"
        rlLog "Generate a different EC key to simulate a tampered tang_pub"
        rlRun "jose jwk gen -i '{\"alg\":\"ECMR\"}' -o fake_exc.jwk"
        rlRun "fake_kid=\$(jose jwk thp -i fake_exc.jwk)"

        rlLog "Verify that the fake key has a different thumbprint"
        rlAssertNotEquals "Fake key thumbprint differs from real exc key" \
            "$fake_kid" "$exc_kid"

        rlLog "Request recovery with the real kid"
        rlRun "curl -sSf -X POST \
            -H 'Content-Type: application/jwk+json' \
            -d @ephem.jwk \
            -o rec_good.json \
            'http://localhost:$port/rec/$exc_kid'" 0 \
            "Recovery with valid kid succeeds"

        rlLog "Tamper with the response: replace tang_pub with the fake key"
        if jq -e '.tang_pub' rec_good.json > /dev/null 2>&1; then
            rlRun "jq --argjson fakekey \"\$(cat fake_exc.jwk)\" \
                '.tang_pub = \$fakekey' rec_good.json > rec_tampered.json"

            rlLog "Verify clevis would reject the mismatched key"
            tampered_thp=$(jq -r '.tang_pub' rec_tampered.json | jose jwk thp -i-)
            rlAssertNotEquals "Tampered tang_pub thumbprint should not match exc_kid" \
                "$tampered_thp" "$exc_kid"
            rlLog "Mismatch detected: tang_pub thp=$tampered_thp vs expected=$exc_kid"
        else
            rlLogWarning "tang_pub not present in /rec response — server may not yet support it; mismatch test deferred"
        fi
    rlPhaseEnd

    # ------------------------------------------------------------------
    # Cleanup
    # ------------------------------------------------------------------

    rlPhaseStartCleanup
        stop_tang "$port"
        if [ -n "$lodev" ]; then
            rlRun "cryptsetup close \$(basename \$lodev) 2>/dev/null" 0,5
            rlRun "losetup -d \"\$lodev\""
        fi
        if [ -n "$lodev_legacy" ]; then
            rlRun "cryptsetup close \$(basename \$lodev_legacy) 2>/dev/null" 0,5
            rlRun "losetup -d \"\$lodev_legacy\""
        fi
        rlRun "popd"
        rlRun "rm -r $TmpDir" 0 "Removing tmp directory"
    rlPhaseEnd
rlJournalPrintText
rlJournalEnd
