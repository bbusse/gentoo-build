FROM gentoo/portage:latest as portage
#FROM gentoo/stage3-amd64-systemd:latest
FROM gentoo/stage3:systemd
ARG TARGET_ARCH
ARG TARGET_FLAVOUR
LABEL maintainer="Björn Busse <bj.rn@baerlin.eu>"
LABEL org.opencontainers.image.source=https://github.com/bbusse/gentoo-build

# Copy portage volume
COPY --from=portage /var/db/repos/gentoo /var/db/repos/gentoo

RUN mkdir -p /etc/portage/package.use && \
    mkdir -p /etc/portage/package.unmask

COPY emerge.sh /usr/local/bin

# Fetch portage config from the separate gentoo-config repo
ARG GENTOO_CONFIG_REF=main
RUN curl -L "https://github.com/bbusse/gentoo-config/archive/refs/heads/${GENTOO_CONFIG_REF}.tar.gz" | \
        tar -xzf - -C /tmp && \
    mv /tmp/gentoo-config-${GENTOO_CONFIG_REF} /tmp/gentoo-config && \
    cp /tmp/gentoo-config/make.conf /etc/portage/ && \
    cp /tmp/gentoo-config/package.use /etc/portage/package.use/ && \
    cp /tmp/gentoo-config/package.unmask/* /etc/portage/package.unmask/ && \
    cp /tmp/gentoo-config/package.accept_keywords /etc/portage/package.accept_keywords/ && \
    cp -r /tmp/gentoo-config/sets /etc/portage/sets && \
    rm -rf /tmp/gentoo-config

# Build
RUN rm -rf /.git || printf "No .git in /\n" && \
    rm -rf /var/.git || printf "No .git in /var\n" && \
    rm -rf /var/tmp/.git || printf "No .git in /var/tmp\n" && \
    emerge.sh "${TARGET_FLAVOUR}" && \
    tar -cJf /gentoo-stage4-${TARGET_FLAVOUR}-${TARGET_ARCH}.tar.xz /var/cache/binpkgs && \
    sha384sum /gentoo-stage4-${TARGET_FLAVOUR}-${TARGET_ARCH}.tar.xz > /gentoo-stage4-${TARGET_FLAVOUR}-${TARGET_ARCH}.tar.xz.sha384 && \
    cp /gentoo-stage4-${TARGET_FLAVOUR}-${TARGET_ARCH}.tar.xz /output && \
    cp /gentoo-stage4-${TARGET_FLAVOUR}-${TARGET_ARCH}.tar.xz.sha384 /output
