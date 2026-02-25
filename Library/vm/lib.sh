#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Description: provides helper shell functions for dealing with vms
#   Author: Sergio Correia <scorreia@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2022 Red Hat, Inc.
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
#   library-prefix = vm
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Include Beaker environment
. /usr/share/beakerlib/beakerlib.sh || exit 1


true <<'=cut'
=pod

=head1 NAME

clevis/vm - provides helper shell functions for dealing with vms

=head1 DESCRIPTION

The library provides shell functions to ease testing of clevis with virtual
machines.

=cut

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Variables
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Timeout to wait for VM to boot and respond to commands via ssh.
export __INTERNAL_BOOT_TIMEOUT
[ -n "${__INTERNAL_BOOT_TIMEOUT}" ] || __INTERNAL_BOOT_TIMEOUT=600

# Timeout to wait for VM to be provisioned.
export __INTERNAL_PROVISIONING_TIMEOUT
[ -n "${__INTERNAL_PROVISIONING_TIMEOUT}" ] || __INTERNAL_PROVISIONING_TIMEOUT=1800

export __INTERNAL_SWAPFILE
[ -n "${__INTERNAL_SWAPFILE}" ] || __INTERNAL_SWAPFILE=/vm-swapfile

# Wait time before start checking for VMs provisioned/responding.
export __INTERNAL_VM_WAIT_TIME
[ -n "${__INTERNAL_VM_WAIT_TIME}" ] || __INTERNAL_VM_WAIT_TIME=15

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Functions
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

true <<'=cut'
=pod

=head1 FUNCTIONS

=head2 vmCmd

Runs a specific command within a given VM, via ssh

  vmCmd <ADDR> <cmd>

=over

=back

Runs a given command within a given VM, via ssh, and returns its
return code.

=cut

vmCmd() {
  [ -z "${1}" ] && rlLogWarning "(vmCmd) no VM addr specified" && return 1
  [ -z "${2}" ] && rlLogWarning "(vmCmd) no command specified" && return 1
  local _skiplog=${3:-}

  [ -z "${_skiplog}" ] && rlLogInfo "(vmCmd) SYSTEM=(${1}) CMD=(${2})"
  ssh "${1}" "${2}"
}


true <<'=cut'
=pod

=head1 FUNCTIONS

=head2 vmWaitByAddr

Wait for VM to respond to commands via ssh

  vmWaitByAddr <ADDR> [timeout]

=over

=back

Return success or failure depending on whether the VM was able to
respond to commands via SSH within the specified timeout

=cut

vmWaitByAddr() {
  local _addr=${1:-}
  [ -z "${_addr}" ] \
    && rlLogWarning "(vmWaitByAddr) VM addr was not defined" \
    && return 1

  local _timeout=${2:-${__INTERNAL_BOOT_TIMEOUT}}

  # Let's store the addresses of VMs in an array.
  # Yeah, bash arrays are awful, but...
  _vms=()
  _status=()
  for _vm in ${_addr}; do
    _vms+=("${_vm}")
    _status+=("NOT-OK")
  done

  _suffix=
  [ "${#_vms[@]}" -gt 1 ] && _suffix=s
  rlLogInfo "(vmWaitByAddr) Waiting up to ${_timeout} seconds for ${#_vms[@]} VM${_suffix} (${_addr}) to respond..."

  local _start _elapsed
  _start=${SECONDS}
  _elapsed=0
  _ok=0

  # Let's wait a little while before start checking if the VMs
  # are responding.
  sleep "${__INTERNAL_VM_WAIT_TIME}"

  while /bin/true; do
    # Now let's check the VMs.
    for _i in "${!_vms[@]}"; do
      [ "${_status[${_i}]}" = "OK" ] && continue
      if vmCmd "${_vms[${_i}]}" ls _SKIP_LOG_ 2>/dev/null >/dev/null; then
        _elapsed=$((SECONDS - _start))
        rlLogInfo "(vmWaitByAddr) VM "${_vms[${_i}]}" responded within ${_elapsed} seconds"
        _ok=$((_ok+1))
        _status[${_i}]="OK"
      fi
    done

    _elapsed=$((SECONDS - _start))

    # Check if all the expected VMs repsonded.
    [ "${_ok}" -eq "${#_vms[@]}" ] && break

    if [ "${_elapsed}" -gt "${_timeout}" ]; then
      rlLogWarning "(vmWaitByAddr) TIMEOUT (${_timeout}) reached; status report to follow:"
      # Before returning, let's inform the status, which may be helpful
      # when debugging.
      for _i in "${!_vms[@]}"; do
        rlLogWarning "(vmWaitByAddr) VM: ${_vms[${_i}]}, STATUS: ${_status[${_i}]}"
      done
      return 1
    fi

    sleep 0.2
  done
  _elapsed=$((SECONDS - _start))
  rlLogInfo "(vmWaitByAddr) ${#_vms[@]} VM${_suffix} (${_addr}) up in ${_elapsed} seconds"
  return 0
}

