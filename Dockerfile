# Use an official Ubuntu as a base image
FROM ubuntu:latest

# Set build arguments for OpenSSL versions
ARG FIPS_OPENSSL_VERSION=openssl-3.1.2
ARG OPENSSL_VERSION=openssl-3.4.1

# Install necessary dependencies
RUN apt-get update && apt-get install -y \
    wget \
    vim \
    build-essential

# Remove default OpenSSL installation
RUN apt-get purge --auto-remove openssl -y

# Download and build the validated FIPS provider
RUN wget --no-check-certificate https://github.com/openssl/openssl/releases/download/${FIPS_OPENSSL_VERSION}/${FIPS_OPENSSL_VERSION}.tar.gz && \
    tar -xf ${FIPS_OPENSSL_VERSION}.tar.gz && \
    cd ${FIPS_OPENSSL_VERSION} && \
    ./Configure enable-fips && \
    make && \
    make install

# Download and build the release of OpenSSL
RUN wget --no-check-certificate https://github.com/openssl/openssl/releases/download/${OPENSSL_VERSION}/${OPENSSL_VERSION}.tar.gz && \
    tar -xf ${OPENSSL_VERSION}.tar.gz && \
    cd ${OPENSSL_VERSION} && \
    ./Configure enable-fips && \
    make && \
    make install

# Copy the FIPS provider artifacts to the OpenSSL providers directory
RUN cp ${FIPS_OPENSSL_VERSION}/providers/fips.so ${OPENSSL_VERSION}/providers/. && \
    cp ${FIPS_OPENSSL_VERSION}/providers/fipsmodule.cnf ${OPENSSL_VERSION}/providers/.

# Validate the FIPS provider
RUN cd ${OPENSSL_VERSION} && \
    ./util/wrap.pl -fips apps/openssl list -provider-path providers -provider fips -providers > apps/fips_provider_validation.txt

# Run tests using the OpenSSL 3.1.2 FIPS provider
RUN cd ${OPENSSL_VERSION} && \
    make tests

# Install the FIPS provider
RUN cd ${FIPS_OPENSSL_VERSION} && \
    make install_fips

# Check that the correct FIPS provider is being used
RUN cd ${OPENSSL_VERSION} && \
    ./util/wrap.pl -fips apps/openssl list -provider-path providers -provider fips -providers > apps/fips_provider_installation.txt

# Uncomment the FIPS-related lines in the openssl.cnf file
RUN sed -i "s/# .include fipsmodule.cnf/.include \/${OPENSSL_VERSION}\/providers\/fipsmodule.cnf/" /${OPENSSL_VERSION}/apps/openssl.cnf
RUN sed -i 's/# fips = fips_sect/fips = fips_sect/' /${OPENSSL_VERSION}/apps/openssl.cnf
RUN sed -i 's/# activate = 1/activate = 1/' /${OPENSSL_VERSION}/apps/openssl.cnf

# Set the environment variables to use the correct libraries and configuration
ENV LD_LIBRARY_PATH=/usr/local/lib
ENV OPENSSL_CONF=/${OPENSSL_VERSION}/apps/openssl.cnf
ENV PATH="/usr/local/bin:$PATH"

# Set the working directory to where OpenSSL binaries are installed
WORKDIR ${OPENSSL_VERSION}/apps

# Set the entrypoint to Bash
ENTRYPOINT ["/bin/bash", "-c"]
