#!/bin/bash

# Redirect stdout/stderr to console and log for debugging
exec >/dev/kmsg 2>&1
echo "initramfs: Running 90luks-loop.sh hook..."
echo "initramfs: Current working directory: $(pwd)"
echo "initramfs: Listing root content:"
ls -F /
ls -l /var/opt/ || true # List contents of /var/opt in initramfs

# Define the persistent loopfile location, consistent with runtest.sh
PERSISTENT_LOOPFILE="/var/opt/loopfile"

# Check if the persistent loopfile actually exists in initramfs
if [ -f "${PERSISTENT_LOOPFILE}" ]; then
    echo "initramfs: ${PERSISTENT_LOOPFILE} found. Attempting losetup."
    # Create the loop device. It will find a free /dev/loopX.
    LDEV=$(losetup -f --show "${PERSISTENT_LOOPFILE}")
    if [ -n "$LDEV" ]; then
        echo "initramfs: losetup done: $LDEV for ${PERSISTENT_LOOPFILE}"
        # Important: Inform udev that a new block device is ready.
        # This is critical for systemd-cryptsetup to see it.
        udevadm settle --timeout=30 # Increased udev settle timeout
        udevadm trigger --action=add --subsystem=block
        echo "initramfs: udevadm done. Current devices:"
        ls -l /dev/loop* || true
        ls -l /dev/mapper/ || true
    else
        echo "initramfs: ERROR: losetup failed for ${PERSISTENT_LOOPFILE}!"
    fi
else
    echo "initramfs: ERROR: ${PERSISTENT_LOOPFILE} not found in initramfs at all!"
fi