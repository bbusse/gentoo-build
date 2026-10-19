#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: Björn Busse <bj.rn@baerlin.eu>
# SPDX-License-Identifier: BSD-3-Clause
#

QEMU_ARCH="${QEMU_ARCH:-amd64}"
DISK_IMAGE="${DISK_IMAGE:-gentoo-containeros-${QEMU_ARCH}.raw}"
RUN_SCRIPT="${RUN_SCRIPT:-./run}"
ENTRY_TIMEOUT="${ENTRY_TIMEOUT:-300}"
export MTOOLS_SKIP_CHECK=1

ESP=""
WORK=""

esp_offset() {
    sfdisk -d "${1}" | awk 'toupper($0) ~ /C12A7328-F81F-11D2-BA4B-00A0C93EC93B/ {
        if (match($0, /start= *[0-9]+/)) {
            s = substr($0, RSTART, RLENGTH)
            gsub(/[^0-9]/, "", s)
            print s * 512
            exit
        }
    }'
}

entry_pattern() {
    case "${1}" in
    nomadbsd) echo "FreeBSD" ;;
    refind) echo "rEFInd - Main Menu" ;;
    u-root) echo "u-root" ;;
    *) echo "[Ll]ogin:" ;;
    esac
}

boot_entry() {
    local entry
    entry="${1}"
    local log
    log="${WORK}/${entry}.log"

    printf 'default %s.conf\ntimeout 0\nconsole-mode keep\neditor no\n' "${entry}" >"${WORK}/loader.conf"
    mcopy -o -i "${ESP}" "${WORK}/loader.conf" ::/loader/loader.conf

    rm -f "${WORK}/serial.in" "${WORK}/serial.out"
    mkfifo "${WORK}/serial.in" "${WORK}/serial.out"
    exec 3<>"${WORK}/serial.in"
    exec 4<>"${WORK}/serial.out"
    : >"${log}"
    cat <&4 >>"${log}" &
    local reader
    reader=$!

    ARCH="${QEMU_ARCH}" \
        DISK_IMAGE="${DISK_IMAGE}" \
        SERIAL_PIPE="${WORK}/serial" \
        QEMU_NET=none \
        "${RUN_SCRIPT}" >"${WORK}/${entry}.qemu.log" 2>&1 &
    local qemu
    qemu=$!

    local pattern
    pattern="$(entry_pattern "${entry}")"
    local waited
    waited=0
    local ok
    ok=1
    while [ "${waited}" -lt "${ENTRY_TIMEOUT}" ]; do
        if grep -qaE "${pattern}" "${log}"; then
            ok=0
            break
        fi
        if ! kill -0 "${qemu}" 2>/dev/null; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done

    pkill -P "${qemu}" 2>/dev/null
    kill "${qemu}" 2>/dev/null
    wait "${qemu}" 2>/dev/null
    kill "${reader}" 2>/dev/null
    exec 3<&- 4<&-

    if [ "${ok}" -ne 0 ]; then
        printf -- '----- %s serial console -----\n' "${entry}"
        tr -c '[:print:]\n' ' ' <"${log}" | tail -40
        printf -- '----- %s run/qemu output -----\n' "${entry}"
        tail -20 "${WORK}/${entry}.qemu.log"
        printf -- '----- end %s -----\n' "${entry}"
    fi
    return "${ok}"
}

setup_suite() {
    if [ ! -f "${DISK_IMAGE}" ]; then
        fail "Disk image not found: ${DISK_IMAGE} (set DISK_IMAGE to override)"
    fi

    local offset
    offset="$(esp_offset "${DISK_IMAGE}")"
    if [ -z "${offset}" ]; then
        fail "No ESP in ${DISK_IMAGE}"
    fi
    ESP="${DISK_IMAGE}@@${offset}"

    WORK="$(mktemp -d)"
    mtype -i "${ESP}" ::/loader/loader.conf >"${WORK}/loader.conf.orig"
}

test_every_boot_entry_reaches_its_system() {
    local default
    default="$(awk '$1 == "default" { sub(/\.conf$/, "", $2); print $2 }' "${WORK}/loader.conf.orig")"

    local entries
    entries="$(mdir -b -i "${ESP}" ::/loader/entries | awk -F/ '/\.conf$/ { sub(/\.conf$/, "", $NF); print $NF }')"
    assert "test -n '${entries}'" "the ESP carries boot entries"

    local failed
    failed=""
    local entry
    for entry in ${entries}; do
        if [ "${entry}" = "${default}" ]; then
            continue
        fi
        printf 'boot entry %s: waiting for /%s/\n' "${entry}" "$(entry_pattern "${entry}")"
        if ! boot_entry "${entry}"; then
            failed="${failed} ${entry}"
        fi
    done

    assert_equals "" "${failed}" "every entry besides the default reaches its system"
}

teardown_suite() {
    if [ -n "${WORK}" ] && [ -s "${WORK}/loader.conf.orig" ]; then
        mcopy -o -i "${ESP}" "${WORK}/loader.conf.orig" ::/loader/loader.conf
    fi
    [ -n "${WORK}" ] && rm -rf "${WORK}"
}
