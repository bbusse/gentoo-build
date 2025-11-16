#!/usr/bin/env bash

set -eo pipefail

main() {
    local target_flavour
    target_flavour="${1}"

    printf "Building gentoo flavour: %s\n" "${target_flavour}"

    case "${target_flavour}" in
    containeros)
        emerge -qv \
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
