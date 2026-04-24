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

shell-op::on -k v1/Pod -e Added -l "app=myapp" -f '.metadata.name' pod::handle
shell-op::run "${@}"
```

Handlers are argsh functions — declare `local` for the fields you need, `:args` skips the rest.

## Kubernetes bindings

### `shell-op::on` — watch resources

```bash
# Single kind, multiple events
shell-op::on -k v1/Pod -e Added -e Modified -e Deleted pod::handle

# Multiple kinds — auto-groups under the handler name
shell-op::on -k Pod -k Service -e Added mesh::handle

# Full options
shell-op::on \
  -k apps/v1/Deployment \
  -e Added -e Modified \
  -l "app=web,tier=frontend" \
  -f '.metadata.name' \
  -n production \
  -g my-group \
  --no-sync \
  deploy::handle
```

Flags are repeatable for `-k` (kind) and `-e` (event).

| Flag | Long | Description |
|---|---|---|
| `-k` | `--kind` | Resource kind, optionally with apiVersion (`v1/Pod`, `apps/v1/Deployment`) |
| `-e` | `--event` | Watch event: `Added`, `Modified`, `Deleted` (repeatable) |
| `-l` | `--labels` | Label selector (`key=val,...`) |
| `-f` | `--filter` | jq filter expression |
| `-n` | `--namespace` | Namespace to watch |
| `-g` | `--group` | Group key for batching multiple bindings |
| | `--no-sync` | Skip Synchronization on startup |

### Handler signature

Handlers receive positional args with a pre-defined `:args` array. Declare `local` for the fields you need:

```bash
pod::handle() {
  local event kind name namespace type binding ctx
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
| `event` | Unified: watchEvent (`Added`/`Modified`/`Deleted`) or type (`Synchronization`/`Group`) or binding (`onStartup`) |
| `kind` | Resource kind (`Pod`, `Service`, ...) |
| `name` | `object.metadata.name` |
| `namespace` | `object.metadata.namespace` |
| `type` | Raw context type (`Event`/`Synchronization`/`Group`) |
| `binding` | Binding name |
| `ctx` | Full raw JSON binding context |

## Schedule bindings

### `shell-op::cron` — cron triggers

```bash
shell-op::cron "*/5 * * * *" cron::tick
shell-op::cron "0 * * * *" hourly::report
```

Cron handlers receive: `event` (`Schedule`), `binding`, `ctx`.

```bash
cron::tick() {
  local event binding
  :args "Cron tick" "${@}"
  echo "Triggered: ${binding}"
}
```

## Startup

### `shell-op::startup` — run at operator start

```bash
shell-op::startup my::init      # order 1 (default)
shell-op::startup my::init 10   # custom order
```

The handler receives `event` = `onStartup`.

## Entry point

### `shell-op::run` — auto-dispatcher

```bash
shell-op::run "${@}"
```

Handles `--config` automatically (generates shell-operator JSON config from registered bindings), then dispatches each binding context entry to the matching handler.

## CLI

### `shell-op init` — scaffold a new hook

```bash
argsh run shell-op init --name my-hook
# Creates hooks/my-hook.sh with a ready-to-use template
```

## Structure

```text
shell-op/
├── README.md           # this file
├── argsh-plugin.yml    # metadata
├── shell-op            # bash library + CLI executable
├── shell-op.bats       # tests (29 tests)
└── example             # example hook
```

## License

MIT
