# shell-op

Declarative [shell-operator](https://github.com/flant/shell-operator) hooks for [argsh](https://github.com/arg-sh/argsh).

Replaces the `if [[ $1 == "--config" ]]` boilerplate and raw `jq` context parsing with clean, typed functions.

## Install

```bash
argsh lib add shell-op
```

## Usage

### Before (vanilla shell-operator)

```bash
#!/usr/bin/env bash
if [[ $1 == "--config" ]] ; then
  cat <<EOF
configVersion: v1
kubernetes:
- apiVersion: v1
  kind: Pod
  executeHookOnEvent: ["Added"]
  labelSelector:
    matchLabels: {app: myapp}
  jqFilter: '.metadata.name'
EOF
else
  type=$(jq -r '.[0].type' $BINDING_CONTEXT_PATH)
  if [[ $type == "Event" ]] ; then
    podName=$(jq -r '.[0].object.metadata.name' $BINDING_CONTEXT_PATH)
    echo "Pod '${podName}' added"
  fi
fi
```

### After (with shell-op)

```bash
#!/usr/bin/env bash
source argsh
import shell-op

pod::handle() {
  local event name namespace
  :args "Handle pod events" "${@}"
  echo "Pod ${namespace}/${name} was ${event}"
}

shell-op::on pod::handle -k v1/Pod -e Added -l "app=myapp" -f '.metadata.name'
shell-op::run "${@}"
```

Handlers are argsh functions — declare `local` for the fields you need, `:args` skips the rest.

## Kubernetes bindings

### `shell-op::on` — watch resources

```bash
# Single kind, multiple events
shell-op::on pod::handle -k v1/Pod -e Added -e Modified -e Deleted

# Multiple kinds — auto-groups under the handler name
shell-op::on mesh::handle -k Pod -k Service -e Added

# Full options
shell-op::on deploy::handle \
  -k apps/v1/Deployment \
  -e Added -e Modified \
  -l "app=web,tier=frontend" \
  -f '.metadata.name' \
  -n production \
  -g my-group \
  -q slow \
  -r 1h \
  --no-sync
```

Flags `-k` (kind) and `-e` (event) are repeatable.

| Flag | Long | Description |
|---|---|---|
| `-k` | `--kind` | Resource kind, with optional apiVersion (`v1/Pod`, `apps/v1/Deployment`) |
| `-e` | `--event` | Watch event: `Added`, `Modified`, `Deleted` (repeatable) |
| `-l` | `--labels` | Label selector (`key=val,...`) |
| `-f` | `--filter` | jq filter expression |
| `-n` | `--namespace` | Namespace to watch |
| `-g` | `--group` | Group key for batching multiple bindings |
| `-q` | `--queue` | Named queue for parallel execution |
| `-r` | `--resync` | Resynchronization period (e.g. `1h`, `30m`) |
| | `--no-sync` | Skip Synchronization on startup |

### Handler signature

Handlers receive positional args with a pre-defined `:args` array. Declare `local` for the fields you need:

```bash
pod::handle() {
  local event kind name namespace type binding watchEvent ctx
  :args "Handle pod events" "${@}"

  case "${event}" in
    "Synchronization")
      echo "Initial sync: ${namespace}/${name}"
      ;;
    *)
      echo "Pod ${namespace}/${name} was ${event}"
      ;;
  esac
}
```

Available fields (in order):

| Field | Description |
|---|---|
| `event` | Unified: watchEvent (`Added`/`Modified`/`Deleted`) or type (`Synchronization`/`Group`) |
| `kind` | Resource kind (`Pod`, `Service`, ...) |
| `name` | `object.metadata.name` (or `filterResult` if object is empty) |
| `namespace` | `object.metadata.namespace` |
| `type` | Raw context type (`Event`/`Synchronization`/`Group`) |
| `binding` | Binding name |
| `watchEvent` | Raw watch event (`Added`/`Modified`/`Deleted`) |
| `ctx` | Full raw JSON binding context |

## Schedule bindings

### `shell-op::cron` — cron triggers

```bash
shell-op::cron "*/5 * * * *" cron::tick
shell-op::cron "0 * * * *" hourly::report --queue slow
shell-op::cron "*/1 * * * *" fast::check --allow-failure
shell-op::cron "*/5 * * * *" snap::check --include-snapshots pod::handle
```

| Flag | Long | Description |
|---|---|---|
| `-q` | `--queue` | Named queue for parallel execution |
| `-i` | `--include-snapshots` | Include snapshots from a named k8s binding |
| | `--allow-failure` | Ignore hook execution errors |

Cron handlers receive: `event` (`Schedule`), `binding`, `ctx`.

```bash
cron::tick() {
  local event binding
  :args "Cron tick" "${@}"
  echo "Triggered: ${binding}"
}
```

## Startup

### `shell-op::run --startup` — run at operator start

```bash
shell-op::run --startup my::init "${@}"         # order 1 (default)
shell-op::run --startup my::init --order 10 "${@}"  # custom order
```

`onStartup` is a script-level event — the handler is called once when the operator starts, before any k8s events flow. The order controls execution sequence across multiple hook scripts in the same operator.

## Entry point

### `shell-op::run` — main dispatcher

```bash
shell-op::run "${@}"
```

Handles `--config` automatically (generates shell-operator JSON config from registered bindings), dispatches `onStartup` to the startup handler, and routes each binding context entry to the matching handler.

| Flag | Long | Description |
|---|---|---|
| `-s` | `--startup` | Startup handler function |
| `-o` | `--order` | Startup execution order (default: 1) |
| | `--config` | Print shell-operator config (called by shell-operator) |

## Handler validation

Handler functions are validated at registration time using the `to::declared` custom type. If a handler function doesn't exist, registration fails immediately with an error:

```
Handler function 'nonexistent::handler' is not declared
```

## Docker

Base image with argsh + shell-op pre-installed.

### Option 1: Bake hooks into the image

```dockerfile
FROM ghcr.io/arg-sh/shell-op:latest
COPY hooks/ /hooks/
```

### Option 2: Mount hooks via ConfigMap (Kubernetes)

Use the base image and mount hooks at runtime — ideal for GitOps workflows where hooks live alongside your manifests:

```yaml
# kustomization.yaml
configMapGenerator:
- name: my-operator-hooks
  files:
  - hooks/watch-machines.sh

# deployment.yaml
spec:
  containers:
  - name: operator
    image: ghcr.io/arg-sh/shell-op:latest
    volumeMounts:
    - name: hooks
      mountPath: /hooks
  volumes:
  - name: hooks
    configMap:
      name: my-operator-hooks
      defaultMode: 0755
```

## Structure

```text
shell-op/
├── Dockerfile          # base image with argsh + shell-op
├── README.md           # this file
├── argsh-plugin.yml    # metadata
├── shell-op            # bash library
├── shell-op.bats       # unit tests
├── shell-op-e2e.bats   # e2e tests
└── example             # example hook
```

## License

MIT
