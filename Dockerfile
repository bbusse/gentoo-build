FROM gentoo/portage:latest as portage
FROM gentoo/stage3:latest

# Copy portage volume
COPY --from=portage /var/db/repos/gentoo /var/db/repos/gentoo

RUN mkdir -p /etc/portage/package.use && \
    mkdir -p /etc/portage/package.unmask

COPY make.conf /etc/portage/
COPY package.use /etc/portage/package.use/
COPY package.unmask/* /etc/portage/package.unmask/
COPY package.accept_keywords /etc/portage/package.accept_keywords/
ADD sets /etc/portage/sets

# Build
# https://bugs.gentoo.org/878489
RUN rm -rf /.git || printf "No .git in /\n" && \
    rm -rf /var/.git || printf "No .git in /var\n" && \
    rm -rf /var/tmp/.git || printf "No .git in /var/tmp\n" && \
    emerge -qv \
           --buildpkg \
           --buildpkg-exclude \
           "virtual/* \
           sys-kernel/*-sources" \
           @dev \
           @dev-lang \
           @desktop \
           @essentials \
           @virt \
           @net && \
    tar --directory /output -cJvf gentoo-binpkgs.tar.xz /var/cache/binpkgs && \
    sha384sum /output/gentoo-binpkgs.tar.xz > /output/gentoo-binpkgs.tar.xz.sha384