true <<'=cut'
=pod

=head1 FUNCTIONS

=head2 vmPaused

Checks is VM is paused

  vmPaused <VIRSH-NAME>

=over

=back

Return success or failure depending on whether the VM is paused.

=cut

vmPaused() {
  local _virsh_name=${1:-}
  [ -z "${_virsh_name}" ] \
    && rlLogWarning "(vmPaused) VM virsh name was not defined; try 10mctl name <VM ID> to get it" \
    && return 1

  virsh list --state-paused --name | grep -qw "${_virsh_name}"
}

true <<'=cut'
=pod

=head1 FUNCTIONS

=head2 vmProvisioned

Checks is VM is provisioned

  vmProvisioned <VIRSH-NAME>

=over

=back

Return success or failure depending on whether the VM is provisioned.

=cut

vmProvisioned() {
  local _virsh_name=${1:-}
  [ -z "${_virsh_name}" ] \
    && rlLogWarning "(vmProvisioned) VM virsh name was not defined; try 10mctl name <VM ID> to get it" \
    && return 1

  virsh list --state-shutoff --name | grep -qw "${_virsh_name}"
}

true <<'=cut'
=pod

=head1 FUNCTIONS

=head2 vmWaitForProvisioning

Wait for VM to be provisioned

  vmWaitForProvisioning <VIRSH-NAME> [timeout]

=over

=back

Return success or failure depending on whether the VM was able to
be provisioned within the specified timeframe.

=cut

vmWaitForProvisioning() {
  local _vm_list="${1:-}"
  [ -z "${_vm_list}" ] \
    && rlLogWarning "(vmWaitForProvisioning) VMs to wait for provisioning was not defined" \
    && return 1

  local _timeout=${2:-${__INTERNAL_PROVISIONING_TIMEOUT}}

  # Let's store the names of VMs in an array.
  # Yeah, bash arrays are awful, but...
  _vms=()
  _virsh=()
  _status=()
  for _vm in ${_vm_list}; do
    _vms+=("${_vm}")
    _vname="$(10mtctl name "${_vm}")"
    _virsh+=("${_vname}")
    _status+=("NOT-OK")
  done

  _suffix=s
  [ "${#_vms[@]}" -eq 1 ] && _suffix=
  rlLogInfo "(vmWaitForProvisioning) Waiting up to ${_timeout} seconds for ${#_vms[@]} VM${_suffix} (${_vm_list}) to be provisioned..."

  local _start _elapsed
  _start=${SECONDS}
  _elapsed=0
  _provisioned=0
  _failed=0
  _failed_vms=

  # Let's wait a little while before start checking if the VMs
  # were provisioned.
  sleep "${__INTERNAL_VM_WAIT_TIME}"

  while /bin/true; do
    # Now let's check the VMs.
    for _i in "${!_virsh[@]}"; do
      case "${_status[${_i}]}" in
      "OK"|"NOT-OK-PAUSED")
        continue;;
      esac
      if vmProvisioned "${_virsh[${_i}]}"; then
        _elapsed=$((SECONDS - _start))
        rlLogInfo "(vmWaitForProvisioning) VM ${_vms[${_i}]} provisioned within ${_elapsed} seconds"
        _provisioned=$((_provisioned+1))
        _status[${_i}]="OK"
      elif vmPaused "${_virsh[${_i}]}"; then
        _elapsed=$((SECONDS - _start))
        rlLogWarning "(vmWaitForProvisioning) VM ${_vms[${_i}]} detected as PAUSED within ${_elapsed} seconds"
        _failed=$((_failed+1))
        _failed_vms="${_failed_vms} ${_vms[${_i}]}"
        _status[${_i}]="NOT-OK-PAUSED"
      fi
    done

    # Check if we provisioned (and/or failed) the expected number of VMs.
    [ $((_provisioned + _failed)) -eq "${#_vms[@]}" ] && break

    _elapsed=$((SECONDS - _start))
    if [ "${_elapsed}" -gt "${_timeout}" ]; then
      rlLogWarning "(vmWaitForProvisioning) TIMEOUT (${_timeout}) reached; status report to follow:"
      # Before returning, let's inform the status, which may be helpful
      # when debugging.
      for _i in "${!_vms[@]}"; do
        rlLogWarning "(vmWaitForProvisioning) VM: ${_vms[${_i}]}, STATUS: ${_status[${_i}]}"
      done
      return 1
    fi

    sleep 0.2
  done

  _elapsed=$((SECONDS - _start))

  if [ "${_failed}" -gt 0 ]; then
    IFS=' ' read _failed_vms <<< "${_failed_vms}"
    _suffix=s
    [ "${_failed}" -eq 1 ] && _suffix=
    rlLogError "(vmWaitForProvisioning) failed, as ${_failed} VM${_suffix} (${_failed_vms}) failed to provision; elapsed time: ${_elapsed} seconds"
    return 1
  fi

  rlLogInfo "(vmWaitForProvisioning) ${_provisioned} VM${_suffix} (${_vm_list}) provisioned in ${_elapsed} seconds"
  return 0
}

