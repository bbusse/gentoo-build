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
        # Real hardware, unlike sway-virt: build mesa with the Gallium
        # driver each supported SoC needs. One rootfs serves every board of
        # an arch (gentoo-sway-pine64 reuses this rootfs and only swaps the
        # kernel), so the arm64 file carries lima and panfrost together
        # while amd64 gets the Intel driver
        case "$(uname -m)" in
        aarch64 | arm64)
            cp /etc/portage/package.use.hwaccel /etc/portage/package.use/
            ;;
        x86_64 | amd64)
            cp /etc/portage/package.use.hwaccel-amd64 /etc/portage/package.use/
            ;;
        *)
            printf 'No hwaccel USE flags for %s, mesa will be swrast-only\n' \
                "$(uname -m)" >&2
            ;;
        esac

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
    sway-virt)
         emerge -qv \
             --jobs "${emerge_jobs}" \
             --load-average "${emerge_load}" \
               --buildpkg \
               --buildpkg-exclude \
               "virtual/* \
               sys-kernel/*-sources" \
               @dev \
               @dev-lang \
               @sway-virt \
               @essentials \
               @virt \
               @net
        ;;
    k3s)
         emerge -qv \
             --jobs "${emerge_jobs}" \
             --load-average "${emerge_load}" \
               --buildpkg \
               --buildpkg-exclude \
               "virtual/* \
               sys-kernel/*-sources" \
               @k8s \
               @essentials \
               @net
        ;;
    esac
}

main "$@"
