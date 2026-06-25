#!/bin/bash
. /usr/share/beakerlib/beakerlib.sh || exit 1

rlJournalStart
    rlPhaseStartSetup "Setup"
        rlRun "dnf install -y clevis clevis-luks cryptsetup tang jose-utils socat expect"
        # Source helper functions for tang server
        rlRun ". /usr/share/rhts-testing/tests/clevis-tests/TestHelpers/utils.sh || . ../../TestHelpers/utils.sh"

        rlRun "TmpDir=\$(mktemp -d)" 0 "Creating tmp directory"
        rlRun "pushd \$TmpDir"

        # Setup Tang server
        rlRun "mkdir -p tangd/db"
        gen_tang_keys "tangd/db"
        port=\$(start_tang "tangd/db")
        rlAssertGrep "A tang server is running on port" "lsof -i :\$port"

        # Setup LUKS device with sha512
        rlRun "dd if=/dev/zero of=loopfile bs=100M count=1"
        rlRun "lodev=\$(losetup -f --show loopfile)"
        echo -n "redhat123" > pwfile
        rlRun "cryptsetup luksFormat --hash sha512 --batch-mode --key-file pwfile \"\$lodev\""
        rlLogInfo "LUKS device created at \$lodev"
    rlPhaseEnd

    rlPhaseStartTest "RHEL-163324: Verify clevis respects luksFormat hash"
        # Bind clevis to the LUKS device
        rlLogInfo "Binding clevis to LUKS device..."
        expect <<CLEVIS_END
            set timeout 60
            spawn sh -c "clevis luks bind -d $lodev tang '{ \"url\": \"http://localhost:$port\" }'"
            expect {
                "*Do you wish to trust these keys*" {send "y\r"; exp_continue}
                "*Enter existing LUKS password*" {send "redhat123\r"; exp_continue}
            }
CLEVIS_END
        rlAssert0 "Clevis luks bind command finished successfully"

        # Verify the hash algorithm in luksDump
        rlLogInfo "Checking luksDump for the correct hash algorithm..."
        rlRun "cryptsetup luksDump \$lodev > luks_dump.txt"
        # Find the keyslot used by clevis by searching for the JWE payload
        clevis_keyslot=\$(grep -B 5 -A 5 "clevis" luks_dump.txt | grep "Keyslot" | awk '{print \$2}' | tr -d ':')
        rlAssertNotEquals "Could not find Clevis keyslot" "\$clevis_keyslot" ""

        rlLogInfo "Clevis is using keyslot: \$clevis_keyslot"
        keyslot_info=\$(awk "/Keyslot \$clevis_keyslot/{flag=1;next}/Keyslot/{flag=0}flag" luks_dump.txt)
        rlLogInfo "Keyslot \$clevis_keyslot info:\n\$keyslot_info"

        # Check that the digest is sha512
        echo "\$keyslot_info" | rlAssertGrep "Digest:.*sha512" "The hash algorithm for the clevis keyslot should be sha512"

        # Verify that the device can be unlocked
        rlLogInfo "Verifying device can be unlocked by clevis..."
        rlRun "clevis luks unlock -d \$lodev -n luks-unlocked"
        rlRun "ls /dev/mapper/luks-unlocked" 0 "Device unlocked successfully"
        rlRun "cryptsetup close luks-unlocked"
    rlPhaseEnd

    rlPhaseStartCleanup "Cleanup"
        stop_tang "\$port"
        rlRun "losetup -d \"\$lodev\""
        rlRun "popd"
        rlRun "rm -rf \$TmpDir" 0 "Removing tmp directory"
    rlPhaseEnd
rlJournalPrintText
rlJournalEnd
