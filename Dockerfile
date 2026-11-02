# Pin the multi-platform Ubuntu release so all stages use the same base.
ARG UBUNTU_IMAGE=ubuntu:26.04@sha256:6a06111c3b0a8600feadb270aec771dc239bf407b25625f93f44ab00e11f4d3c
ARG FIPS_OPENSSL_VERSION=openssl-3.1.2
ARG OPENSSL_VERSION=openssl-3.5.9
FROM ${UBUNTU_IMAGE} AS build-tools

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential ca-certificates curl perl \
    && rm -rf /var/lib/apt/lists/*
COPY --chmod=0755 scripts/fetch-source.sh /usr/local/bin/fetch-source.sh

# Independent stages keep runtime changes from rebuilding the selected module.
FROM build-tools AS fips-builder
ARG FIPS_OPENSSL_VERSION
ARG FIPS_OPENSSL_SHA256=
ARG MAKE_JOBS=2
WORKDIR /build
RUN set -eu; \
    fetch-source.sh "$FIPS_OPENSSL_VERSION" "$FIPS_OPENSSL_SHA256" /build/fips.tar.gz; \
    mkdir /build/fips-src; \
    tar -xzf /build/fips.tar.gz -C /build/fips-src --strip-components=1

# Install the unmodified selected FIPS module into its own staging prefix.
# Its generated builder configuration is deliberately excluded from the image.
RUN set -eu; \
    case "$MAKE_JOBS" in ''|0|*[!0-9]*) exit 1 ;; esac; \
    cd /build/fips-src; \
    ./Configure enable-fips shared --prefix=/build/fips-install \
        --openssldir=/build/fips-install/ssl --libdir=lib; \
    make -j "$MAKE_JOBS" build_sw; \
    make install_fips; \
    sha256sum /build/fips-install/lib/ossl-modules/fips.so | \
        cut -d ' ' -f 1 > /build/fips-module.sha256; \
    install -D -m 0644 LICENSE.txt /build/licenses/FIPS-LICENSE.txt

FROM build-tools AS runtime-builder
ARG OPENSSL_VERSION
ARG OPENSSL_SHA256=
ARG MAKE_JOBS=2
WORKDIR /build
RUN set -eu; \
    fetch-source.sh "$OPENSSL_VERSION" "$OPENSSL_SHA256" /build/openssl.tar.gz; \
    mkdir /build/runtime-src; \
    tar -xzf /build/openssl.tar.gz -C /build/runtime-src --strip-components=1

# no-fips prevents accidentally installing a provider from the runtime release.
# install_runtime selects the proper shared-library ABI without development files.
RUN set -eu; \
    case "$MAKE_JOBS" in ''|0|*[!0-9]*) exit 1 ;; esac; \
    cd /build/runtime-src; \
    ./Configure shared no-fips no-tests --prefix=/opt/openssl \
        --openssldir=/opt/openssl/ssl --libdir=lib \
        '-Wl,-rpath,/opt/openssl/lib'; \
    make -j "$MAKE_JOBS" build_sw; \
    make install_runtime DESTDIR=/build/runtime-root; \
    install -D -m 0644 LICENSE.txt /build/licenses/OPENSSL-LICENSE.txt

FROM ${UBUNTU_IMAGE} AS runtime
ARG FIPS_OPENSSL_VERSION
ARG OPENSSL_VERSION
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ARG VCS_REF=unknown
LABEL org.opencontainers.image.title="OpenSSL with a FIPS provider" \
    org.opencontainers.image.description="Configurable OpenSSL CLI and separately built FIPS provider; not a deployment certification" \
    org.opencontainers.image.source="https://github.com/xcapdevila/openssl-fips" \
    org.opencontainers.image.url="https://github.com/xcapdevila/openssl-fips" \
    org.opencontainers.image.version="${OPENSSL_VERSION}-fips-${FIPS_OPENSSL_VERSION}" \
    org.opencontainers.image.revision=$VCS_REF

# Copy only runtime artifacts and the separately installed selected module.
COPY --from=runtime-builder /build/runtime-root/opt/openssl/ /opt/openssl/
COPY --from=fips-builder /build/fips-install/lib/ossl-modules/fips.so /opt/openssl/lib/ossl-modules/fips.so
COPY --from=fips-builder /build/fips-module.sha256 /opt/openssl/ssl/fips-module.sha256
COPY --from=fips-builder /build/licenses/ /usr/share/doc/openssl-from-source/
COPY --from=runtime-builder /build/licenses/ /usr/share/doc/openssl-from-source/
COPY LICENSE /usr/share/doc/openssl-fips/LICENSE
COPY openssl-fips.cnf /opt/openssl/ssl/openssl.cnf
COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

ENV PATH="/opt/openssl/bin:$PATH" \
    OPENSSL_SOURCE_TAG=$OPENSSL_VERSION \
    FIPS_SOURCE_TAG=$FIPS_OPENSSL_VERSION \
    LD_LIBRARY_PATH=/opt/openssl/lib \
    OPENSSL_CONF=/opt/openssl/ssl/openssl.cnf \
    OPENSSL_MODULES=/opt/openssl/lib/ossl-modules \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_DIR=/etc/ssl/certs \
    HOME=/tmp

USER 10001:10001
WORKDIR /tmp
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["openssl", "list", "-providers"]
