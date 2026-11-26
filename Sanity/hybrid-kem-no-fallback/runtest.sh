#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/clevis/Sanity/hybrid-kem-no-fallback
#   Description: verifies the hybrid tang-pqc binding policy and rejects
#                fallback to the classical-only recovery path.
#   Author: Patrik Koncity <pkoncity@redhat.com>
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

KEM_ALG="ML-KEM-768"
# Passphrase shared by all temporary LUKS2 images; written to a key file once
# so luksFormat and "clevis luks bind -k" always use identical key bytes.
LUKS_PASSPHRASE="pqc-test-passphrase"
TMP_DIR=""
TANG_DB=""
TANG_PORT=""
TANG_URL=""
MAPPER_PREFIX="clevis-t3-3-$$"
CLEANUP_DONE=0

cleanup() {
    local exit_status=$?
    [[ "${CLEANUP_DONE}" == "1" ]] && return "${exit_status}"
    CLEANUP_DONE=1

    for mapper in policy proxy-check rec-kem atomic version; do
        mapper="${MAPPER_PREFIX}-${mapper}"
        cryptsetup close "${mapper}" 2>/dev/null || :
    done

    if [[ -n "${TANG_PORT}" ]]; then
        stop_tang_http "${TANG_PORT}" 2>/dev/null || :
        TANG_PORT=""
    fi

    stop_tang_fault_proxy 2>/dev/null || :

    if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
        rm -rf "${TMP_DIR}"
        TMP_DIR=""
    fi
    return "${exit_status}"
}
trap cleanup EXIT

