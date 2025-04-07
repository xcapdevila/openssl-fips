# OpenSSL with FIPS Enabled Docker Image

This repository contains a Dockerfile to build an OpenSSL instance with FIPS enabled. Follow the instructions below to build the Docker image and execute commands using the OpenSSL FIPS provider.

## Building the Docker Image

### Build Arguments

You can build the Docker image with specific versions of OpenSSL and the FIPS provider using build arguments. The default versions are:
- `FIPS_OPENSSL_VERSION=openssl-3.1.2`: This is the last FIPS validated version of OpenSSL.
- `OPENSSL_VERSION=openssl-3.4.1`: This is the latest stable release of OpenSSL.

To build the Docker image with the default versions, use:
```sh
docker build -t openssl-fips .
```

To specify different versions, use:
```sh
docker build --build-arg FIPS_OPENSSL_VERSION=<desired-version> --build-arg OPENSSL_VERSION=<desired-version> -t openssl-fips .
```

Example:
```sh
docker build --build-arg FIPS_OPENSSL_VERSION=openssl-3.1.2 --build-arg OPENSSL_VERSION=openssl-3.4.1 -t openssl-fips .
```

## Running the Docker Container

### Listing Providers

To list the available providers, use the following command:
```sh
docker run -it openssl-fips "openssl list -providers"
```

Example output:
```sh
Providers:
  default
    name: OpenSSL Default Provider
    version: 3.4.1
    status: active
  fips
    name: OpenSSL FIPS Provider
    version: 3.1.2
    status: active
```

_The versions in the output match the provided build arguments._

### Generating Random Data with FIPS Provider

To generate random data using the FIPS provider, use the following command:
```sh
docker run -it openssl-fips "openssl rand -provider fips -base64 32"
```

Example output:
```sh
UHMkKnXFcRQak3KEGs+E/gf6nKdaIXYmXPxpLCNBJaE=
```

### Connecting to Bash

To connect to /bin/bash inside the Docker container, use the following command:

```sh
docker run -it openssl-fips /bin/bash
```
