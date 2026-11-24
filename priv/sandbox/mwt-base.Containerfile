# ---- MWT's base: MWT keeps it, the same for every build. Your layer comes after it. ----
# Ubuntu 26.04 LTS: hex.pm builds Erlang for it, so `mise install erlang`
# takes seconds; Playwright supports it; its packages are patched until 2031.
# Only what MWT itself runs in the VM, which its final layer checks is still
# there after yours:
#   - bash, coreutils, findutils, tar, sed, grep, mawk, util-linux: the shell
#     snippets MWT runs there to sync folders, keep slots and hand off work
#     (GNU find and tar: `find -printf`, `tar --format=gnu`);
#   - git: projects, slots and handoffs;
#   - socat and iproute2 (ss): the mwt command, and the watcher that opens
#     the VM's servers on your machine;
#   - python3: the agents' memory tool;
#   - ca-certificates (with openssl): MWT's CA joins the system's bundle;
#   - bubblewrap: confines microsandbox when the VM runs VMs of its own.
FROM docker.io/library/ubuntu:26.04

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash coreutils findutils tar sed grep mawk util-linux \
      git socat iproute2 python3 ca-certificates openssl bubblewrap \
    && rm -rf /var/lib/apt/lists/*
