#!/bin/bash
# vim: dict=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Author: Patrik Koncity <pkoncityt@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2025 Red Hat, Inc.
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
. /usr/share/beakerlib/beakerlib.sh || exit 1

TESTDIR=`pwd`

function checkFile() {
    MUSTEXIST=false
    if [ "$1" == "-e" ]; then
        MUSTEXIST=true
        shift
    fi
    FILEPATH=$1
    OWNER=$2
    GROUP=$3
    if "$MUSTEXIST" || [ -e "$FILEPATH" ]; then
        ls -ld $FILEPATH
        rlRun "ls -ld $FILEPATH | grep -qE '$OWNER[ ]*$GROUP'"
    fi
}

rlJournalStart
    rlPhaseStartTest
        # verify user account
        rlRun -s "id clevis"
        rlRun "grep -E 'groups=.*clevis' $rlRun_LOG"
        rlRun "grep -E 'gid=.*clevis' $rlRun_LOG"
        rlRun "grep -E 'uid=.*clevis.*tss' $rlRun_LOG"
    rlPhaseEnd
rlJournalPrintText
rlJournalEnd
