FROM flant/shell-operator:v1.14.3

COPY --from=ghcr.io/arg-sh/argsh:latest /usr/local/bin/argsh /usr/local/bin/argsh
COPY --from=ghcr.io/fentas/b:latest /b /usr/local/bin/b

COPY shell-op argsh-plugin.yml /root/.local/share/argsh/libs/shell-op/
