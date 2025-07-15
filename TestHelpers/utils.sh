#!/bin/bash

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
