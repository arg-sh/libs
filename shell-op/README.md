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

shell-op::kubernetes "watch-pods" \
  kind=Pod apiVersion=v1 \
  events=Added \
  labels="app=myapp" \
  jqFilter='.metadata.name'

pod::added() {
  local name
  shell-op::object name=.metadata.name
  echo "Pod '${name}' added"
}

shell-op::on Event pod::added
shell-op::run "${@}"
```

## Bindings

### `shell-op::kubernetes` — watch Kubernetes resources

```bash
shell-op::kubernetes "watch-deploys" \
  kind=Deployment \
  apiVersion=apps/v1 \
  events=Added,Modified,Deleted \
  labels="app=web,tier=frontend" \
  fields="status.phase=Running" \
  jqFilter='.metadata.name' \
  namespace=production
```

All parameters except `kind` are optional.

### `shell-op::schedule` — cron triggers

```bash
shell-op::schedule "every-5m" "*/5 * * * *"
shell-op::schedule "hourly" "0 * * * *"
```

### `shell-op::startup` — run at operator start

```bash
shell-op::startup 10  # order parameter (default: 1)
```

## Event routing

### `shell-op::on` — map events to functions

```bash
shell-op::on Event pod::event
shell-op::on Synchronization pod::sync
shell-op::on "every-5m" cron::cleanup   # by binding name
```

Binding-specific handlers take priority over type handlers.

### `shell-op::run` — auto-dispatcher

```bash
shell-op::run "${@}"
```

Handles `--config` automatically, then routes each binding context entry to the registered handler. The handler receives the context index as `$1`.

## Context accessors

### `shell-op::object` — read from the Kubernetes object

```bash
local name namespace
shell-op::object name=.metadata.name namespace=.metadata.namespace

# Or print to stdout
echo "Name: $(shell-op::object .metadata.name)"
```

### `shell-op::filter` — read from filterResult

```bash
local name status
shell-op::filter name=.name status=.status
```

### `shell-op::snapshots` — iterate Synchronization objects

```bash
shell-op::snapshots "watch-pods" | while read -r snap; do
  echo "Pod: $(echo "${snap}" | jq -r '.object.metadata.name')"
done
```

### `shell-op::type` / `shell-op::binding` / `shell-op::count`

```bash
echo "Event type: $(shell-op::type)"
echo "Binding: $(shell-op::binding)"
echo "Context entries: $(shell-op::count)"
```

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
└── shell-op.bats       # tests (27 tests)
```

## License

MIT
