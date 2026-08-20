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

# Register any overlays needed by the sets above (e.g. x11-misc/vju for
# @sway lives in bbusse-overlay, not the main tree) - space separated
# repo URLs. git isn't installed at this point in the base image, so
# fetch a tarball of the default branch the same way gentoo-config is
# fetched above, rather than git clone. The repos.conf section name
# must match the repo's own profiles/repo_name (Portage silently
# ignores the repo otherwise), which doesn't necessarily match the
# URL's basename - read it from the fetched tree instead of guessing
ARG GENTOO_OVERLAYS=""
RUN mkdir -p /etc/portage/repos.conf && \
    for url in ${GENTOO_OVERLAYS}; do \
        url_name="$(basename "${url%.git}")" && \
        curl -L "${url}/archive/refs/heads/main.tar.gz" | tar -xzf - -C /tmp && \
        name="$(cat /tmp/"${url_name}"-main/profiles/repo_name)" && \
        mv /tmp/"${url_name}"-main /var/db/repos/"${name}" && \
        printf '[%s]\nlocation = /var/db/repos/%s\nsync-type = git\nsync-uri = %s\nauto-sync = yes\n' \
            "${name}" "${name}" "${url}" > /etc/portage/repos.conf/"${name}".conf; \
    done

# Build
RUN rm -rf /.git || printf "No .git in /\n" && \
    rm -rf /var/.git || printf "No .git in /var\n" && \
    rm -rf /var/tmp/.git || printf "No .git in /var/tmp\n" && \
    emerge.sh "${TARGET_FLAVOUR}" && \
    tar -cJf /gentoo-stage4-${TARGET_FLAVOUR}-${TARGET_ARCH}.tar.xz /var/cache/binpkgs && \
    sha384sum /gentoo-stage4-${TARGET_FLAVOUR}-${TARGET_ARCH}.tar.xz > /gentoo-stage4-${TARGET_FLAVOUR}-${TARGET_ARCH}.tar.xz.sha384 && \
    cp /gentoo-stage4-${TARGET_FLAVOUR}-${TARGET_ARCH}.tar.xz /output && \
    cp /gentoo-stage4-${TARGET_FLAVOUR}-${TARGET_ARCH}.tar.xz.sha384 /output
