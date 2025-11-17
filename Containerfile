FROM gentoo/portage:latest as portage
#FROM gentoo/stage3-amd64-systemd:latest
#FROM gentoo/stage3:latest
ARG TARGET_ARCH
ARG TARGET_FLAVOUR
LABEL maintainer="Björn Busse <bj.rn@baerlin.eu>"
LABEL org.opencontainers.image.source=https://github.com/bbusse/linux-kernel-build

# Copy portage volume
COPY --from=portage /var/db/repos/gentoo /var/db/repos/gentoo

RUN mkdir -p /etc/portage/package.use && \
    mkdir -p /etc/portage/package.unmask

COPY emerge.sh /usr/local/bin
COPY gentoo-config/make.conf /etc/portage/
COPY gentoo-config/package.use /etc/portage/package.use/
COPY gentoo-config/package.unmask/* /etc/portage/package.unmask/
COPY gentoo-config/package.accept_keywords /etc/portage/package.accept_keywords/
ADD gentoo-config/sets /etc/portage/sets

# Build
# https://bugs.gentoo.org/878489
RUN mkdir /gentoo && cd /gentoo && \
    curl -LO https://mirror.netcologne.de/gentoo/releases/amd64/autobuilds/current-stage3-amd64-nomultilib-systemd/stage3-amd64-nomultilib-systemd-20251116T161545Z.tar.xz && \
    tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner -C /gentoo && \
    rm -rf /.git || printf "No .git in /\n" && \
    rm -rf /var/.git || printf "No .git in /var\n" && \
    rm -rf /var/tmp/.git || printf "No .git in /var/tmp\n" && \
    emerge.sh "${TARGET_FLAVOUR}" && \
    tar -cJf /gentoo-stage4-sway-${TARGET_ARCH}.tar.xz /var/cache/binpkgs && \
    sha384sum /gentoo-stage4-sway-${TARGET_ARCH}.tar.xz > /gentoo-stage4-sway-${TARGET_ARCH}.tar.xz.sha384 && \
    cp /gentoo-stage4-sway-${TARGET_ARCH}.tar.xz /output && \
    cp /gentoo-stage4-sway-${TARGET_ARCH}.tar.xz.sha384 /output
