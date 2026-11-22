
# ---- Added by MWT. Everything above is yours; this layer is the same for every build. ----
# Only pointers: MWT fills /mnt/mwt for each VM (its CA bundle, the
# placeholders, git's credential helper) and mounts the VM's Cache at /cache.
# Nothing here belongs to one identity, so a CA change needs no rebuild.
RUN set -e; \
    mkdir -p /etc/ssl/certs /etc/ca-certificates/update.d /etc/profile.d /mnt/mwt /cache /root; \
    ln -sf /mnt/mwt/ca-bundle.pem /etc/ssl/certs/ca-certificates.crt; \
    printf '#!/bin/sh\n# MWT: keep the bundle pointing at the one MWT writes.\nln -sf /mnt/mwt/ca-bundle.pem /etc/ssl/certs/ca-certificates.crt\n' \
      > /etc/ca-certificates/update.d/zz-mwt; \
    chmod 755 /etc/ca-certificates/update.d/zz-mwt; \
    ln -sf /mnt/mwt/profile.sh /etc/profile.d/mwt.sh; \
    if [ -f /etc/bash.bashrc ]; then echo '[ -r /mnt/mwt/bashrc.sh ] && . /mnt/mwt/bashrc.sh' >> /etc/bash.bashrc; fi; \
    if command -v git >/dev/null; then \
      git config --system credential.helper /mnt/mwt/bin/git-credential; \
      git config --system url."https://github.com/".insteadOf "git@github.com:"; \
      git config --system --add url."https://github.com/".insteadOf "ssh://git@github.com/"; \
    fi; \
    mkdir -p /etc/mwt; \
    if command -v mise >/dev/null; then mise ls --offline > /etc/mwt/versions.txt 2>&1 || true; fi
ENV SSL_CERT_FILE=/mnt/mwt/ca-bundle.pem \
    CURL_CA_BUNDLE=/mnt/mwt/ca-bundle.pem \
    REQUESTS_CA_BUNDLE=/mnt/mwt/ca-bundle.pem \
    HEX_CACERTS_PATH=/mnt/mwt/ca-bundle.pem \
    CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE=/mnt/mwt/ca-bundle.pem \
    NODE_EXTRA_CA_CERTS=/mnt/mwt/ca.pem \
    GRPC_DEFAULT_SSL_ROOTS_FILE_PATH=/mnt/mwt/ca-bundle.pem \
    AWS_CA_BUNDLE=/mnt/mwt/ca-bundle.pem \
    DENO_CERT=/mnt/mwt/ca.pem \
    JAVA_TOOL_OPTIONS="-Djavax.net.ssl.trustStore=/mnt/mwt/java-truststore.jks -Djavax.net.ssl.trustStoreType=JKS -Djavax.net.ssl.trustStorePassword=changeit" \
    HEX_HTTP_TIMEOUT=900 \
    BASH_ENV=/mnt/mwt/profile.sh \
    SHELL=/bin/bash \
    MWT_SANDBOX=1 \
    ZED_FILE_WATCHER_MODE=poll \
    ZED_FILE_WATCHER_POLL_MS=5000 \
    XDG_CACHE_HOME=/cache/xdg \
    MISE_DATA_DIR=/cache/mise \
    MISE_CACHE_DIR=/cache/xdg/mise \
    HEX_HOME=/cache/hex \
    MIX_HOME=/cache/mix \
    npm_config_cache=/cache/npm \
    npm_config_prefix=/cache/npm-global \
    GOPATH=/cache/go \
    CARGO_HOME=/cache/cargo \
    GRADLE_USER_HOME=/cache/gradle \
    PATH="/cache/mise/shims:/cache/npm-global/bin:/cache/cargo/bin:/cache/go/bin:${PATH}"
