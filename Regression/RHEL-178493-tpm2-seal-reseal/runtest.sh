#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/clevis/Regression/RHEL-178493-tpm2-seal-reseal
#   Description: Test for RHEL-178493 - TPM2 seal and reseal functionality
#   Author: QE Automation <sec-eng-special@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Include Beaker environment
. /usr/bin/rhts-environment.sh || :
. /usr/share/beakerlib/beakerlib.sh || exit 1

PACKAGE="clevis"
PACKAGES="${PACKAGE} ${PACKAGE}-luks ${PACKAGE}-pin-tpm2 tpm2-tools cryptsetup"

rlJournalStart
    rlPhaseStartSetup "Setup test environment and loopback LUKS volume"
        rlAssertRpm "clevis"
        rlAssertRpm "clevis-luks"
        rlAssertRpm "clevis-pin-tpm2"
        rlAssertRpm "tpm2-tools"
        rlAssertRpm "cryptsetup"

        rlRun "TmpDir=\$(mktemp -d)" 0 "Creating tmp directory"
        rlRun "pushd ${TmpDir}"

        # Create 100M backing file and attach to loop device
        rlRun "dd if=/dev/zero of=loopfile bs=1M count=100" 0 "Create zero file for loop device"
        rlRun "luks_dev=\$(losetup -f --show loopfile)" 0 "Attach loop device"

        # Format LUKS2 volume
        rlRun "pass=redhat123"
        rlRun "cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --batch-mode --force-password ${luks_dev} <<< ${pass}" 0 "Format LUKS2 volume"
    rlPhaseEnd

    rlPhaseStartTest "Test TPM2 binding with default PCRs (PCR 7)"
        rlRun "slot=1"
        cfg='{"pcr_ids":"7"}'
        rlRun "clevis luks bind -y -d ${luks_dev} -s ${slot} tpm2 '${cfg}' <<< ${pass}" 0 "Bind LUKS slot with TPM2 PCR 7"
        rlRun "clevis luks list -d ${luks_dev}" 0 "List bound LUKS slots"
        rlRun "clevis luks unlock -d ${luks_dev}" 0 "Unlock LUKS volume using TPM2"
        rlRun "find /dev/mapper -name 'luks*' -exec cryptsetup close {} +" 0 "Close mapped LUKS volume"
    rlPhaseEnd

    rlPhaseStartTest "Test PCR policy updates and resealing (clevis luks edit / bind)"
        # Update PCR binding configuration to include PCR 1 and 7 (simulating reseal after PCR change)
        cfg_new='{"pcr_ids":"1,7"}'
        rlRun "clevis luks edit -d ${luks_dev} -s ${slot} -c '${cfg_new}'" 0 "Reseal / edit TPM2 PCR binding policy"
        rlRun "clevis luks list -d ${luks_dev}" 0 "Verify updated LUKS slot configuration"
        rlRun "clevis luks unlock -d ${luks_dev}" 0 "Unlock LUKS volume with updated TPM2 PCR policy"
        rlRun "find /dev/mapper -name 'luks*' -exec cryptsetup close {} +" 0 "Close mapped LUKS volume"

        # Test unbinding slot
        rlRun "clevis luks unbind -f -d ${luks_dev} -s ${slot}" 0 "Unbind TPM2 slot"
    rlPhaseEnd

    rlPhaseStartCleanup "Clean up temporary files and loop device"
        rlRun "find /dev/mapper -name 'luks*' -exec cryptsetup close {} +"
        if [ -n "${luks_dev}" ]; then
            rlRun "losetup -d ${luks_dev}"
        fi
        rlRun "popd"
        rlRun "rm -rf ${TmpDir}" 0 "Removing tmp directory"
    rlPhaseEnd
rlJournalPrintText
rlJournalEnd
