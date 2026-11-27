#!/bin/bash

_FIPS_CACHED=""
is_fips_enabled() {
    if [ -z "$_FIPS_CACHED" ]; then
        [ "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null)" = "1" ] && _FIPS_CACHED=1 || _FIPS_CACHED=0
    fi
    [ "$_FIPS_CACHED" = "1" ]
}

create_hsm_config() {
    # Create a configuration file for the softhsm

    rlLog "Creating a softhsm configuration file"
    cat > $TMPDIR/softhsm.conf << EOF
directories.tokendir = $TMPDIR
objectstore.backend = file
log.level = DEBUG
EOF
}

# Generates a TLS cert with a specific algorithm and output filenames.
gen_tls_cert() {
    local crypto_alg=$1 key_file=$2 cert_file=$3
    # The fourth argument is the optional IP address
    local ip_address=$4

    rlLog "Generating $crypto_alg TLS certificate..."

    # Start building the Subject Alternative Name (SAN) options.
    # The DNS name 'localhost' is always included.
    local san_options="subjectAltName = DNS:localhost"

    # If an IP address was provided, add it to the SAN options.
    if [ -n "$ip_address" ]; then
        san_options="$san_options,IP:$ip_address"
        rlLog "Including IP SAN: $ip_address"
    fi

    local pkey_alg_opt=""
    local extra_opts=""

    case "$crypto_alg" in
        RSA)
            pkey_alg_opt="rsa:4096"
            ;;
        ECC | ECDSA)
            pkey_alg_opt="ec"
            extra_opts="-pkeyopt ec_paramgen_curve:prime256v1"
            ;;
        ML-DSA-65)
            rlLog "Note: Using a post-quantum algorithm."
            pkey_alg_opt="mldsa65"
            ;;
        *)
            rlLogFatal "Unsupported algorithm: $crypto_alg"; return 1 ;;
    esac

    rlRun "openssl req -x509 -nodes \
        -newkey $pkey_alg_opt $extra_opts \
        -keyout \"$key_file\" -out \"$cert_file\" \
        -subj \"/CN=localhost\" -days 365 \
        -addext \"$san_options\""
}

install_softhsm() {
    # TODO: the test may only run on latest Feodra and RHEL>9 versions:
    #   https://issues.redhat.com/browse/RHEL-34856
    rlRun "dnf install softhsm -y"
}

install_clevis_pkcs11() {
    if rpm -qa | grep -q clevis-pin-pkcs11; then
        export PKCS11_IMPLEMENTED=1
        rlRun "rpm -q clevis-pin-pkcs11"
        rlLogInfo "Package is already installed on system!"
    else
        rlRun "dnf info clevis-pin-pkcs11 && dnf install -y clevis-pin-pkcs11 || :"
    fi
}

luks_setup() {
    # Create disk out of the file on the system.
    rlPhaseStart FAIL "cryptsetup setup"
        rlRun "dd if=/dev/zero of=loopfile bs=100M count=1"
        rlRun "lodev=\$(losetup -f --show loopfile)"
        echo -n redhat123 > pwfile
        rlRun "cryptsetup luksFormat --batch-mode --key-file pwfile \"$lodev\""
    rlPhaseEnd
}

luks_destroy() {
    rlPhaseStart FAIL "cryptsetup destroy"
        rlRun "losetup -d \"$lodev\""
        rlRun "rm -f loopfile pwfile"
    rlPhaseEnd
}

prepare_dracut() {
    # Put the softhsm library and the configuration file to initramfs so it can be used
    # by Clevis to load the smartcard and decrypt the disk.
    rlPhaseStart FAIL "softhsm dracut setup"
        rlRun "dracut -f -v --include $SOFTHSM_LIB $SOFTHSM_LIB --include /etc/softhsm2.conf /etc/softhsm2.conf" 0 "Include softhsm libraries in initramfs"
    rlPhaseEnd
}

create_token() {
    # Create a softhsm token
    rlPhaseStart FAIL "create softhsm token"
        TOKEN_LABEL="test_token"
        SOFTHSM_LIB="/usr/lib64/softhsm/libsofthsm.so"
        PINVALUE=1234
        ID="0001"

        rlRun -l "softhsm2-util --init-token --label $TOKEN_LABEL --free --pin $PINVALUE --so-pin $PINVALUE" 0 "Initialize token"
        rlRun -l "pkcs11-tool --keypairgen --key-type="rsa:2048" --login --pin=$PINVALUE --module=$SOFTHSM_LIB --label=$TOKEN_LABEL --id=$ID" 0 "Generating a new key pair"

        rlRun -l "pkcs11-tool -L --module=$SOFTHSM_LIB"
    rlPhaseEnd
}

