#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: Björn Busse <bj.rn@baerlin.eu>
# SPDX-License-Identifier: BSD-3-Clause
#
# Boots the built gentoo-containeros disk image under QEMU and verifies it
# reaches a console login prompt and that we can log in as root.
#
# CI runners have no /dev/kvm, so this boots under TCG (software emulation)
# rather than KVM - expect it to be slow. BOOT_TIMEOUT/LOGIN_TIMEOUT below
# are first-pass guesses and will likely need tuning once we see real
# timing from an actual run.
#
# The VM itself is launched by the repo's ./run script, so this exercises the
# same launcher developers use locally rather than a second copy of the qemu
# invocation. RUN_SCRIPT points at it; ARCH selects which image to boot.

QEMU_ARCH="${QEMU_ARCH:-amd64}"
DISK_IMAGE="${DISK_IMAGE:-gentoo-containeros-${QEMU_ARCH}.raw}"
RUN_SCRIPT="${RUN_SCRIPT:-./run}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"
LOGIN_TIMEOUT="${LOGIN_TIMEOUT:-60}"
ROOT_PASSWORD="gentoo"

QEMU_PID=""
SERIAL_DIR=""
SERIAL_LOG=""
QEMU_LOG=""
PIPE_BASE=""
READER_PID=""

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
    if [ ! -x "$RUN_SCRIPT" ]; then
        fail "Launcher not found or not executable: $RUN_SCRIPT (set RUN_SCRIPT to override)"
    fi

    SERIAL_DIR="$(mktemp -d)"
    SERIAL_LOG="${SERIAL_DIR}/console.log"
    QEMU_LOG="${SERIAL_DIR}/qemu.log"
    PIPE_BASE="${SERIAL_DIR}/serial"

    mkfifo "${PIPE_BASE}.in" "${PIPE_BASE}.out"
    : >"$SERIAL_LOG"

    # Open both FIFO ends read-write from our side before qemu starts.
    # A plain open() on a FIFO blocks until a peer opens the other end;
    # opening O_RDWR bypasses that, so neither we nor qemu (started after)
    # ever deadlock waiting for the other to attach first.
    exec 3<>"${PIPE_BASE}.in"
    exec 4<>"${PIPE_BASE}.out"

    # Drain the .out side into a plain file we can grep/tail freely
    cat <&4 >>"$SERIAL_LOG" &
    READER_PID=$!

    ARCH="$QEMU_ARCH" \
        DISK_IMAGE="$DISK_IMAGE" \
        SERIAL_PIPE="$PIPE_BASE" \
        QEMU_NET=user \
        "$RUN_SCRIPT" >"$QEMU_LOG" 2>&1 &
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
        echo "----- run/qemu output -----"
        cat "$QEMU_LOG"
        echo "----- end run/qemu output -----"
    fi
    if [ -n "$SERIAL_LOG" ] && [ -f "$SERIAL_LOG" ]; then
        echo "----- guest serial console -----"
        cat "$SERIAL_LOG"
        echo "----- end guest serial console -----"
    fi
    [ -n "$SERIAL_DIR" ] && rm -rf "$SERIAL_DIR"
}
