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
# The disk uses a q35/GPT/EFI layout (see image-builder's gentoo_create_disk),
# so boot needs OVMF firmware (the "ovmf" package on Debian/Ubuntu) and an
# AHCI-attached disk - q35 has no legacy IDE controller, and we don't know
# whether the custom kernel (bbusse/linux-build) has virtio-blk built in,
# so AHCI (near-universally supported by generic x86_64 kernels) is the
# safer default over virtio.

DISK_IMAGE="${DISK_IMAGE:-gentoo-containeros.raw}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"
LOGIN_TIMEOUT="${LOGIN_TIMEOUT:-60}"
ROOT_PASSWORD="gentoo"

QEMU_PID=""
SERIAL_DIR=""
SERIAL_LOG=""
PIPE_BASE=""
READER_PID=""
OVMF_VARS_COPY=""

find_ovmf_code() {
    local candidate
    for candidate in \
        /usr/share/OVMF/OVMF_CODE_4M.fd \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/ovmf/OVMF.fd \
        /usr/share/qemu/OVMF.fd
    do
        [ -f "$candidate" ] && { printf '%s' "$candidate"; return 0; }
    done
    return 1
}

find_ovmf_vars() {
    local candidate
    for candidate in \
        /usr/share/OVMF/OVMF_VARS_4M.fd \
        /usr/share/OVMF/OVMF_VARS.fd
    do
        [ -f "$candidate" ] && { printf '%s' "$candidate"; return 0; }
    done
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

    local ovmf_code
    ovmf_code=$(find_ovmf_code) || \
        fail "OVMF firmware (OVMF_CODE*.fd) not found - is the 'ovmf' package installed?"
    local ovmf_vars_src
    ovmf_vars_src=$(find_ovmf_vars) || \
        fail "OVMF vars template (OVMF_VARS*.fd) not found - is the 'ovmf' package installed?"

    SERIAL_DIR="$(mktemp -d)"
    SERIAL_LOG="${SERIAL_DIR}/console.log"
    PIPE_BASE="${SERIAL_DIR}/serial"
    OVMF_VARS_COPY="${SERIAL_DIR}/OVMF_VARS.fd"

    mkfifo "${PIPE_BASE}.in" "${PIPE_BASE}.out"
    cp "$ovmf_vars_src" "$OVMF_VARS_COPY"
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

    qemu-system-x86_64 \
        -m 2048 \
        -machine q35,accel=tcg \
        -cpu qemu64 \
        -nographic \
        -no-reboot \
        -nic user,model=virtio-net-pci \
        -serial pipe:"${PIPE_BASE}" \
        -drive if=pflash,format=raw,readonly=on,file="${ovmf_code}" \
        -drive if=pflash,format=raw,file="${OVMF_VARS_COPY}" \
        -drive if=none,format=raw,file="${DISK_IMAGE}",id=disk0 \
        -device ahci,id=ahci0 \
        -device ide-hd,drive=disk0,bus=ahci0.0 \
        >/dev/null 2>&1 &
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
    [ -n "$SERIAL_DIR" ] && rm -rf "$SERIAL_DIR"
}
