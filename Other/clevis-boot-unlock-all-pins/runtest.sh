#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /clevis-tests/Otherl/tang-boot-unlock
#   Description: Test of clevis boot unlock via tang.
#   Author: Patrik Koncity <pkoncity@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2024 Red Hat, Inc.
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
. /usr/share/beakerlib/beakerlib.sh || exit 1

# If this is set to true, we will keep the VMs that were created
# during the test. By default, we remove everything in the cleanup
# step.
DEBUG_VMS=${DEBUG_VMS:-}

# This test aims to be an example of virtualiztion tests that use our "vm"
# library. It goes like this:
# 1) Import the library, which will then prepare the test for virtualization,
#     installing and setting up the prerequisites (requires either Fedora or
#     RHEL >= 8).
# 2) Create VMs with 10mt (installed by the library)
# 3) Provision the VMs with 10mtctl provision <VM-ID>
# 4) call vmWaitForProvisioning by specifying a single argument that may
#    contain a list of VM-IDs, such as vmWaitForProvisioning 'VM1 VM2 VM2'
# 5) At this point, the VM is ready and you can start and use it

rlJournalStart
  rlPhaseStartSetup
    rlImport --all || rlDie "Import failed"
    rlRun "rlImport --all" 0 "Import libraries" || rlDie "cannot continue"

: <<'EOF'
#need to imported because pkcs11 implementation
rlRun ". ../../TestHelpers/utils.sh" || rlDie "cannot import function script"
EOF

    rlLogInfo "DEBUG_VMS=${DEBUG_VMS} <- set this variable if you want to keep the VMs after the test completes"

    rlLogInfo "DISABLE_SELINUX(${DISABLE_SELINUX})"
    if [ -n "${DISABLE_SELINUX}" ]; then
      rlRun "setenforce 0" 0 "Putting SELinux in Permissive mode"
    fi
    rlLogInfo "SELinux: $(getenforce)"

    # EXTRA_REPOS can be used in 1minutetip to specify a brew repo when
    # testing scratch/official builds. In beaker we usually will achieve
    # this in different ways.
    rlLogInfo "EXTRA_REPOS=${EXTRA_REPOS}"
    if [ -n "${EXTRA_REPOS}" ]; then
      count=0
      for repo in ${EXTRA_REPOS}; do
        count=$((count+1))
        curl -kL "${repo}" -o "/etc/yum.repos.d/extra-repo-r${count}.repo" ||:
      done
      dnf update -y ||:
    fi

    # EXTRA_VM_REPOS is similar to EXTRA_REPOS, but these repos will be
    # added to the provisioned VM.
    rlLogInfo "EXTRA_VM_REPOS=${EXTRA_VM_REPOS}"
    rlRun -s "env"
    rlFileSubmit "${rlRun_LOG}" "env.log"
    rlServiceStart tangd.socket
    rlServiceStatus tangd.socket
    TANG_IP=$(ip addr show $(ip route get 1 | awk '{print $5; exit}') | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)

