# Your layer: the VM's tools. Edit it freely; MWT keeps the rest. It comes
# after MWT's base (Ubuntu 26.04 with what MWT itself runs in the VM: bash,
# git, socat, python3, CA certificates, bubblewrap) and before MWT's final
# layer, which points the VM at /mnt/mwt (its CA bundle, git's credential
# helper, the placeholders) and at /cache, and checks that what MWT needs is
# still there. So no FROM: the base is MWT's.
#
# The build runs with podman on this machine, in a container, with an empty
# context: no host file reaches the image. Downloads are checked against
# their published checksums, and nothing runs npm install scripts.
#
# Tools come from mise, installed into /usr/local/share/mise with the versions
# in /etc/mise/config.toml. Versions installed later in the VM go to
# /cache/mise, which survives recreating it. Keep /root empty: the VM's Home
# is mounted over it.
ARG MISE_VERSION=2026.11.7

# What agents work with. The libraries and fonts are what a headless
# Chromium (Playwright's) needs to load pages and take screenshots, and
# certutil (libnss3-tools), with which MWT's boot script puts its CA in
# Chromium's own certificate store. podman runs containers in the VM, with
# docker as its alias and nftables for their network: MWT's final layer
# keeps their storage on /cache, and its boot script has them trust MWT's
# CA. apt installs at runtime are lost on every recreate, so they belong
# here.
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash-completion curl openssh-client less procps \
      build-essential pkg-config libssl-dev unzip xz-utils zstd tmux lsof \
      postgresql-client sqlite3 inotify-tools \
      libnss3 libnss3-tools libnspr4 libatk1.0-0t64 libatk-bridge2.0-0t64 libdrm2 libgbm1 \
      libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libasound2t64 \
      fonts-liberation \
      podman podman-docker nftables \
    && rm -rf /var/lib/apt/lists/*

RUN arch="$(uname -m)" \
    && case "$arch" in x86_64) arch=x64 ;; aarch64) arch=arm64 ;; *) exit 1 ;; esac \
    && file="mise-v${MISE_VERSION}-linux-${arch}.tar.xz" \
    && base="https://github.com/jdx/mise/releases/download/v${MISE_VERSION}" \
    && cd /tmp && curl -fsSLO "$base/$file" \
    && curl -fsSL "$base/SHASUMS256.txt" | grep " ./${file}\$" | sed 's# ./# #' | sha256sum -c - \
    && tar -xJf "$file" --strip-components=2 -C /usr/local/bin mise/bin/mise \
    && rm "$file" && mise --version

# Rust through rustup, which is what mise would run anyway. This way the
# toolchains stay in the image while CARGO_HOME (the registry, cargo install)
# lives in /cache, and rust-toolchain.toml files still pick their version.
# The musl target builds MWT's presentations, static (scripts/build-present.sh), when
# MWT itself is developed in the VM.
ENV RUSTUP_HOME=/usr/local/share/rustup CARGO_HOME=/usr/local/share/cargo
RUN arch="$(uname -m)" \
    && url="https://static.rust-lang.org/rustup/dist/${arch}-unknown-linux-gnu/rustup-init" \
    && cd /tmp && curl -fsSLO "$url" \
    && echo "$(curl -fsSL "$url.sha256" | cut -d' ' -f1)  rustup-init" | sha256sum -c - \
    && chmod +x rustup-init \
    && ./rustup-init -y --no-modify-path --profile minimal --default-toolchain stable \
         --component clippy,rustfmt --target "$(uname -m)-unknown-linux-musl" \
    && rm rustup-init

# The default versions. A project's .tool-versions or mise.toml picks others;
# `mise install` in the project fetches them (Erlang comes prebuilt from
# hex.pm, in seconds). Majors are pinned, so a rebuild takes the latest
# patches. Codex is pinned exactly: mise's registry lags its releases.
RUN mkdir -p /etc/mise && printf '%s\n' \
      '[tools]' \
      'erlang = "29"' \
      'elixir = "1.20"' \
      'rebar = "3"' \
      'node = "24"' \
      'pnpm = "latest"' \
      'python = "3.14"' \
      'uv = "latest"' \
      'go = "1.27"' \
      'java = "temurin-21"' \
      'kotlin = "latest"' \
      'gh = "latest"' \
      'gcloud = "latest"' \
      'kubectl = "latest"' \
      'pulumi = "latest"' \
      'jq = "latest"' \
      'yq = "latest"' \
      'ripgrep = "latest"' \
      'fd = "latest"' \
      'shellcheck = "latest"' \
      'claude = "latest"' \
      'codex = "0.167.1"' \
      > /etc/mise/config.toml

ENV MISE_DATA_DIR=/usr/local/share/mise \
    MISE_CACHE_DIR=/tmp/mise-cache \
    MISE_YES=1 \
    MISE_ERLANG_PRECOMPILED_OS=ubuntu-26.04 \
    MISE_TRUSTED_CONFIG_PATHS=/ \
    DISABLE_AUTOUPDATER=1 \
    PATH="/usr/local/share/mise/shims:/usr/local/share/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
RUN mise install --system && mise reshim --system && mise ls && rm -rf /tmp/mise-cache \
    && claude --version && codex --version && elixir --version && cargo --version

RUN mkdir -p /usr/share/bash-completion/completions \
    && mise completion bash > /usr/share/bash-completion/completions/mise

# mise keeps Mix's archives inside each Elixir version, so Hex and rebar for
# the default one belong in the image.
RUN mix local.hex --force && mix local.rebar --force

# Check the same split used by a fresh VM: baked tools in system storage,
# runtime installs in an empty cache. No downloads should be needed here.
RUN MISE_DATA_DIR=/tmp/mwt-runtime mise install --dry-run --dry-run-code \
    && MISE_DATA_DIR=/tmp/mwt-runtime MISE_AUTO_INSTALL=0 HEX_OFFLINE=1 mise exec -- sh -ec '\
      for tool in erl elixir mix node npm npx python python3 uv go java kotlin \
        gh gcloud kubectl pulumi pnpm rebar3 jq yq rg fd shellcheck claude codex; do \
        command -v "$tool" >/dev/null || exit 1; \
      done; \
      mix hex.info >/dev/null; java -version; python --version; node --version' \
    && rm -rf /tmp/mwt-runtime /tmp/mise-cache
