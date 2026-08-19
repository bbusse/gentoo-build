#!/usr/bin/env bash
#
# Boots the built gentoo-containeros disk image under QEMU and verifies it
# reaches a console login prompt and that we can log in as root.
#
# CI runners have no /dev/kvm, so this boots under TCG (software emulation)
# rather than KVM - expect it to be slow. BOOT_TIMEOUT/LOGIN_TIMEOUT below
# are first-pass guesses and will likely need tuning once we see real
# timing from an actual run.
#
# QEMU_ARCH picks the machine: amd64 uses q35/AHCI + OVMF (q35 has no legacy
# IDE controller, and AHCI is the safer default over virtio for a generic
# x86_64 kernel); arm64 uses the "virt" machine + virtio-blk + AAVMF (virt
# has no AHCI/IDE controller at all, and the arm64-vm kernel config was
# built specifically with CONFIG_VIRTIO_BLK for this machine type).

QEMU_ARCH="${QEMU_ARCH:-amd64}"
DISK_IMAGE="${DISK_IMAGE:-gentoo-containeros-${QEMU_ARCH}.raw}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"
LOGIN_TIMEOUT="${LOGIN_TIMEOUT:-60}"
ROOT_PASSWORD="gentoo"

QEMU_PID=""
SERIAL_DIR=""
SERIAL_LOG=""
QEMU_LOG=""
PIPE_BASE=""
READER_PID=""
FIRMWARE_VARS_COPY=""

find_firmware_code() {
    local candidate
    case "$QEMU_ARCH" in
    arm64)
        for candidate in \
            /usr/share/AAVMF/AAVMF_CODE.fd \
            /usr/share/qemu-efi-aarch64/QEMU_EFI.fd
        do
            [ -f "$candidate" ] && { printf '%s' "$candidate"; return 0; }
        done
        ;;
    *)
        for candidate in \
            /usr/share/OVMF/OVMF_CODE_4M.fd \
            /usr/share/OVMF/OVMF_CODE.fd \
            /usr/share/ovmf/OVMF.fd \
            /usr/share/qemu/OVMF.fd
        do
            [ -f "$candidate" ] && { printf '%s' "$candidate"; return 0; }
        done
        ;;
    esac
    return 1
}

find_firmware_vars() {
    local candidate
    case "$QEMU_ARCH" in
    arm64)
        for candidate in \
            /usr/share/AAVMF/AAVMF_VARS.fd \
            /usr/share/qemu-efi-aarch64/QEMU_VARS.fd
        do
            [ -f "$candidate" ] && { printf '%s' "$candidate"; return 0; }
        done
        ;;
    *)
        for candidate in \
            /usr/share/OVMF/OVMF_VARS_4M.fd \
            /usr/share/OVMF/OVMF_VARS.fd
        do
            [ -f "$candidate" ] && { printf '%s' "$candidate"; return 0; }
        done
        ;;
    esac
    return 1
}

# Send a line of input to the guest's serial console
send_line() {
    printf '%s\r' "$1" >&3
}

# Poll the captured serial log for a pattern, up to a timeout (seconds).
# Bails out early if qemu has already exited (nothing left to wait for).
wait_for_pattern() {
    local pattern="$1"
    local timeout="$2"
    local waited=0

    while [ "$waited" -lt "$timeout" ]; do
        if grep -qE "$pattern" "$SERIAL_LOG" 2>/dev/null; then
            return 0
        fi
        if [ -n "$QEMU_PID" ] && ! kill -0 "$QEMU_PID" 2>/dev/null; then
            return 1
        fi
        sleep 2
        waited=$((waited + 2))
    done
    return 1
}

