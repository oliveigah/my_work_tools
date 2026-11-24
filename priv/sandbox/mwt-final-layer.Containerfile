# ---- MWT's final layer: MWT keeps it, the same for every build. It comes after yours. ----
USER root
SHELL ["/bin/sh", "-c"]

# What MWT runs in the VM, from its base: your layer may have removed or
# replaced some of it. The build stops here, naming what is missing, rather
# than a VM failing later in a way that points nowhere.
RUN missing=""; \
    for tool in bash git socat ss python3 find tar sed grep awk setsid flock timeout \
      mktemp realpath openssl update-ca-certificates bwrap; do \
      command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"; \
    done; \
    find --version 2>/dev/null | grep -q GNU || missing="$missing GNU-find"; \
    tar --version 2>/dev/null | grep -q GNU || missing="$missing GNU-tar"; \
    if [ -n "$missing" ]; then \
      echo "MWT runs these in the VM, and your layer removed or replaced them:$missing." >&2; \
      echo "Put them back, or start from MWT's default." >&2; \
      exit 1; \
    fi

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Only pointers: MWT fills /mnt/mwt for each VM (its CA bundle, the
# placeholders, git's credential helper) and mounts the VM's Cache at /cache.
# Nothing here belongs to one identity, so a CA change needs no rebuild.
# Containers keep their storage on /cache: the VM's root is an overlay, on
# which podman's own overlay storage can't mount, and /cache survives
# recreating the VM.
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
    if command -v podman >/dev/null; then \
      mkdir -p /etc/containers; \
      printf '[storage]\ndriver = "overlay"\nrunroot = "/run/containers/storage"\ngraphroot = "/cache/containers/storage"\n' \
        > /etc/containers/storage.conf; \
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

WORKDIR /root
ENTRYPOINT []
CMD ["/bin/bash"]

# Last, once every file is in place: the checksum of each file in the image.
# After a VM's first start, MWT checks them against the image disk the VM
# runs from, which microsandbox assembled from this build: a file damaged
# there shows on the VM's page instead of as a crash an agent hits later.
# What is mounted into the build (its /etc/hosts, a CA, a secret) is never
# committed, so every mount point the build has is left out.
RUN mkdir -p /etc/mwt && cd / \
    && mounts=() \
    && while read -r _ _ _ _ point _; do \
         point=$(printf '%b' "$point"); \
         [ "$point" = / ] || mounts+=(! -path ".$point" ! -path ".$point/*"); \
       done < /proc/self/mountinfo \
    && find . -xdev -type f ! -path ./etc/mwt/image.sha256 "${mounts[@]}" -print0 \
    | LC_ALL=C sort -z | xargs -0 -r sha256sum > /etc/mwt/image.sha256
