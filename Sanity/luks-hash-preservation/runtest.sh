#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/clevis/Sanity/luks-hash-preservation
#   Description: Verify that clevis operations (bind, regen, edit)
#                preserve the hash algorithm of LUKS devices formatted
#                with a non-default hash (sha512).
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2026 Red Hat, Inc.
#
#   This program is free software: you can redistribute it and/or
#   modify it under the terms of the GNU General Public License as
#   published by the Free Software Foundation, either version 2 of
#   the License, or (at your option) any later version.
#
#   This program is distributed in the hope that it will be
#   useful, but WITHOUT ANY WARRANTY; without even the implied
#   warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
#   PURPOSE.  See the GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program. If not, see http://www.gnu.org/licenses/.
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Include Beaker environment
. /usr/bin/rhts-environment.sh || :
. /usr/share/beakerlib/beakerlib.sh || exit 1

PACKAGE="clevis"
PACKAGES="${PACKAGE} ${PACKAGE}-luks tang cryptsetup"

PASS="redhat123"
HASH="sha512"

# Get hash algorithm from LUKS1 header (single global hash).
get_luks1_hash() {
    cryptsetup luksDump "$1" | sed -rn 's|^Hash spec:\s+(\S+)$|\1|p'
}

# Get hash algorithm for a specific LUKS2 keyslot.
get_luks2_slot_hash() {
    local dev="$1" slot="$2"
    cryptsetup luksDump "$dev" \
        | awk "/^[[:space:]]+${slot}: luks/{found=1} found && /Hash:/{print \$2; exit}"
}

rlJournalStart
    rlPhaseStartSetup
        rlRun "rpm -q clevis || which clevis" 0 "Checking for the presence of clevis rpm"
        rlRun "TmpDir=\$(mktemp -d)" 0 "Creating tmp directory"
        rlRun "pushd $TmpDir"

        rlRun "rlServiceStart tangd.socket"
        rlRun "sleep 1"
    rlPhaseEnd

    for luksVersion in luks1 luks2; do

        rlPhaseStartTest "Bind preserves hash - ${luksVersion}"
            rlRun "dd if=/dev/zero of=bind-${luksVersion} bs=1M count=64"
            rlRun "dev=\$(losetup -f --show bind-${luksVersion})" 0 "Create loop device"
            rlRun "cryptsetup luksFormat --type ${luksVersion} --hash ${HASH} \
                --pbkdf pbkdf2 --pbkdf-force-iterations 1000 \
                --batch-mode --force-password ${dev} <<< ${PASS}"

            if [ "${luksVersion}" = "luks1" ]; then
                hash_before=$(get_luks1_hash "${dev}")
            else
                hash_before=$(get_luks2_slot_hash "${dev}" 0)
            fi
            rlAssertEquals "Hash before bind is ${HASH}" "${hash_before}" "${HASH}"

            rlRun "clevis luks bind -y -d ${dev} tang '{\"url\":\"http://localhost\"}' <<< ${PASS}" 0 "Bind device"

            if [ "${luksVersion}" = "luks1" ]; then
                hash_after=$(get_luks1_hash "${dev}")
            else
                hash_after=$(get_luks2_slot_hash "${dev}" 1)
            fi
            rlAssertEquals "Hash after bind is ${HASH}" "${hash_after}" "${HASH}"

            rlRun "losetup -d ${dev}" 0 "Destroy loop device"
        rlPhaseEnd

        rlPhaseStartTest "Regen preserves hash - ${luksVersion}"
            rlRun "dd if=/dev/zero of=regen-${luksVersion} bs=1M count=64"
            rlRun "dev=\$(losetup -f --show regen-${luksVersion})" 0 "Create loop device"
            rlRun "cryptsetup luksFormat --type ${luksVersion} --hash ${HASH} \
                --pbkdf pbkdf2 --pbkdf-force-iterations 1000 \
                --batch-mode --force-password ${dev} <<< ${PASS}"

            rlRun "clevis luks bind -y -d ${dev} tang '{\"url\":\"http://localhost\"}' <<< ${PASS}" 0 "Bind device"
            rlRun "cryptsetup luksRemoveKey --batch-mode ${dev} <<< ${PASS}" 0 "Remove initial passphrase"
            rlRun "clevis luks regen -q -d ${dev} -s 1" 0 "Regen slot 1"

            if [ "${luksVersion}" = "luks1" ]; then
                hash_after=$(get_luks1_hash "${dev}")
            else
                hash_after=$(get_luks2_slot_hash "${dev}" 1)
            fi
            rlAssertEquals "Hash after regen is ${HASH}" "${hash_after}" "${HASH}"

            rlRun "losetup -d ${dev}" 0 "Destroy loop device"
        rlPhaseEnd

        rlPhaseStartTest "Edit preserves hash - ${luksVersion}"
            rlRun "dd if=/dev/zero of=edit-${luksVersion} bs=1M count=64"
            rlRun "dev=\$(losetup -f --show edit-${luksVersion})" 0 "Create loop device"
            rlRun "cryptsetup luksFormat --type ${luksVersion} --hash ${HASH} \
                --pbkdf pbkdf2 --pbkdf-force-iterations 1000 \
                --batch-mode --force-password ${dev} <<< ${PASS}"

            rlRun "clevis luks bind -y -d ${dev} tang '{\"url\":\"localhost\"}' <<< ${PASS}" 0 "Bind device"

            if [ "${luksVersion}" = "luks1" ]; then
                hash_before=$(get_luks1_hash "${dev}")
            else
                hash_before=$(get_luks2_slot_hash "${dev}" 1)
            fi
            rlAssertEquals "Hash after bind is ${HASH}" "${hash_before}" "${HASH}"

            rlRun "clevis luks edit -d ${dev} -s 1 -c '{\"url\":\"http://localhost\"}'" 0 "Edit clevis binding"

            if [ "${luksVersion}" = "luks1" ]; then
                hash_after=$(get_luks1_hash "${dev}")
            else
                hash_after=$(get_luks2_slot_hash "${dev}" 1)
            fi
            rlAssertEquals "Hash after edit is ${HASH}" "${hash_after}" "${HASH}"

            rlRun "clevis luks unlock -d ${dev} -n test-edit-${luksVersion}" 0 "Unlock after edit"
            rlRun "cryptsetup close test-edit-${luksVersion}" 0 "Close unlocked device"

            rlRun "losetup -d ${dev}" 0 "Destroy loop device"
        rlPhaseEnd

    done

    rlPhaseStartCleanup
        rlRun "rlServiceRestore tangd.socket"
        rlRun "popd"
        rlRun "rm -r $TmpDir" 0 "Removing tmp directory"
    rlPhaseEnd
rlJournalPrintText
rlJournalEnd