setup_suite() {
    if [ ! -f "$DISK_IMAGE" ]; then
        fail "Disk image not found: $DISK_IMAGE (set DISK_IMAGE to override)"
    fi

    local firmware_code
    firmware_code=$(find_firmware_code) || \
        fail "UEFI firmware not found for arch '${QEMU_ARCH}' - is the 'ovmf' (amd64) or 'qemu-efi-aarch64' (arm64) package installed?"
    local firmware_vars_src
    firmware_vars_src=$(find_firmware_vars) || \
        fail "UEFI vars template not found for arch '${QEMU_ARCH}' - is the 'ovmf' (amd64) or 'qemu-efi-aarch64' (arm64) package installed?"

    SERIAL_DIR="$(mktemp -d)"
    SERIAL_LOG="${SERIAL_DIR}/console.log"
    QEMU_LOG="${SERIAL_DIR}/qemu.log"
    PIPE_BASE="${SERIAL_DIR}/serial"
    FIRMWARE_VARS_COPY="${SERIAL_DIR}/FIRMWARE_VARS.fd"

    mkfifo "${PIPE_BASE}.in" "${PIPE_BASE}.out"
    cp "$firmware_vars_src" "$FIRMWARE_VARS_COPY"
    : > "$SERIAL_LOG"

    # Open both FIFO ends read-write from our side before qemu starts.
    # A plain open() on a FIFO blocks until a peer opens the other end;
    # opening O_RDWR bypasses that, so neither we nor qemu (started after)
    # ever deadlock waiting for the other to attach first.
    exec 3<>"${PIPE_BASE}.in"
    exec 4<>"${PIPE_BASE}.out"

    # Drain the .out side into a plain file we can grep/tail freely
    cat <&4 >>"$SERIAL_LOG" &
    READER_PID=$!

    local qemu_bin qemu_machine qemu_cpu
    local -a disk_device_args
    case "$QEMU_ARCH" in
    arm64)
        qemu_bin="qemu-system-aarch64"
        qemu_machine="virt,accel=tcg"
        qemu_cpu="max"
        disk_device_args=(-device "virtio-blk-pci,drive=disk0")
        ;;
    *)
        qemu_bin="qemu-system-x86_64"
        qemu_machine="q35,accel=tcg"
        qemu_cpu="qemu64"
        disk_device_args=(-device "ahci,id=ahci0" -device "ide-hd,drive=disk0,bus=ahci0.0")
        ;;
    esac

    "$qemu_bin" \
        -m 2048 \
        -machine "$qemu_machine" \
        -cpu "$qemu_cpu" \
        -nographic \
        -no-reboot \
        -nic user,model=virtio-net-pci \
        -serial pipe:"${PIPE_BASE}" \
        -drive if=pflash,format=raw,readonly=on,file="${firmware_code}" \
        -drive if=pflash,format=raw,file="${FIRMWARE_VARS_COPY}" \
        -drive if=none,format=raw,file="${DISK_IMAGE}",id=disk0 \
        "${disk_device_args[@]}" \
        >"$QEMU_LOG" 2>&1 &
    QEMU_PID=$!
}

# bash_unit enumerates test_* functions via `set`, which lists them
# alphabetically rather than in file order - these are numbered so
# alphabetical order matches the required boot -> login -> shell sequence
test_01_disk_image_boots_to_login_prompt() {
    assert "wait_for_pattern '[Ll]ogin:' ${BOOT_TIMEOUT}" \
        "Console should reach a login prompt within ${BOOT_TIMEOUT}s"
}

test_02_can_log_in_as_root() {
    send_line "root"
    assert "wait_for_pattern '[Pp]assword:' ${LOGIN_TIMEOUT}" \
        "Console should prompt for a password after entering the username"

    send_line "$ROOT_PASSWORD"
    assert "wait_for_pattern 'Last login|# \$' ${LOGIN_TIMEOUT}" \
        "Should reach a root shell prompt after logging in"
}

test_03_shell_is_interactive() {
    local marker="BOOT_TEST_OK_$$"
    send_line "echo ${marker}"
    assert "wait_for_pattern '${marker}' 30" \
        "Shell should echo back a command we send, confirming an interactive session"
}

teardown_suite() {
    [ -n "$READER_PID" ] && kill "$READER_PID" 2>/dev/null
    exec 3<&- 2>/dev/null
    exec 4<&- 2>/dev/null
    if [ -n "$QEMU_PID" ]; then
        kill "$QEMU_PID" 2>/dev/null
        wait "$QEMU_PID" 2>/dev/null
    fi
    if [ -n "$QEMU_LOG" ] && [ -s "$QEMU_LOG" ]; then
        echo "----- qemu stderr -----"
        cat "$QEMU_LOG"
        echo "----- end qemu stderr -----"
    fi
    if [ -n "$SERIAL_LOG" ] && [ -f "$SERIAL_LOG" ]; then
        echo "----- guest serial console -----"
        cat "$SERIAL_LOG"
        echo "----- end guest serial console -----"
    fi
    [ -n "$SERIAL_DIR" ] && rm -rf "$SERIAL_DIR"
}
