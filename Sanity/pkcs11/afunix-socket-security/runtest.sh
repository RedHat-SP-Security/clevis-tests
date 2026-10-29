#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/clevis/Sanity/pkcs11/afunix-socket-security
#   Description: tests the security properties of clevis-pkcs11-afunix-socket-unlock
#   Author: Andrei Prikryl
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

. /usr/bin/rhts-environment.sh || :
. /usr/share/beakerlib/beakerlib.sh || exit 1

PACKAGE="clevis"
DAEMON="clevis-pkcs11-afunix-socket-unlock"
SOCK_DIR=""
DATA_SOCK=""
CONTROL_SOCK=""
LOG_FILE=""

stop_daemon() {
    if [ -n "$DAEMON_PID" ]; then
        kill "$DAEMON_PID" 2>/dev/null
        wait "$DAEMON_PID" 2>/dev/null
        DAEMON_PID=""
    fi
}

start_daemon() {
    # Recreate socket directory for a clean state each phase
    rm -rf "$SOCK_DIR"
    SOCK_DIR=$(mktemp -d)
    DATA_SOCK="${SOCK_DIR}/clevis-pkcs11.sock"
    CONTROL_SOCK="${SOCK_DIR}/clevis-pkcs11.control.sock"
    LOG_FILE="${SOCK_DIR}/clevis-pkcs11-test.log"

    $DAEMON -l "$LOG_FILE" -f "$DATA_SOCK" -s 0 -t 120 &
    DAEMON_PID=$!
    # Wait for sockets to appear
    local retries=50
    while [ $retries -gt 0 ] && [ ! -S "$DATA_SOCK" ]; do
        sleep 0.1
        retries=$((retries - 1))
    done
    rlAssertExists "$DATA_SOCK"
}

rlJournalStart
    rlPhaseStartSetup
        rlRun ". ../../../TestHelpers/utils.sh" || rlDie "cannot import function script"
        install_clevis_pkcs11
        rlRun "rpm -q $PACKAGE || which clevis" 0 "Checking for the presence of clevis rpm"
        rlRun "which $DAEMON" 0 "Checking for the presence of $DAEMON"
    rlPhaseEnd

    rlPhaseStart FAIL "Daemon must not crash on unbound client connection (CVE-2026-109976)"
        start_daemon

        # Connect without bind - this triggers the integer underflow on unpatched versions
        rlRun "echo '' | socat - UNIX-CONNECT:${DATA_SOCK} 2>/dev/null" 0,1 \
            "Connect to data socket without bind (socat does not call bind)"

        sleep 1

        # Check if the daemon is still alive (non-blocking)
        if kill -0 "$DAEMON_PID" 2>/dev/null; then
            rlPass "Daemon survived unbound client connection"
        else
            wait "$DAEMON_PID" 2>/dev/null
            EXIT_CODE=$?
            rlFail "Daemon crashed after unbound client connection (exit code: $EXIT_CODE)"
            DAEMON_PID=""
        fi

        stop_daemon
    rlPhaseEnd

    rlPhaseStart FAIL "Socket permissions must be restrictive (CVE-2026-109969)"
        start_daemon

        DATA_SOCK_PERMS=$(stat -c '%a' "$DATA_SOCK")
        rlLog "Data socket permissions: $DATA_SOCK_PERMS"

        # Sockets should not be world-accessible (no write permission for others)
        OTHERS_WRITE=$(echo "$DATA_SOCK_PERMS" | grep -c '[2367]$')
        rlAssertEquals "Data socket must NOT have world-write permission" "$OTHERS_WRITE" "0"

        if [ -S "$CONTROL_SOCK" ]; then
            CTRL_SOCK_PERMS=$(stat -c '%a' "$CONTROL_SOCK")
            rlLog "Control socket permissions: $CTRL_SOCK_PERMS"
            OTHERS_WRITE_CTRL=$(echo "$CTRL_SOCK_PERMS" | grep -c '[2367]$')
            rlAssertEquals "Control socket must NOT have world-write permission" "$OTHERS_WRITE_CTRL" "0"
        else
            rlLog "Control socket not found at $CONTROL_SOCK (may use different path)"
        fi

        stop_daemon
    rlPhaseEnd

    rlPhaseStart FAIL "Log file must not contain plaintext passphrase (CVE-2026-109968)"
        start_daemon
        TEST_PASSPHRASE="SENSITIVE_TEST_PASSPHRASE_$(date +%s)"

        # Wait for control socket
        retries=50
        while [ $retries -gt 0 ] && [ ! -S "$CONTROL_SOCK" ]; do
            sleep 0.1
            retries=$((retries - 1))
        done

        if [ -S "$CONTROL_SOCK" ]; then
            # Send a device,passphrase pair via control socket
            rlRun "printf 'test-device,%s\n' '$TEST_PASSPHRASE' | socat - UNIX-CONNECT:${CONTROL_SOCK}" \
                0,1 "Send test passphrase via control socket"

            sleep 1

            # Verify log file permissions
            if [ -f "$LOG_FILE" ]; then
                LOG_PERMS=$(stat -c '%a' "$LOG_FILE")
                rlLog "Log file permissions: $LOG_PERMS"
                rlAssertEquals "Log file must have restrictive permissions (0600)" "$LOG_PERMS" "600"

                # Verify passphrase is NOT in the log
                if grep -q "$TEST_PASSPHRASE" "$LOG_FILE"; then
                    rlFail "Plaintext passphrase found in log file"
                    rlLog "Log contents (redacted): $(sed "s/$TEST_PASSPHRASE/[REDACTED]/g" "$LOG_FILE")"
                else
                    rlPass "Passphrase is NOT logged in plaintext"
                fi
            else
                rlLog "Log file not created"
            fi
        else
            rlLog "Control socket not available, skipping passphrase logging test"
        fi

        stop_daemon
    rlPhaseEnd

    rlPhaseStartCleanup
        stop_daemon
        rm -rf "$SOCK_DIR"
    rlPhaseEnd
rlJournalPrintText
rlJournalEnd
