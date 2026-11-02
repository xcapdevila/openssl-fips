# Pin the multi-platform Ubuntu release so both stages use the same base.
ARG UBUNTU_IMAGE=ubuntu:26.04@sha256:6a06111c3b0a8600feadb270aec771dc239bf407b25625f93f44ab00e11f4d3c
FROM ${UBUNTU_IMAGE} AS builder

ARG FIPS_OPENSSL_VERSION=openssl-3.1.2
ARG FIPS_OPENSSL_SHA256=a0ce69b8b97ea6a35b96875235aa453b966ba3cba8af2de23657d8b6767d6539
ARG OPENSSL_VERSION=openssl-3.5.9
ARG OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
ARG MAKE_JOBS=2

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential ca-certificates curl perl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN set -eu; \
    for version in "$FIPS_OPENSSL_VERSION" "$OPENSSL_VERSION"; do \
        printf '%s\n' "$version" | grep -Eq '^openssl-[0-9]+\.[0-9]+\.[0-9]+$'; \
    done; \
    for checksum in "$FIPS_OPENSSL_SHA256" "$OPENSSL_SHA256"; do \
        printf '%s\n' "$checksum" | grep -Eq '^[a-f0-9]{64}$'; \
    done; \
    case "$MAKE_JOBS" in ''|0|*[!0-9]*) exit 1 ;; esac; \
    curl --fail --show-error --location --retry 5 --proto '=https' --tlsv1.2 \
        "https://github.com/openssl/openssl/releases/download/${FIPS_OPENSSL_VERSION}/${FIPS_OPENSSL_VERSION}.tar.gz" \
        --output fips.tar.gz; \
    printf '%s  fips.tar.gz\n' "$FIPS_OPENSSL_SHA256" | sha256sum --check --strict; \
    tar -xzf fips.tar.gz; \
    curl --fail --show-error --location --retry 5 --proto '=https' --tlsv1.2 \
        "https://github.com/openssl/openssl/releases/download/${OPENSSL_VERSION}/${OPENSSL_VERSION}.tar.gz" \
        --output openssl.tar.gz; \
    printf '%s  openssl.tar.gz\n' "$OPENSSL_SHA256" | sha256sum --check --strict; \
    tar -xzf openssl.tar.gz

# Install the unmodified selected FIPS module into its own staging prefix.
# Its generated builder configuration is deliberately excluded from the image.
RUN set -eu; \
    cd "$FIPS_OPENSSL_VERSION"; \
    ./Configure enable-fips shared --prefix=/build/fips-install \
        --openssldir=/build/fips-install/ssl --libdir=lib; \
    make -j "$MAKE_JOBS" build_sw; \
    make install_fips; \
    sha256sum /build/fips-install/lib/ossl-modules/fips.so | \
        cut -d ' ' -f 1 > /build/fips-module.sha256; \
    install -D -m 0644 LICENSE.txt /build/licenses/FIPS-LICENSE.txt

# no-fips prevents accidentally installing a provider from the runtime release.
RUN set -eu; \
    cd "$OPENSSL_VERSION"; \
    ./Configure shared no-fips no-tests --prefix=/opt/openssl \
        --openssldir=/opt/openssl/ssl --libdir=lib \
        '-Wl,-rpath,/opt/openssl/lib'; \
    make -j "$MAKE_JOBS" build_sw; \
    make install_sw; \
    install -D -m 0644 LICENSE.txt /build/licenses/OPENSSL-LICENSE.txt

FROM ${UBUNTU_IMAGE} AS runtime
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy only the CLI, shared runtime libraries, and the selected installed module.
COPY --from=builder /opt/openssl/bin/openssl /opt/openssl/bin/openssl
COPY --from=builder /opt/openssl/lib/libcrypto.so.3 /opt/openssl/lib/libcrypto.so.3
COPY --from=builder /opt/openssl/lib/libssl.so.3 /opt/openssl/lib/libssl.so.3
COPY --from=builder /build/fips-install/lib/ossl-modules/fips.so /opt/openssl/lib/ossl-modules/fips.so
COPY --from=builder /build/fips-module.sha256 /opt/openssl/ssl/fips-module.sha256
COPY --from=builder /build/licenses/ /usr/share/doc/openssl-from-source/
COPY openssl-fips.cnf /opt/openssl/ssl/openssl.cnf
COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

ENV PATH="/opt/openssl/bin:$PATH" \
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