: <<'EOF'
#TODO
#PKCS11 setup
#token could on host machine
#is it possible to open it first boot
install_softhsm
create_token
# Get serial number of the token
TOKEN_SERIAL_NUM=$(pkcs11-tool --module $SOFTHSM_LIB -L | grep "serial num" | awk '{print $4}')
rlAssertNotEquals "Test that the serial number is not empty" "" $TOKEN_SERIAL_NUM
URI="{\"uri\": \"pkcs11:model=SoftHSM%20v2;serial=$TOKEN_SERIAL_NUM;token=$TOKEN_LABEL;id=$ID;module-path=$SOFTHSM_LIB?pin-value=$PINVALUE\", \"mechanism\": \"RSA-PKCS\"}"
#need to be added as another sss to snippet
rlRun "clevis luks bind -k pwfile -d ${parent_disk} pkcs11 '$URI'" 0 "Bind the clevis to the disk"
#also needed to enable pkcs11 askpass
rlRun "systemctl enable clevis-luks-pkcs11-askpass.socket"
EOF

  rlPhaseEnd

  rlPhaseStartTest "VM provisioning"
    # Check if we can provision the VM.
    VM_DISK_SIZE=8
    export VM_DISK_SIZE
    # Space required for provisioning a single VM.
    SINGLE_SIZE=$((VM_DISK_SIZE+1))

    _space="$(df -BG /var/lib/ | tail -1 | awk '{ print $4 }' | tr -d 'G')"
    [ "${_space}" -lt "${SINGLE_SIZE}" ] \
      && rlDie "Not enough space (${_space}) to provision a VM"

    _test="single"
    rlLogInfo "TEST(${_test}, SPACE(${_space}))"

    if ! NET_RANGE="$(virsh net-dumpxml --network default \
                      | grep range \
                      | cut -d"'" -f2 \
                      | awk -F'.' '{print $1,$2,$3}' OFS='.')" \
                      || [ -z "${NET_RANGE}" ]; then
      rlDie "Unable to determine default network range"
    fi

    rlLogInfo "Default network range: ${NET_RANGE}"

    ADDR="${NET_RANGE}".99
    #ADD IT AS FUNCTION TO VM LIBRARY
    if [ -z "${SYSTEM}" ]; then
      # Default is rhel9.
      SYSTEM=rhel9

      # If we are using either RHEL8, 9 or 10, let's try to use
      # a compose of the same version.
      VERSION_ID=$(grep VERSION_ID /etc/os-release | cut -d'=' -f2  | tr -d '"')
      rlIsRHEL 10 && SYSTEM="rhel10 -r ${VERSION_ID}"
      rlIsRHEL 9 && SYSTEM="rhel9 -r ${VERSION_ID}"
      rlIsRHEL 8 && SYSTEM="rhel8 -r ${VERSION_ID}"
      rlIsFedora && SYSTEM="fedora -r ${VERSION_ID}"
    fi
    ###
    rlLogInfo "SYSTEM: ${SYSTEM}, ADDR: ${ADDR}"

    #maybe part of 10mt for future, now it is kinda workaround
    rlRun "cp clevis-boot-unlock-all-pins /usr/share/10mt/template/post/"

    VM_ID="$(10mt -z -s ${SYSTEM} -k ~/.ssh/id_rsa.pub -a "${ADDR}" -t -x clevis-boot-unlock-all-pins -v TANG_SERVER=${TANG_IP})"
    [ -n "${VM_ID}" ] || rlDie "Unable to get VM_ID; cannot continue"

    _compose="$(10mtctl compose "${VM_ID}")"
    rlLogInfo "COMPOSE: ${_compose}"

    # Provision the VM.
    rlRun "10mtctl provision \"${VM_ID}\""
    rlRun "vmWaitForProvisioning ${VM_ID}" \
      || rlDie "VM was not provisioned in time"

    rlRun "10mtctl start \"${VM_ID}\""
    #10mtctl info <ID>
    #10mtctl console <ID>
    rlRun "vmWaitByAddr ${ADDR}" \
      || rlDie "Cannot continue without VM responding"

    if rlIsRHELLike '>=10'; then
      rlRun "vmCmd ${ADDR} journalctl -b | grep \"Finished systemd-cryptsetup\""
    else
      rlRun "vmCmd ${ADDR} journalctl -b | grep \"Finished Cryptography Setup for luks-\""
      rlRun "vmCmd ${ADDR} journalctl -b | grep \"clevis-luks-askpass.service: Deactivated successfully\""
    fi

    # Now we setup any extra VM repos.
    if [ -n "${EXTRA_VM_REPOS}" ]; then
      count=0
      for repo in ${EXTRA_VM_REPOS}; do
        count=$((count+1))
        vmCmd "${ADDR}" "curl -kL '${repo}' -o '/etc/yum.repos.d/extra-repo-r${count}.repo'" ||:
      done
      vmCmd "${ADDR}" "dnf update -y" ||:
    fi
  rlPhaseEnd

  rlPhaseStartCleanup
    # The vm library may have backup'ed some files during its setup,
    # so let's restore that now.
    rlRun "rlFileRestore"

    # By default, we remove the VMs that were created, but we can keep
    # them if required, by setting DEBUG_VMS env variable.
    # Let's also set this variable if some test did not pass, so we can
    # try to debug it.
    [ -n "${__INTERNAL_PHASES_WORST_RESULT}" ] \
      && [ "${__INTERNAL_PHASES_WORST_RESULT}" != "PASS" ] \
      && DEBUG_VMS=true

    # You can list the 10mt VMs with "10mtctl list".
    [ -z "${DEBUG_VMS}" ] && 10mt -A
    rlRun "rm -f /usr/share/10mt/template/post/clevis-boot-unlock-all-pins"
  rlPhaseEnd
rlJournalEnd
