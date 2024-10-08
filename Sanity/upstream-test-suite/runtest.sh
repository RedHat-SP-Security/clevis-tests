#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/clevis/Sanity/upstream-test-suite
#   Description: Run the upstream test suite
#   Author: Sergio Correia <scorreia@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2020 Red Hat, Inc.
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

rlJournalStart
    rlPhaseStartSetup
        rlAssertRpm "clevis" || rlDie
        rlRun "TmpDir=\$(mktemp -d)" 0 "Creating tmp directory"
        rlRun "pushd $TmpDir"
        if [ -d /root/rpmbuild ]; then
            rlRun "rlFileBackup /root/rpmbuild" 0 "Backup rpmbuild directory"
            touch backup
        fi
    rlPhaseEnd

    rlPhaseStartTest
        rlRun "rlFetchSrcForInstalled clevis"
        rlRun "rpm -Uvh *.src.rpm" 0 "Install clevis source rpm"

        # Enabling buildroot/CRB so that we can have the build dependencies.
        for r in rhel-buildroot rhel-CRB rhel-CRB-latest beaker-CRB; do
            ! dnf config-manager --set-enabled "${r}"
        done
        for repo in $(dnf repolist --all | grep -iE "crb|codeready|powertools" | grep -ivE "debug|source" | cut -d " " -f1); do
            dnf config-manager --set-enabled "${repo}"
        done

        rlRun "dnf builddep -y clevis*" 0 "Install clevis build dependencies"

        # Preparing source and applying existing patches.
        rlRun "SPEC=/root/rpmbuild/SPECS/clevis.spec"
        rlRun "SRCDIR=/root/rpmbuild/SOURCES"

        rlRun "rm -rf clevis-*"
        rlRun "tar xf ${SRCDIR}/clevis-*.tar.*" 0 "Unpacking clevis source"
        rlRun "pushd clevis-*"
            for p in $(grep ^Patch "${SPEC}" | awk '{ print$2 }'); do
                rlRun "patch -p1 < ${SRCDIR}/${p}" 0 "Applying patch ${p}"
            done

            rlRun "mkdir build"
            rlRun "pushd build"
                rlRun "meson .."
                rlRun "meson test" 0 "Running upstream test suite"
            rlRun "popd"
        rlRun "popd"
    rlPhaseEnd

    rlPhaseStartCleanup
        rlRun "rm -rf /root/rpmbuild" 0 "Removing rpmbuild directory"
        if [ -e backup ]; then
            rlRun "rlFileRestore" 0 "Restore previous rpmbuild directory"
        fi

        rlRun "popd"
        rlRun "rm -r ${TmpDir}" 0 "Removing tmp directory"
    rlPhaseEnd
rlJournalPrintText
rlJournalEnd
