#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/clevis/Sanity/tang-pub-binding
#   Description: Verify tang_pub in /rec response and binding storage
#                semantics
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

. /usr/share/beakerlib/beakerlib.sh || exit 1

# tangd startup/shutdown (start_tang_http/stop_tang_http), the fault
# injection proxy (start_tang_fault_proxy/stop_tang_fault_proxy), key
# generation (gen_tang_keys/gen_tang_cache) and the JWE inspection helpers
# (save_clevis_jwe/save_jwe_header) all come from TestHelpers/utils.sh,
# sourced in Setup below. The shared gen_tang_keys also generates kem.jwk
# when the jose build supports ML-KEM-768 — harmless here (the
# advertisement just carries an extra AKP key) and closer to a real PQC
# deployment.

# NOTE: covers EC ("d") and oct ("k") private members. If this helper is
# ever reused for AKP (ML-KEM) keys, check the AKP private member name as
# well — it may differ from "d".
jwk_is_public_only() {
    local jwk="$1"
    rlRun "jq -e '.d // .priv // .k' \"$jwk\" >/dev/null 2>&1" 1 \
        "JWK should not contain private members (d, priv, k)"
}

PACKAGE="clevis"
SKIP_TEST=false

rlJournalStart
    rlPhaseStartSetup
        rlRun "rpm -q $PACKAGE || which clevis" 0 "Checking for the presence of clevis rpm"
        rlRun ". ../../TestHelpers/utils.sh" || rlDie "cannot import function script"
        rlRun "TmpDir=\$(mktemp -d)" 0 "Creating tmp directory" || rlDie "mktemp failed"
        rlRun "pushd $TmpDir" || rlDie "cannot enter $TmpDir"
        # Public-only attacker key injected by the tamper-tang-pub proxy mode.
        FAKE_KEY_FILE="${TmpDir}/fake_pub.jwk"
    rlPhaseEnd

    rlPhaseStartTest "tangd setup"
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
        rlRun "start_tang_http \"\$tang_dir\"" 0 "Start local tangd"
        port="$TANG_HTTP_PORT"
        rlRun "start_tang_fault_proxy \"http://localhost:\$port\" \"\$FAKE_KEY_FILE\"" 0 \
            "Start the tang fault-injection proxy"
    rlPhaseEnd

    rlPhaseStartTest "Capability check: tang returns tang_pub in /rec"
        rlRun "exc_kid=\$(jose jwk thp -i tangd/db/exc.jwk)"
        rlRun "jose jwk gen -i '{\"alg\":\"ECMR\"}' -o probe_ephem.jwk"
        if curl -sSf -X POST -H 'Content-Type: application/jwk+json' \
               -d @probe_ephem.jwk -o probe_rec.json \
               "http://localhost:$port/rec/$exc_kid" 2>/dev/null \
            && jq -e '(.tang_pub | type) == "object"' probe_rec.json >/dev/null 2>&1; then
            rlPass "tang build returns tang_pub in /rec responses"
        else
            rlLogWarning "tang build does not return tang_pub in /rec responses"
            rlLogWarning "this test requires a tang build with tang_pub support; skipping"
            SKIP_TEST=true
        fi
    rlPhaseEnd

    if [ "$SKIP_TEST" != true ]; then

    # ------------------------------------------------------------------
    # Phase 1 — /rec/$kid includes tang_pub
    # ------------------------------------------------------------------

    rlPhaseStartTest "Phase 1: Fetch advertisement and extract ECMR exchange key"
        rlRun "curl -sSf -o adv.json 'http://localhost:$port/adv'"
        rlRun "jq . adv.json" 0 "Advertisement is valid JSON"

        rlLog "Extract the ECMR exchange key from the advertisement"
        rlRun "jq -e '.payload' adv.json > /dev/null" 0 "Advertisement has payload"
        rlRun "jose b64 dec -i <(jq -r '.payload' adv.json) -O adv_payload.json"
        rlRun "jq -e '.keys' adv_payload.json > /dev/null" 0 "Payload has keys array"

        rlLog "Find the EC exchange key in the advertisement and compare it to the on-disk key"
        rlRun "adv_exc_jwk=\$(jq -e \
            '.keys[] | select(.kty == \"EC\" and (.key_ops[]? == \"deriveKey\"))' \
            adv_payload.json)" 0 "Found EC exchange key in advertisement"
        rlRun "adv_thp=\$(printf '%s' \"\$adv_exc_jwk\" | jose jwk thp -i-)" 0 "Advertised exchange key thumbprint computed"
        rlAssertEquals "Advertised ECMR key matches on-disk exc key" \
            "$adv_thp" "$exc_kid"
    rlPhaseEnd

    rlPhaseStartTest "Phase 1: Perform ECMR key recovery via /rec/\$kid"
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

    rlPhaseStartTest "Phase 1: Verify tang_pub in recovery response"
        rlLog "Check that tang_pub is present and is a JSON object"
        rlRun "jq -e 'if (.tang_pub | type) == \"object\" then .tang_pub else null end' \
            rec_response.json > tang_pub.jwk" 0 \
            "tang_pub field is present in /rec response"

        rlLog "Verify tang_pub is a valid JWK"
        rlRun "jq -e '.kty' tang_pub.jwk > /dev/null" 0 "tang_pub has kty field"

        rlLog "Verify tang_pub is public-only (no private components)"
        jwk_is_public_only tang_pub.jwk

        rlLog "Verify tang_pub matches the requested ECMR key identifier"
        rlRun "tang_pub_thp=\$(jose jwk thp -i tang_pub.jwk)"
        rlAssertEquals "tang_pub thumbprint matches exc key thumbprint" "$tang_pub_thp" "$exc_kid"
    rlPhaseEnd

    rlPhaseStartTest "Phase 1: Verify ECMR recovery result is preserved"
        rlLog "Compute expected recovery result independently"
        rlLog "The server performs ECMR: rec = exc_priv * ephem_pub"
        rlLog "We verify by completing the exchange: result = ephem_priv * rec"
        rlLog "This must equal exc_priv * ephem_priv * G (the shared point)"

        # jose jwk exc expects a plain JWK: strip the extra tang_pub member
        # first, mirroring what clevis-decrypt-tang itself does with the
        # /rec response.
        rlRun "jq 'del(.tang_pub)' rec_response.json > rec_ec.jwk"
        rlRun "resp_kty=\$(jq -r '.kty' rec_ec.jwk)"
        rlAssertEquals "Recovery response kty is EC (backward compatible)" "$resp_kty" "EC"

        rlLog "Complete the ECMR exchange locally to verify the server's result"
        rlRun "jose jwk exc -i ephem.jwk -I rec_ec.jwk -o local_shared.jwk" 0 "Local ECMR exchange with server recovery result succeeds"

        rlLog "Perform the same exchange using the original server key for comparison"
        rlRun "jose jwk exc -i ephem.jwk -I tangd/db/exc.jwk -o expected_shared.jwk" 0 "Direct ECMR exchange with server key succeeds"

        rlRun "local_thp=\$(jose jwk thp -i local_shared.jwk)"
        rlRun "expected_thp=\$(jose jwk thp -i expected_shared.jwk)"
        rlAssertEquals "ECMR recovery produces correct shared secret" "$local_thp" "$expected_thp"
    rlPhaseEnd

    # ------------------------------------------------------------------
    # Phase 2 — tang_pub not persisted in new bindings
    # ------------------------------------------------------------------

    # The LUKS device is created (and destroyed afterwards) by the shared
    # luks_setup()/luks_destroy() helpers from utils.sh. They open their own
    # phases, so they must be called at journal top level, never inside
    # another phase.
    luks_setup

    rlPhaseStartTest "Phase 2: New binding stores no advertisement and unlocks"
        rlRun "thp=\$(jose jwk thp -i tangd/db/sig.jwk)"

        rlLog "Bind LUKS device to Tang"
        rlRun "clevis luks bind -f -k pwfile -d \"\$lodev\" tang \
            '{\"url\":\"http://localhost:$port\",\"thp\":\"$thp\"}'"

        rlLog "Assert on the persisted JWE from the LUKS2 token metadata"
        rlRun "save_clevis_jwe \"\$lodev\" new_binding.jwe" 0 "Extract clevis JWE from LUKS2 token metadata"
        rlRun "save_jwe_header new_binding.jwe new_hdr.json" 0 "Decode new binding protected header"
        rlRun "jq -e '.clevis.tang.url != null' new_hdr.json" 0 "Binding config is present in the JWE header"
        rlRun "jq -e '.clevis.tang.adv == null' new_hdr.json" 0 "New binding does not store the Tang advertisement"
        rlRun "jq -e '.clevis.tang.tang_pub == null' new_hdr.json" 0 "New binding does not store tang_pub"
        rlRun "jq -e --arg kid \"\$exc_kid\" '.kid == \$kid' new_hdr.json" 0 "New binding pins the ECMR key thumbprint (kid)"

        rlLog "Functional verification: unlock through the tang_pub recovery path"
        MAPPER="tangpub-p2-$$"
        rlRun "clevis luks unlock -d \"\$lodev\" -n ${MAPPER}" 0 "LUKS unlock via tang_pub recovery path succeeds"
        rlRun "cryptsetup close ${MAPPER}" 0 "Close verification mapper"
    rlPhaseEnd

    luks_destroy

    # ------------------------------------------------------------------
    # Phase 3 — Legacy-format binding migration
    # ------------------------------------------------------------------

    luks_setup

    rlPhaseStartTest "Phase 3: Create a legacy-format binding with stored advertisement"
        # Pre-tang_pub clevis always stored the whole advertisement under
        # clevis.tang.adv in the JWE protected header. Current clevis still
        # produces exactly this format whenever the server does not report
        # tang_pub support via /version — so hiding /version behind the
        # proxy yields a genuine legacy-format binding without needing an
        # old clevis build.
        printf 'block-version\n' > "${TANG_PROXY_MODE_FILE}"
        rlRun "clevis luks bind -f -k pwfile -d \"\$lodev\" tang \
            '{\"url\":\"http://localhost:${TANG_PROXY_PORT}\",\"thp\":\"$thp\"}'"

        rlRun "save_clevis_jwe \"\$lodev\" legacy_binding.jwe" 0 "Extract legacy binding JWE from LUKS2 token metadata"
        rlRun "save_jwe_header legacy_binding.jwe legacy_hdr.json" 0 "Decode legacy binding protected header"
        rlRun "jq -e '.clevis.tang.adv != null' legacy_hdr.json" 0 "Legacy-format binding stores the Tang advertisement"
        rlRun "jq -j '.clevis.tang.adv' legacy_hdr.json > legacy_adv_keys.json"
        rlRun "jose jwk thp -i legacy_adv_keys.json -f \"\$exc_kid\"" 0 "Stored advertisement contains the ECMR key matching kid"
    rlPhaseEnd

    rlPhaseStartTest "Phase 3: Regenerate legacy binding and verify migration"
        # NOTE: the test strategy also expects clevis to *warn* about a
        # stored advertisement when reading a legacy binding. Current
        # clevis does not emit such a warning, so it is not asserted here;
        # the functional migration (regen drops the stored adv) is.
        printf 'passthrough\n' > "${TANG_PROXY_MODE_FILE}"
        rlRun "legacy_slot=\$(clevis luks list -d \"\$lodev\" \
            | head -1 | cut -d: -f1 | tr -d ' ')" 0 "Discover legacy binding slot"
        rlRun "clevis luks regen -d \"\$lodev\" -s \"\$legacy_slot\" -q" 0 \
            "Regenerate legacy binding against tang_pub-capable server"

        rlRun "save_clevis_jwe \"\$lodev\" regen_binding.jwe" 0 "Extract regenerated binding JWE from LUKS2 token metadata"
        rlRun "save_jwe_header regen_binding.jwe regen_hdr.json" 0 "Decode regenerated binding protected header"
        rlRun "jq -e '.clevis.tang.adv == null' regen_hdr.json" 0 "Regenerated binding no longer stores the advertisement"
        rlRun "jq -e '.clevis.tang.tang_pub == null' regen_hdr.json" 0 "Regenerated binding does not store tang_pub"

        rlLog "Functional verification: unlock the regenerated binding"
        MAPPER_LEGACY="tangpub-p3-$$"
        rlRun "clevis luks unlock -d \"\$lodev\" -n ${MAPPER_LEGACY}" 0 "Regenerated binding unlocks successfully"
        rlRun "cryptsetup close ${MAPPER_LEGACY}" 0 "Close legacy mapper"
    rlPhaseEnd

    luks_destroy

    # ------------------------------------------------------------------
    # Phase 4 — Returned-key identifier mismatch (clevis-driven)
    # ------------------------------------------------------------------

    rlPhaseStartTest "Phase 4: Mismatched tang_pub is never used by clevis"
        rlLog "Generate an attacker ECMR key (public-only, as a MITM would inject)"
        rlRun "jose jwk gen -i '{\"alg\":\"ECMR\"}' -o fake_exc.jwk"
        rlRun "jose jwk pub -i fake_exc.jwk -o ${FAKE_KEY_FILE}"
        rlRun "fake_kid=\$(jose jwk thp -i fake_exc.jwk)"
        rlAssertNotEquals "Attacker key thumbprint differs from real exc key" \
            "$fake_kid" "$exc_kid"

        rlLog "Encrypt through the proxy (passthrough), then tamper /rec responses"
        printf 'passthrough\n' > "${TANG_PROXY_MODE_FILE}"
        rlRun "echo 'phase4-secret' | clevis encrypt tang \
            '{\"url\":\"http://localhost:${TANG_PROXY_PORT}\",\"thp\":\"$thp\"}' > phase4.jwe"

        # Case A — /adv still reachable. clevis must discard the mismatched
        # tang_pub and take the exchange key from /adv by pinned-kid lookup.
        # Decryption succeeds, and the correct plaintext proves the attacker
        # key was not used: had clevis used it, the shared secret would
        # differ and the JWE AEAD authentication would fail.
        printf 'tamper-tang-pub\n' > "${TANG_PROXY_MODE_FILE}"
        rlRun "clevis decrypt < phase4.jwe > phase4.out" 0 \
            "Decrypt succeeds via /adv fallback despite tampered tang_pub"
        rlAssertEquals "Plaintext correct — attacker key was not used" \
            "$(cat phase4.out)" "phase4-secret"

        # Case B — /adv blocked too. No trusted source for the exchange key
        # remains, so clevis must refuse the mismatched tang_pub and fail
        # closed.
        printf 'tamper-tang-pub,block-adv\n' > "${TANG_PROXY_MODE_FILE}"
        rlRun "clevis decrypt < phase4.jwe" 1 \
            "Decrypt fails closed when tang_pub mismatches and /adv is unavailable"

        printf 'passthrough\n' > "${TANG_PROXY_MODE_FILE}"
    rlPhaseEnd

    fi

    # ------------------------------------------------------------------
    # Cleanup
    # ------------------------------------------------------------------

    rlPhaseStartCleanup
        stop_tang_fault_proxy
        if [ -n "$port" ]; then
            stop_tang_http "$port"
        fi
        if [ -n "${MAPPER}" ] && cryptsetup status "${MAPPER}" >/dev/null 2>&1; then
            rlRun "cryptsetup close ${MAPPER}" 0 "Closing mapper left open"
        fi
        if [ -n "${MAPPER_LEGACY}" ] && cryptsetup status "${MAPPER_LEGACY}" >/dev/null 2>&1; then
            rlRun "cryptsetup close ${MAPPER_LEGACY}" 0 "Closing legacy mapper left open"
        fi
        # Fallback only: luks_destroy already ran between phases; detach the
        # loop device if a phase crashed midway. Do not call luks_destroy
        # here — it opens its own phase, which cannot nest inside Cleanup.
        if [ -n "$lodev" ] && losetup -l -O NAME | grep -qx "$lodev"; then
            rlRun "losetup -d \"\$lodev\"" 0 "Detaching leftover loop device"
        fi
        rlRun "popd"
        rlRun "rm -r $TmpDir" 0 "Removing tmp directory"
    rlPhaseEnd
rlJournalPrintText
rlJournalEnd