rlJournalStart
    rlPhaseStartSetup
        rlRun ". ../../TestHelpers/utils.sh" 0 "Load shared Tang helpers"
        for command in clevis clevis-luks-bind clevis-encrypt-tang-pqc clevis-decrypt jose curl jq python3 cryptsetup socat fuser; do
            if ! command -v "${command}" >/dev/null 2>&1; then
                rlDie "Required T3.3 command '${command}' is missing; install the production Clevis PQC package and test dependencies"
            fi
        done
        for package in clevis clevis-luks clevis-pin-tang-pqc tang jose; do
            rlLogInfo "$(rpm -q --qf '%{NAME}-%{VERSION}-%{RELEASE} built %{BUILDTIME:date}\n' "${package}" 2>&1)"
        done

        TMP_DIR="$(mktemp -d)" || rlDie "Could not create temporary directory"
        TANG_DB="${TMP_DIR}/tang/db"
        rlRun "mkdir -p '${TANG_DB}'" 0 "Create temporary Tang key database"
        printf '%s\n' "${LUKS_PASSPHRASE}" > "${TMP_DIR}/luks.pass"

        # Shared helper from TestHelpers/utils.sh: generates the sig and exc
        # keys through jose plus the ML-KEM-768 key; --require-kem fails the
        # test when the installed jose cannot provide hybrid keys.
        gen_tang_keys --require-kem "${TANG_DB}" || rlDie "Hybrid T3.3 requires a jose build with ML-KEM-768 support"
        # Called directly (not in a command substitution) so the PID
        # bookkeeping in stop_tang_http keeps working; the port also lands
        # in the global TANG_HTTP_PORT.
        start_tang_http "${TANG_DB}" "" "${TMP_DIR}/tang.log" || rlDie "Temporary Tang server did not start"
        TANG_PORT="${TANG_HTTP_PORT}"
        TANG_URL="http://localhost:${TANG_PORT}"

        VERSION="$(curl -fsS "${TANG_URL}/version")" || rlDie "Local Tang /version endpoint is unavailable"
        if [[ "$(jq -r '.features.hybrid_recovery // false' <<< "${VERSION}")" != "true" ]]; then
            rlDie "Local Tang does not report hybrid recovery support"
        fi

        ADV_KEM="$(curl -fsS "${TANG_URL}/adv-kem?alg=${KEM_ALG}")" || rlDie "Local Tang does not advertise ${KEM_ALG}"
        KEM_PAYLOAD="$(jose fmt -j- -Og payload -Su- <<< "${ADV_KEM}" | jose b64 dec -i- 2>/dev/null)" || rlDie "Could not decode Tang's KEM advertisement"
        if ! jq -e --arg alg "${KEM_ALG}" 'any(.keys[]?; .kty == "AKP" and .alg == $alg)' <<< "${KEM_PAYLOAD}" >/dev/null; then
            rlDie "Tang does not advertise the required ${KEM_ALG} key"
        fi

        start_tang_fault_proxy "${TANG_URL}" || rlDie "Tang fault proxy did not start"
        rlLogInfo "Started local Tang at ${TANG_URL} and the fault proxy at ${TANG_PROXY_URL}"
        PQC_CONFIG="$(printf '{"url":"%s","alg":"%s"}' "${TANG_URL}" "${KEM_ALG}")"
        PROXY_PQC_CONFIG="$(printf '{"url":"%s","alg":"%s"}' "${TANG_PROXY_URL}" "${KEM_ALG}")"
        CLASSICAL_CONFIG="$(printf '{"url":"%s"}' "${TANG_URL}")"
    rlPhaseEnd

    rlPhaseStartTest "Provisioning policy selects hybrid mode"
        HYBRID_DEVICE="${TMP_DIR}/hybrid-luks.img"
        rlRun "dd if=/dev/zero of='${HYBRID_DEVICE}' bs=1M count=32 status=none" 0 "Create a temporary LUKS2 image"
        rlRun "cryptsetup luksFormat --type luks2 --batch-mode --key-file '${TMP_DIR}/luks.pass' '${HYBRID_DEVICE}'" 0 "Format temporary LUKS2 image"

        # Do not abort the test on failure here: the remaining phases and the
        # cleanup phase must still run, so skip only the steps that need the
        # binding.
        if clevis luks bind -y -f -k "${TMP_DIR}/luks.pass" -d "${HYBRID_DEVICE}" tang-pqc "${PQC_CONFIG}" > "${TMP_DIR}/hybrid-bind.out" 2>&1; then
            rlPass "Bound LUKS2 with the hybrid tang-pqc pin"
            rlRun "clevis luks list -d '${HYBRID_DEVICE}' > '${TMP_DIR}/hybrid-list.txt'" 0 "List hybrid LUKS binding"
            rlRun "grep -Eq '^[[:space:]]*[0-9]+:[[:space:]]+tang-pqc([[:space:]]|$)' '${TMP_DIR}/hybrid-list.txt'" 0 "LUKS token records the tang-pqc pin"

            # The pin name alone does not prove the stored policy is hybrid: a
            # classical-only policy labeled tang-pqc would pass the listing check
            # above. Assert the stored JWE header carries the KEM algorithm and
            # both recovery key ids.
            rlRun "save_clevis_jwe '${HYBRID_DEVICE}' '${TMP_DIR}/hybrid-token.jwe'" 0 "Extract the hybrid binding JWE"
            rlRun "save_jwe_header '${TMP_DIR}/hybrid-token.jwe' '${TMP_DIR}/hybrid-header.json'" 0 "Decode the hybrid binding header"
            rlAssertEquals "Stored policy selects the hybrid KEM algorithm" "${KEM_ALG}" "$(jq -r '.clevis."tang-pqc".alg // empty' < "${TMP_DIR}/hybrid-header.json")"
            rlAssertEquals "Stored binding carries ECMR (kid) and KEM (kem_kid) material" "true" "$(jq -r '.kid and .kem_kid' < "${TMP_DIR}/hybrid-header.json")"

            if clevis luks unlock -d "${HYBRID_DEVICE}" -n "${MAPPER_PREFIX}-policy" > "${TMP_DIR}/hybrid-unlock.out" 2>&1; then
                rlPass "Hybrid LUKS2 unlock succeeded against local Tang"
                rlRun "cryptsetup close '${MAPPER_PREFIX}-policy'" 0 "Close temporary mapper"
            else
                rlFail "Hybrid LUKS2 unlock failed against local Tang"
                rlLogInfo "Unlock output: $(<"${TMP_DIR}/hybrid-unlock.out")"
                rlLogInfo "Tang output: $(<"${TMP_DIR}/tang.log")"
            fi
        else
            rlFail "Hybrid tang-pqc binding failed"
            rlLogInfo "Bind output: $(<"${TMP_DIR}/hybrid-bind.out")"
        fi
    rlPhaseEnd

    rlPhaseStartTest "Hybrid recovery does not fall back to EC-only"
        NO_FALLBACK_DEVICE="${TMP_DIR}/no-fallback-luks.img"
        rlRun "dd if=/dev/zero of='${NO_FALLBACK_DEVICE}' bs=1M count=32 status=none" 0 "Create no-fallback LUKS2 image"
        rlRun "cryptsetup luksFormat --type luks2 --batch-mode --key-file '${TMP_DIR}/luks.pass' '${NO_FALLBACK_DEVICE}'" 0 "Format no-fallback LUKS2 image"
        printf 'passthrough\n' > "${TANG_PROXY_MODE_FILE}"
        : > "${TANG_PROXY_EVENTS}"
        # The /rec-kem block below only proves "no fallback" when the binding
        # and the passthrough unlock both work, so guard them instead of
        # aborting with rlDie: the remaining phases must still run.
        if clevis luks bind -y -f -k "${TMP_DIR}/luks.pass" -d "${NO_FALLBACK_DEVICE}" tang-pqc "${PROXY_PQC_CONFIG}" > "${TMP_DIR}/no-fallback-bind.out" 2>&1; then
            if clevis luks unlock -d "${NO_FALLBACK_DEVICE}" -n "${MAPPER_PREFIX}-proxy-check" > "${TMP_DIR}/proxy-unlock.out" 2>&1; then
                rlPass "Hybrid unlock succeeded through the passthrough proxy"
                rlRun "cryptsetup close '${MAPPER_PREFIX}-proxy-check'" 0 "Close passthrough verification mapper"
                rlRun "grep -Eq '(^|[[:space:]])/rec/' '${TANG_PROXY_EVENTS}'" 0 "Passthrough unlock used classical recovery"
                rlRun "grep -Eq '(^|[[:space:]])/rec-kem/' '${TANG_PROXY_EVENTS}'" 0 "Passthrough unlock used KEM recovery"

                printf 'block-rec-kem\n' > "${TANG_PROXY_MODE_FILE}"
                : > "${TANG_PROXY_EVENTS}"
                if clevis luks unlock -d "${NO_FALLBACK_DEVICE}" -n "${MAPPER_PREFIX}-rec-kem" > "${TMP_DIR}/rec-kem-failure.out" 2>&1; then
                    rlFail "Hybrid unlock succeeded while /rec-kem was unavailable"
                    cryptsetup close "${MAPPER_PREFIX}-rec-kem" 2>/dev/null || :
                else
                    rlPass "Hybrid unlock failed when /rec-kem was unavailable"
                    rlLogInfo "Expected unlock error: $(<"${TMP_DIR}/rec-kem-failure.out")"
                fi
                if cryptsetup status "${MAPPER_PREFIX}-rec-kem" >/dev/null 2>&1; then
                    cryptsetup close "${MAPPER_PREFIX}-rec-kem" 2>/dev/null || :
                    rlFail "Failed hybrid unlock left an active device mapping"
                fi
                rlRun "grep -Eq '(^|[[:space:]])/rec/' '${TANG_PROXY_EVENTS}'" 0 "Classical recovery endpoint was available"
                rlRun "grep -Eq '(^|[[:space:]])/rec-kem/' '${TANG_PROXY_EVENTS}'" 0 "Hybrid recovery attempted /rec-kem"
            else
                rlFail "Hybrid unlock failed through the passthrough proxy"
                rlLogInfo "Unlock output: $(<"${TMP_DIR}/proxy-unlock.out")"
            fi
        else
            rlFail "Could not create hybrid binding for the no-fallback check"
            rlLogInfo "Bind output: $(<"${TMP_DIR}/no-fallback-bind.out")"
        fi

        printf '%s' 'classical control' | clevis encrypt tang "${CLASSICAL_CONFIG}" -y > "${TMP_DIR}/classical-control.jwe"
        rlAssertEquals "Classical control JWE was produced" "0" "$?"
        rlRun "clevis decrypt < '${TMP_DIR}/classical-control.jwe' > '${TMP_DIR}/classical-control.plain'" 0 "Classical Tang control still decrypts"
        rlAssertEquals "Classical control plaintext" "classical control" "$(<"${TMP_DIR}/classical-control.plain")"
    rlPhaseEnd

    rlPhaseStartTest "Failed hybrid provisioning leaves no state"
        ATOMIC_DEVICE="${TMP_DIR}/atomic-luks.img"
        rlRun "dd if=/dev/zero of='${ATOMIC_DEVICE}' bs=1M count=32 status=none" 0 "Create atomicity-check LUKS2 image"
        rlRun "cryptsetup luksFormat --type luks2 --batch-mode --key-file '${TMP_DIR}/luks.pass' '${ATOMIC_DEVICE}'" 0 "Format atomicity-check LUKS2 image"
        rlRun "cryptsetup luksHeaderBackup '${ATOMIC_DEVICE}' --header-backup-file '${TMP_DIR}/atomic-before.bin'" 0 "Back up LUKS header before failed provisioning"

        printf 'block-adv-kem\n' > "${TANG_PROXY_MODE_FILE}"
        : > "${TANG_PROXY_EVENTS}"
        if clevis luks bind -y -f -k "${TMP_DIR}/luks.pass" -d "${ATOMIC_DEVICE}" tang-pqc "${PROXY_PQC_CONFIG}" > "${TMP_DIR}/atomic-bind.out" 2>&1; then
            rlFail "Hybrid provisioning unexpectedly succeeded without a KEM advertisement"
        else
            rlPass "Hybrid provisioning failed when the KEM advertisement was unavailable"
        fi
        rlLogInfo "Atomic bind output: $(<"${TMP_DIR}/atomic-bind.out")"
        rlRun "grep -Eq '(^|[[:space:]])/adv-kem([?[:space:]/]|$)' '${TANG_PROXY_EVENTS}'" 0 "Provisioning attempted to fetch the KEM advertisement"
        rlRun "cryptsetup luksHeaderBackup '${ATOMIC_DEVICE}' --header-backup-file '${TMP_DIR}/atomic-after.bin'" 0 "Back up LUKS header after failed provisioning"
        if cmp -s "${TMP_DIR}/atomic-before.bin" "${TMP_DIR}/atomic-after.bin"; then
            rlPass "LUKS header is unchanged"
        else
            rlFail "LUKS header changed after failed hybrid provisioning"
        fi
        TOKEN_COUNT="$(cryptsetup luksDump --dump-json-metadata "${ATOMIC_DEVICE}" | jq '[.tokens // {} | to_entries[] | select(.value.type == "clevis")] | length')"
        rlAssertEquals "No Clevis token remains after failed provisioning" "0" "${TOKEN_COUNT}"
    rlPhaseEnd

    rlPhaseStartTest "/version tampering never downgrades hybrid provisioning"
        VERSION_DEVICE="${TMP_DIR}/version-luks.img"
        rlRun "dd if=/dev/zero of='${VERSION_DEVICE}' bs=1M count=32 status=none" 0 "Create version-check LUKS2 image"
        rlRun "cryptsetup luksFormat --type luks2 --batch-mode --key-file '${TMP_DIR}/luks.pass' '${VERSION_DEVICE}'" 0 "Format version-check LUKS2 image"
        rlRun "cryptsetup luksHeaderBackup '${VERSION_DEVICE}' --header-backup-file '${TMP_DIR}/version-before.bin'" 0 "Back up LUKS header before version tampering"

        printf 'tamper-version\n' > "${TANG_PROXY_MODE_FILE}"
        : > "${TANG_PROXY_EVENTS}"
        if TAMPERED_VERSION="$(curl -fsS "${TANG_PROXY_URL}/version")"; then
            rlAssertEquals "Proxy changed only the hybrid capability" "false" "$(jq -r '.features.hybrid_recovery' <<< "${TAMPERED_VERSION}")"

            if clevis luks bind -y -f -k "${TMP_DIR}/luks.pass" -d "${VERSION_DEVICE}" tang-pqc "${PROXY_PQC_CONFIG}" > "${TMP_DIR}/version-bind.out" 2>&1; then
                rlRun "clevis luks list -d '${VERSION_DEVICE}' > '${TMP_DIR}/version-list.txt'" 0 "List binding after tampered version response"
                rlRun "grep -Eq '^[[:space:]]*[0-9]+:[[:space:]]+tang-pqc([[:space:]]|$)' '${TMP_DIR}/version-list.txt'" 0 "A successful policy bind remains hybrid"
                if grep -Eq '^[[:space:]]*[0-9]+:[[:space:]]+tang([[:space:]]|$)' "${TMP_DIR}/version-list.txt"; then
                    rlFail "Tampered /version caused a classical Tang fallback"
                fi
                # A bind that survives the tampered /version must still carry the
                # full hybrid policy, not merely the tang-pqc label.
                rlRun "save_clevis_jwe '${VERSION_DEVICE}' '${TMP_DIR}/version-token.jwe'" 0 "Extract the tampered-version binding JWE"
                rlRun "save_jwe_header '${TMP_DIR}/version-token.jwe' '${TMP_DIR}/version-header.json'" 0 "Decode the tampered-version binding header"
                rlAssertEquals "Tampered-version binding keeps the hybrid KEM algorithm" "${KEM_ALG}" "$(jq -r '.clevis."tang-pqc".alg // empty' < "${TMP_DIR}/version-header.json")"
                rlAssertEquals "Tampered-version binding carries ECMR (kid) and KEM (kem_kid) material" "true" "$(jq -r '.kid and .kem_kid' < "${TMP_DIR}/version-header.json")"
                : > "${TANG_PROXY_EVENTS}"
                rlRun "clevis luks unlock -d '${VERSION_DEVICE}' -n '${MAPPER_PREFIX}-version'" 0 "Unlock the binding created with tampered /version"
                rlRun "cryptsetup close '${MAPPER_PREFIX}-version'" 0 "Close version-check mapper"
                rlRun "grep -Eq '(^|[[:space:]])/rec/' '${TANG_PROXY_EVENTS}'" 0 "Tampered-version binding used classical recovery"
                rlRun "grep -Eq '(^|[[:space:]])/rec-kem/' '${TANG_PROXY_EVENTS}'" 0 "Tampered-version binding used KEM recovery"
            else
                if ! grep -qi 'does not support hybrid PQC' "${TMP_DIR}/version-bind.out"; then
                    rlFail "Hybrid bind failed for a reason other than the tampered capability response"
                else
                    rlPass "Tampered /version caused a fail-closed hybrid bind"
                fi
                rlRun "cryptsetup luksHeaderBackup '${VERSION_DEVICE}' --header-backup-file '${TMP_DIR}/version-after.bin'" 0 "Back up LUKS header after rejected bind"
                if cmp -s "${TMP_DIR}/version-before.bin" "${TMP_DIR}/version-after.bin"; then
                    rlPass "LUKS header is unchanged after tampered /version"
                else
                    rlFail "LUKS header changed after tampered /version"
                fi
                TOKEN_COUNT="$(cryptsetup luksDump --dump-json-metadata "${VERSION_DEVICE}" | jq '[.tokens // {} | to_entries[] | select(.value.type == "clevis")] | length')"
                rlAssertEquals "Rejected bind left no Clevis token" "0" "${TOKEN_COUNT}"
            fi
        else
            rlFail "Could not query the version-tampering proxy"
            rlLogInfo "Proxy log: $(<"${TANG_PROXY_DIR}/proxy.log")"
        fi
    rlPhaseEnd

    rlPhaseStartCleanup
        cleanup
        rlLogInfo "Stopped the local fault-injection proxy and removed temporary LUKS images"
    rlPhaseEnd
rlJournalPrintText
rlJournalEnd