# ~~~~~~~~~~~~~~~~~~~~
#   Setup
# ~~~~~~~~~~~~~~~~~~~~

__enable_crb() {
  # Attempt to enable CRB/PowerTools, which in RHEL 8 provides
  # things like swtpm.
  for _r in $(dnf repolist --all \
              | grep -iE 'crb|codeready|powertools' \
              | grep -ivE 'debug|source' \
              | awk '{ print $1 }'); do
    dnf config-manager --set-enabled "${_r}" ||:
  done
}

__setup_10mt() {
  __enable_crb

  if ! dnf copr enable scorreia/10mt -y; then
    # RHEL-10/EPEL10 does not yet (ca. May-2024) have a proper COPR buildroot,
    # so we will use c10s, if it fails to enable the repository.
    if rlIsRHEL '10'; then
      dnf copr enable scorreia/10mt centos-stream-10-x86_64 -y
    fi
  fi

  if ! dnf copr enable copr.devel.redhat.com/scorreia/10mt -y; then
    # RHEL-10/EPEL10 does not yet (ca. May-2024) have a proper COPR buildroot,
    # so we will use epel-9, if it fails to enable the repository.
    if rlIsRHEL '10'; then
      dnf copr enable copr.devel.redhat.com/scorreia/10mt epel-9-x86_64 -y
    fi
  fi

  rlRun "yum -y install 10mt"
  rlAssertRpm 10mt || rlDie "Cannot continue without 10mt"
  rlRun "yum -y install 10mt-redhat"
  rlAssertRpm 10mt-redhat || rlDie "Cannot continue without 10mt-redhat"
  rlRun "dnf config-manager --set-disable epel" 0-1 "Disable epel if it's enabled"

  rlRun "semodule -i /usr/share/selinux/packages/10mt/policy10mt.pp" 0-1 "Attempt to load 10mt SELinux policy"
  rlRun -s "semodule -l"
  rlFileSubmit "${rlRun_LOG}" "semodule-l.txt"

  # RHEL-35244: RHEL-10 uses nftables instead of iptables that have been
  # deprecated, and libvirt doesn't seem to account for that. This can
  # cause issues when creating a new network from XML via virsh
  # (but this is likely not the only problematic spot).
  if rlIsRHEL '10'; then
    # Workaround for libvirt/iptables issue mentioned above.
    dnf install kernel-modules-extra -y
    modprobe nft_compat ||:
  fi

  rlServiceStart libvirtd
  rlRun "virt-host-validate" 0-1 "Get info on virtualization capabilities"
}

__setup_swap() {
  [ -e "${__INTERNAL_SWAPFILE}" ] && return 0

  fallocate -l3G "${__INTERNAL_SWAPFILE}"
  chmod 600 "${__INTERNAL_SWAPFILE}"
  mkswap "${__INTERNAL_SWAPFILE}"
  swapon "${__INTERNAL_SWAPFILE}"
}

__setup_ssh() {
  rlRun "rlFileBackup --clean ~/.ssh/"

  mkdir -p ~/.ssh
  chmod 700 ~/.ssh
  ssh-keygen -q -t rsa -b 4096 -N '' -f ~/.ssh/id_rsa <<< y 2>&1 >/dev/null
  rm -f ~/.ssh/known_hosts
  cat << EOF > ~/.ssh/config
Host *
  user root
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel QUIET
EOF
  chmod 600 ~/.ssh/config
}

true <<'=cut'
=pod

=head2 vmInitVirtTesting

Prepare everything for a virtualization-based test.

=over

=back

Returns 0 when the start was successful, non-zero otherwise.

=cut

vmInitVirtTesting() {
  __setup_swap
  __setup_ssh
  __setup_10mt
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Initialization
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

vmInitVirtTesting

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Verification
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   This is a verification callback which will be called by
#   rlImport after sourcing the library to make sure everything is
#   all right. It makes sense to perform a basic sanity test and
#   check that all required packages are installed. The function
#   should return 0 only when the library is ready to serve.

vmLibraryLoaded() {
    if [ -e "${__INTERNAL_SWAPFILE}" ]; then
        rlLogDebug "Library clevis/vm loaded."
        return 0
    else
        rlLogError "Failed loading library clevis/vm."
        return 1
    fi
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Authors
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

true <<'=cut'
=pod

=head1 AUTHORS

=over

=item *

Sergio Correia <scorreia@redhat.com>

=back

=cut
# vim:set ts=2 sw=2 et:
