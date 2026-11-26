#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/clevis/Sanity/bind-luks
#   Description: uses LUKS block device to test clevis luksmeta binding
#   Author: Jiri Jaburek <jjaburek@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2017 Red Hat, Inc.
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

# Include Beaker environment
. /usr/bin/rhts-environment.sh || :
. /usr/share/beakerlib/beakerlib.sh || exit 1

PACKAGE="clevis"

rlJournalStart
    rlPhaseStartSetup
        rlRun "rpm -q $PACKAGE || which clevis" 0 "Checking for the presence of clevis rpm"
        # Include utils library containing critical functions
        rlRun ". ../../TestHelpers/utils.sh" || rlDie "cannot import function script"
        rlRun "TmpDir=\$(mktemp -d)" 0 "Creating tmp directory"
        rlRun "pushd $TmpDir"
    rlPhaseEnd

    rlPhaseStart FAIL "tangd setup"
        if legacy_tang; then
            rlRun "mkdir -p tangd/db tangd/cache"
            gen_tang_keys "tangd/db"
            gen_tang_cache "tangd/db" "tangd/cache"
            port=$(start_tang_http "tangd/cache")
        else
            rlRun "mkdir -p tangd/db"
            gen_tang_keys "tangd/db"
            port=$(start_tang_http "tangd/db")
        fi
    rlPhaseEnd

    luks_setup

    rlPhaseStart FAIL "clevis bind-luks, confirmed interactively"
        if rlIsRHEL '<8'; then
            [ -z "$(luksmeta show -d "$lodev" -s 1)" ] || rlFail "existing luksmeta data found in slot 1"
        fi

        expect <<CLEVIS_END
            set timeout 60
            spawn sh -c "clevis luks bind -d $lodev tang '{ \"url\": \"http://localhost:$port\" }'"
            expect {
                {*Do you wish to trust these keys} {send y\\r; exp_continue}
                {*Do you wish to initialize} {send y\\r; exp_continue}
                {*Enter existing LUKS password} {send redhat123\\r; exp_continue}
            }
            exit [lindex [wait] 3]
CLEVIS_END
        rlAssert0 "expect spawning clevis" $?

        if rlIsRHEL '<8'; then
            [ "$(luksmeta show -d "$lodev" -s 1)" ] || rlFail "no luksmeta data found in slot 1"
        fi
    rlPhaseEnd

    luks_destroy
    luks_setup

    rlPhaseStart FAIL "clevis bind-luks, batch mode"
        rlRun "thp=\$(jose jwk thp -i tangd/db/sig.jwk)"

        if rlIsRHEL '<8'; then
            [ -z "$(luksmeta show -d "$lodev" -s 1)" ] || rlFail "existing luksmeta data found in slot 1"
        fi

        rlRun "clevis luks bind -f -k pwfile -d \"$lodev\" tang '{ \"url\": \"http://localhost:$port\", \"thp\": \"$thp\" }'" 0

        if rlIsRHEL '<8'; then
            [ "$(luksmeta show -d "$lodev" -s 1)" ] || rlFail "no luksmeta data found in slot 1"
        fi
    rlPhaseEnd

    luks_destroy

    rlPhaseStartCleanup
        rlRun "stop_tang_http '$port'" 0 "Stop local Tang server"
        rlRun "popd"
        rlRun "rm -r $TmpDir" 0 "Removing tmp directory"
    rlPhaseEnd
rlJournalPrintText
rlJournalEnd
