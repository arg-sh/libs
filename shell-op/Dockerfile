FROM flant/shell-operator:v1.14.3

COPY --from=ghcr.io/arg-sh/argsh:latest /usr/local/bin/argsh /usr/local/bin/argsh
COPY --from=ghcr.io/fentas/b:latest /b /usr/local/bin/b

# Bake the argsh musl builtin (.so) so argsh does NOT fetch it at runtime. Without a
# local .so present, argsh auto-downloads argsh-linux-<arch>.so from GitHub Releases
# on first run — which HANGS in network-restricted environments (egress firewalls,
# air-gapped clusters) and never returns, so every hook's `--config` stalls and
# shell-operator never subscribes. The musl build is the right one for this Alpine
# base; libgcc provides libgcc_s.so.1, which the Rust loadable links for unwinding.
ARG TARGETARCH=amd64
ARG ARGSH_SO_VERSION=v0.10.0
RUN apk add --no-cache libgcc \
 && wget -qO /usr/local/lib/argsh.so \
      "https://github.com/arg-sh/argsh/releases/download/${ARGSH_SO_VERSION}/argsh-linux-musl-${TARGETARCH}.so" \
 && chmod 0644 /usr/local/lib/argsh.so
ENV ARGSH_BUILTIN_PATH=/usr/local/lib/argsh.so

COPY shell-op argsh-plugin.yml /root/.local/share/argsh/libs/shell-op/
