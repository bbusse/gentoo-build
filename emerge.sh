#!/usr/bin/env bash

set -eo pipefail

main() {
    local target_flavour
    target_flavour="${1}"

    # Parallelization knobs (override via env): EMERGE_JOBS/EMERGE_LOAD and MAKEOPTS
    local emerge_jobs
    emerge_jobs="${EMERGE_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)}"
    local emerge_load
    emerge_load="${EMERGE_LOAD:-${emerge_jobs}}"
    # Respect existing MAKEOPTS, else set a sane default
    export MAKEOPTS="${MAKEOPTS:--j${emerge_jobs}}"

    printf "Building gentoo flavour: %s\n" "${target_flavour}"

    case "${target_flavour}" in
    containeros)
         emerge -qv \
             --jobs "${emerge_jobs}" \
             --load-average "${emerge_load}" \
               --buildpkg \
               --buildpkg-exclude \
               "virtual/* \
               sys-kernel/*-sources" \
               @container-podman \
               @essentials \
               @net
        ;;
    sway)
         emerge -qv \
             --jobs "${emerge_jobs}" \
             --load-average "${emerge_load}" \
               --buildpkg \
               --buildpkg-exclude \
               "virtual/* \
               sys-kernel/*-sources" \
               @dev \
               @dev-lang \
               @sway \
               @essentials \
               @virt \
               @net
        ;;
    esac
}

main "$@"