# Cached ML-KEM-768 capability probe. The result is per-process and
# intentionally never reset: a test that replaced the jose binary mid-run
# (not something we do today) would get a stale answer.
_TANG_HAS_KEM_CACHED=""
# Detect whether the installed jose can generate ML-KEM-768 keys. This
# reflects the jose build only, NOT the OpenSSL FIPS provider state: on a
# FIPS-enabled host where ML-KEM is not approved it may report no KEM. Do
# not reuse it as a FIPS-capability probe; FIPS prerequisite validation is
# covered separately by the jose tests (T1.1 Phase 5).
tang_has_kem() {
    if [ -z "$_TANG_HAS_KEM_CACHED" ]; then
        jose jwk gen -i '{"alg":"ML-KEM-768"}' -o /dev/null 2>/dev/null \
            && _TANG_HAS_KEM_CACHED=1 || _TANG_HAS_KEM_CACHED=0
    fi
    [ "$_TANG_HAS_KEM_CACHED" = "1" ]
}

# Generate Tang keys in the directory given as (remaining) first argument:
# ES512 signing (sig.jwk) and ECMR exchange (exc.jwk) keys, plus an
# ML-KEM-768 key (kem.jwk) when jose supports it.
#
# Pass --require-kem as the first argument to hard-fail when ML-KEM-768 is
# unavailable: hybrid (Tier 3) tests must fail rather than silently
# provision a KEM-less Tang -- per the test strategy, release-gate tests
# fail, they do not skip, when a mandatory dependency is absent.
gen_tang_keys() {
    local require_kem=false
    if [ "${1:-}" = "--require-kem" ]; then
        require_kem=true
        shift
    fi
    local key_dir="$1"
    rlRun "jose jwk gen -i '{\"alg\":\"ES512\"}' -o \"$key_dir/sig.jwk\""
    rlRun "jose jwk gen -i '{\"alg\":\"ECMR\"}' -o \"$key_dir/exc.jwk\""
    if tang_has_kem; then
        rlRun "jose jwk gen -i '{\"alg\":\"ML-KEM-768\"}' -o \"$key_dir/kem.jwk\""
    elif [ "$require_kem" = "true" ]; then
        rlFail "gen_tang_keys: ML-KEM-768 support is required by this test, but the installed jose does not provide it (jose PR #184)"
        return 1
    fi
}

gen_tang_cache() {
    rlRun "/usr/libexec/tangd-update \"$1\" \"$2\""
}

# Starts the tangd process reliably and saves its PID for cleanup.
start_tang_fn() {
    local i= cache="$1" port="$2"
    if [ -z "$port" ]; then
        for i in {8000..8999}; do
            # Use 'ss' for a more reliable check of listening ports
            if ! ss -tlpn | grep -q ":$i\s"; then
                port="$i"
                break
            fi
        done
    fi
    if [ -z "$port" ]; then
        rlLogFatal "no free port found for tangd"; return 1
    fi
    
    # Added 'reuseaddr' to solve the TIME_WAIT issue
    nohup socat "openssl-listen:$port,fork,reuseaddr,cert=server.crt,key=server.key,verify=0" \
        exec:"/usr/libexec/tangd $cache" >/dev/null &


    local pid=$!
    # Save the PID for robust cleanup
    echo "$pid" > tang.pid

    rlWaitForSocket "$port" -p "$pid"
    rlLogInfo "started tangd (TLS) $cache as pid $pid on port $port"
    echo "$port"
}

