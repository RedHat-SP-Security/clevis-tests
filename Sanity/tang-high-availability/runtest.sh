#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/clevis/Sanity/tang-high-availability
#   Description: verifies sharing keys between tang servers
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

# gen_tang_keys()/gen_tang_cache() come from TestHelpers/utils.sh (sourced
# in Setup). These used to be local wrappers around tangd-keygen; they were
# removed so that sourcing utils.sh cannot silently redefine them mid-run.
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
            rlRun "mkdir -p tangd/db tangd/cache tangd/cache2"
            gen_tang_keys "tangd/db"
            gen_tang_cache "tangd/db" "tangd/cache"
            gen_tang_cache "tangd/db" "tangd/cache2"
            port=$(start_tang_http "tangd/cache")
        else
            rlRun "mkdir -p tangd/cache tangd/cache2"
            gen_tang_keys "tangd/cache"
            rlRun "cp -a tangd/cache/* tangd/cache2"
            port=$(start_tang_http "tangd/cache")
        fi
    rlPhaseEnd

    rlPhaseStart FAIL "clevis encrypt using first server, decrypt using second"
        rlRun "curl -sS -o adv.json \"http://localhost:$port/adv\""
        echo -n "testing data string" > plain
        rlRun "clevis encrypt tang '{ \"url\": \"http://localhost:$port\", \"adv\": \"adv.json\" }' < plain > enc"
        grep_b64 "http:" enc
        rlRun "stop_tang_http '$port'" 0 "Stop first Tang server"
        port=$(start_tang_http "tangd/cache2" "$port")
        rlRun "clevis decrypt < enc > plain2"
        rlAssertNotDiffer plain plain2
        rm -f adv plain enc plain2
    rlPhaseEnd

    rlPhaseStartCleanup
        rlRun "stop_tang_http '$port'" 0 "Stop Tang server"
        rlRun "popd"
        rlRun "rm -r $TmpDir" 0 "Removing tmp directory"
    rlPhaseEnd
rlJournalPrintText
rlJournalEnd