# Stops the tangd process using its saved PID.
stop_tang_fn() {
    if [ -f tang.pid ]; then
        rlRun "kill \$(cat tang.pid)" 0 "Stopping tangd process by PID"
        rm tang.pid
    else
        # Fallback for safety, though it shouldn't be needed
        rlLog "tang.pid not found. Stopping by port instead."
        rlRun "fuser -s -k \"$1/tcp\""
    fi
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Plain-HTTP tangd management (shared)
#
# Distinct from start_tang_fn/stop_tang_fn above, which wrap a TLS
# (openssl-listen) listener. These helpers start plain HTTP tangd.
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# True when the installed tang is the legacy variant with tangd-update.
legacy_tang() {
    test -x /usr/libexec/tangd-update
}

# Directory holding this file, resolved at source time so the shared
# tang-fault-proxy.py can be located regardless of the caller's cwd.
_TANG_HELPERS_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# socat listener PIDs we started, as a flat "port=pid" list. Kept as a
# plain string (not an associative array) so it survives being sourced
# and called from any shell context.
_TANG_HTTP_PIDS=""

# Pick a free ephemeral port. The reservation lasts only while the python
# process holds the socket, so there is a short window before socat binds;
# if socat loses that race rlWaitForSocket fails and start_tang_http
# reports an error instead of passing with a dead server.
_tang_free_port() {
    python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

_tang_http_remember_pid() { # PORT PID — replaces any earlier entry for PORT
    local port="$1" pid="$2" entry rebuilt=""
    for entry in $_TANG_HTTP_PIDS; do
        [ "${entry%%=*}" = "$port" ] && continue
        rebuilt="${rebuilt:+${rebuilt} }${entry}"
    done
    _TANG_HTTP_PIDS="${rebuilt:+${rebuilt} }${port}=${pid}"
}

_tang_http_pid_for() { # PORT -> echoes PID, fails when unknown
    local entry
    for entry in $_TANG_HTTP_PIDS; do
        if [ "${entry%%=*}" = "$1" ]; then
            echo "${entry#*=}"
            return 0
        fi
    done
    return 1
}

# Starts socat + tangd on an exact port. Returns non-zero when the
# listener fails to come up (bind race, tangd crash). Records the PID for
# stop_tang_http, stores the port in the global TANG_HTTP_PORT, and
# echoes the port for command-substitution callers.
_start_tang_http_on_port() { # CACHE PORT LOGFILE TANGD
    local cache="$1" port="$2" log_file="$3" tangd="$4" pid

    # Bind to 127.0.0.1 only, so the temporary unauthenticated tangd is
    # not reachable from other machines when the test host is networked.
    if [ -n "$log_file" ]; then
        nohup socat "tcp4-listen:$port,bind=127.0.0.1,reuseaddr,fork" \
            exec:"$tangd $cache" >"$log_file" 2>&1 &
    else
        nohup socat "tcp4-listen:$port,bind=127.0.0.1,reuseaddr,fork" \
            exec:"$tangd $cache" >/dev/null 2>&1 &
    fi
    pid=$!

    if ! rlWaitForSocket "$port" -p "$pid"; then
        rlLogFatal "tangd failed to start on port $port" 1>&2
        kill "$pid" 2>/dev/null || :
        wait "$pid" 2>/dev/null || :
        return 1
    fi

    _tang_http_remember_pid "$port" "$pid"
    TANG_HTTP_PORT="$port"
    rlLogInfo "started tangd $cache as pid $pid on 127.0.0.1:$port" 1>&2
    [ ! -t 1 ] && echo "$port"
    return 0
}

# Starts a plain-HTTP tangd listener. The key database/cache ($1) must
# already exist. Optional arguments: an explicit port ($2) and a log file
# ($3). The chosen port is echoed (so port=$(start_tang_http ...) works)
# and also stored in the global TANG_HTTP_PORT.
#
# Call this helper DIRECTLY (start_tang_http dir; port=$TANG_HTTP_PORT)
# rather than inside a command substitution: $(...) runs the helper in a
# subshell, which discards the PID bookkeeping stop_tang_http relies on
# and forces it back onto the by-port fallback.
start_tang_http() {
    local cache="$1" requested_port="${2:-}" log_file="${3:-}"
    local port tangd attempt

    tangd="$(command -v tangd 2>/dev/null || true)"
    [ -n "$tangd" ] || tangd=/usr/libexec/tangd
    if [ ! -x "$tangd" ]; then
        rlLogFatal "tangd executable not found" 1>&2
        return 1
    fi

    if [ -n "$requested_port" ]; then
        if fuser -s -n tcp "$requested_port" 2>/dev/null; then
            rlLogFatal "Tang port $requested_port is already in use" 1>&2
            return 1
        fi
        _start_tang_http_on_port "$cache" "$requested_port" "$log_file" "$tangd"
        return $?
    fi

    # Ephemeral port instead of a fixed-range scan: no collisions
    # between concurrent test runs racing over the same port range.
    # There is a small window between _tang_free_port releasing the
    # socket and socat binding it; if another process grabs the port
    # in that window, retry with a fresh one instead of failing.
    for attempt in 1 2 3; do
        port="$(_tang_free_port)" || return 1
        if _start_tang_http_on_port "$cache" "$port" "$log_file" "$tangd"; then
            return 0
        fi
        rlLogInfo "tangd failed to bind ephemeral port $port (attempt $attempt); retrying" 1>&2
    done
    rlLogFatal "tangd failed to start on an ephemeral port after $attempt attempts" 1>&2
    return 1
}

# Stops a tangd started by start_tang_http. Kills only the socat listener
# this test started for that port; when no listener of ours is recorded
# for the port (e.g. the starter ran inside a command substitution), it
# falls back to killing whatever listens on the port, matching the
# historical fuser-based behavior.
stop_tang_http() {
    local port="$1" pid

    if pid="$(_tang_http_pid_for "$port")"; then
        if kill -0 "$pid" 2>/dev/null; then
            rlRun "kill $pid" 0 "Stopping tangd pid $pid on port $port"
            wait "$pid" 2>/dev/null || :
        fi
        return 0
    fi

    rlLogWarning "no tangd PID recorded for port $port; falling back to fuser" 1>&2
    fuser -s -k "$port/tcp" 2>/dev/null
    return 0
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Tang fault-injection proxy (shared)
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Starts the shared tang fault-injection proxy (tang-fault-proxy.py, next
# to this file) in front of an already-running tangd. Usage:
#   start_tang_fault_proxy UPSTREAM_URL [FAKE_KEY_FILE]
# Sets TANG_PROXY_URL, TANG_PROXY_PORT, TANG_PROXY_PID, TANG_PROXY_MODE_FILE
# and TANG_PROXY_EVENTS. Faults are enabled by writing comma-separated
# mode names to ${TANG_PROXY_MODE_FILE}; see tang-fault-proxy.py for the
# list. The events file records every forwarded request ("METHOD /path").
# FAKE_KEY_FILE is only needed for the tamper-tang-pub mode.
#
# Call this helper DIRECTLY, not inside a command substitution: the
# globals it sets would be lost in a subshell.
start_tang_fault_proxy() {
    local upstream="$1" fake_key="${2:-}" i

    TANG_PROXY_DIR="$(mktemp -d)" || return 1
    TANG_PROXY_MODE_FILE="${TANG_PROXY_DIR}/mode"
    TANG_PROXY_PORT_FILE="${TANG_PROXY_DIR}/port"
    TANG_PROXY_EVENTS="${TANG_PROXY_DIR}/events"
    printf 'passthrough\n' > "${TANG_PROXY_MODE_FILE}"

    python3 "${_TANG_HELPERS_DIR}/tang-fault-proxy.py" "$upstream" \
        "${TANG_PROXY_MODE_FILE}" "${TANG_PROXY_PORT_FILE}" \
        "${TANG_PROXY_EVENTS}" $([ -n "$fake_key" ] && printf %s "$fake_key") \
        > "${TANG_PROXY_DIR}/proxy.log" 2>&1 &
    TANG_PROXY_PID=$!

    for i in {1..30}; do
        [ -s "${TANG_PROXY_PORT_FILE}" ] && break
        kill -0 "${TANG_PROXY_PID}" 2>/dev/null || break
        sleep 1
    done
    if [ ! -s "${TANG_PROXY_PORT_FILE}" ]; then
        rlLogFatal "tang fault proxy did not start; log: $(cat "${TANG_PROXY_DIR}/proxy.log" 2>/dev/null)" 1>&2
        kill "${TANG_PROXY_PID}" 2>/dev/null || :
        rm -rf "${TANG_PROXY_DIR}"
        return 1
    fi

    TANG_PROXY_PORT="$(<"${TANG_PROXY_PORT_FILE}")"
    TANG_PROXY_URL="http://localhost:${TANG_PROXY_PORT}"
    rlLogInfo "started tang fault proxy as pid ${TANG_PROXY_PID} on ${TANG_PROXY_URL}" 1>&2
    return 0
}

# Stops the fault proxy started by start_tang_fault_proxy and removes its
# temporary directory (mode/port/events files and the proxy log).
stop_tang_fault_proxy() {
    if [ -n "${TANG_PROXY_PID:-}" ] && kill -0 "${TANG_PROXY_PID}" 2>/dev/null; then
        rlRun "kill \${TANG_PROXY_PID}" 0 "Stopping the tang fault proxy"
        wait "${TANG_PROXY_PID}" 2>/dev/null || :
    fi
    [ -n "${TANG_PROXY_DIR:-}" ] && rm -rf "${TANG_PROXY_DIR}"
    TANG_PROXY_PID=""
    TANG_PROXY_DIR=""
    return 0
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Clevis LUKS binding inspection (shared)
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Extract the clevis JWE (general JSON format) from the LUKS2 token
# metadata of device $1 into file $2. `clevis luks list` prints only the
# pin name and config — the JWE protected header is where a stored Tang
# advertisement (clevis.tang.adv) actually lives, so binding assertions
# must run against this, not against the luks list output.
save_clevis_jwe() {
    cryptsetup luksDump --dump-json-metadata "$1" \
        | jq -er '.tokens[] | select(.type == "clevis") | .jwe' > "$2"
}

# Decode the protected header of the general-format JWE file in $1 into
# the file $2.
save_jwe_header() {
    jq -j '.protected' "$1" | jose b64 dec -i- > "$2"
}

# Asserts that the base64-decoded content of FILE ($2) contains STRING
# ($1). On failure the decoded content is printed to the test log, which
# makes payload mismatches easier to diagnose than a bare grep failure.
grep_b64() {
    rlRun "jose b64 dec -i \"$2\" -O - | grep -q \"$1\"" 0 "File '$2' should contain '$1' when b64-decrypted" || jose b64 dec -i "$2" -O -
}
