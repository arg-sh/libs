#!/usr/bin/env bats
# shellcheck shell=bash disable=SC2034
# E2E tests: validate generated JSON config is valid shell-operator config

setup() {
  source argsh
  SHELLOP_BINDINGS="$(mktemp)"
  export SHELLOP_BINDINGS
  source "${BATS_TEST_DIRNAME}/shell-op"
  _tmp="$(mktemp -d)"
}

teardown() {
  rm -rf "${_tmp}"
  rm -f "${SHELLOP_BINDINGS}"
}

# stub handlers
pod::handle() { :; }
svc::handle() { :; }
mesh::handle() { :; }
cron::tick() { :; }
hourly::report() { :; }
startup::init() { :; }

# ── Config generation ──────────────────────────────────

@test "e2e: empty config is valid shell-operator JSON" {
  local config
  config="$(shell-op::config)"
  echo "${config}" | jq -e '.configVersion == "v1"'
  # Must have configVersion and nothing else
  echo "${config}" | jq -e 'keys == ["configVersion"]'
}

@test "e2e: kubernetes-only config" {
  shell-op::on pod::handle -k v1/Pod -e Added -e Modified -e Deleted \
    -f '.metadata.name' -l "app=web" -n default

  local config
  config="$(shell-op::config)"

  # Valid structure
  echo "${config}" | jq -e '.configVersion == "v1"'
  echo "${config}" | jq -e '.kubernetes | type == "array"'
  echo "${config}" | jq -e '.kubernetes | length == 1'

  # Required fields present
  echo "${config}" | jq -e '.kubernetes[0].name == "pod::handle"'
  echo "${config}" | jq -e '.kubernetes[0].kind == "Pod"'
  echo "${config}" | jq -e '.kubernetes[0].apiVersion == "v1"'

  # Optional fields
  echo "${config}" | jq -e '.kubernetes[0].jqFilter == ".metadata.name"'
  echo "${config}" | jq -e '.kubernetes[0].executeHookOnEvent == ["Added", "Modified", "Deleted"]'
  echo "${config}" | jq -e '.kubernetes[0].labelSelector.matchLabels.app == "web"'
  echo "${config}" | jq -e '.kubernetes[0].namespace.nameSelector.matchNames == ["default"]'

  # No schedule or startup
  echo "${config}" | jq -e 'has("schedule") | not'
  echo "${config}" | jq -e 'has("onStartup") | not'
}

@test "e2e: schedule-only config" {
  shell-op::cron "*/5 * * * *" cron::tick
  shell-op::cron "0 * * * *" hourly::report --queue slow --allow-failure

  local config
  config="$(shell-op::config)"

  echo "${config}" | jq -e '.configVersion == "v1"'
  echo "${config}" | jq -e '.schedule | type == "array"'
  echo "${config}" | jq -e '.schedule | length == 2'

  echo "${config}" | jq -e '.schedule[0].name == "cron::tick"'
  echo "${config}" | jq -e '.schedule[0].crontab == "*/5 * * * *"'

  echo "${config}" | jq -e '.schedule[1].name == "hourly::report"'
  echo "${config}" | jq -e '.schedule[1].queue == "slow"'
  echo "${config}" | jq -e '.schedule[1].allowFailure == true'

  echo "${config}" | jq -e 'has("kubernetes") | not'
}

@test "e2e: combined config with startup" {
  shell-op::on pod::handle -k v1/Pod -e Added
  shell-op::cron "*/5 * * * *" cron::tick

  local config
  config="$(shell-op::run --config --startup startup::init --order 5)"

  echo "${config}" | jq -e '.configVersion == "v1"'
  echo "${config}" | jq -e '.onStartup == 5'
  echo "${config}" | jq -e '.kubernetes | length == 1'
  echo "${config}" | jq -e '.schedule | length == 1'
}

@test "e2e: multi-kind auto-group config" {
  shell-op::on mesh::handle -k Pod -k Service -e Added

  local config
  config="$(shell-op::config)"

  echo "${config}" | jq -e '.kubernetes | length == 2'
  echo "${config}" | jq -e '.kubernetes[0].kind == "Pod"'
  echo "${config}" | jq -e '.kubernetes[1].kind == "Service"'
  # Both share the same group
  echo "${config}" | jq -e '.kubernetes[0].group == "mesh::handle"'
  echo "${config}" | jq -e '.kubernetes[1].group == "mesh::handle"'
  # Both have the same handler name
  echo "${config}" | jq -e '.kubernetes[0].name == .kubernetes[1].name'
}

@test "e2e: no-sync config" {
  shell-op::on pod::handle -k Pod --no-sync

  local config
  config="$(shell-op::config)"

  echo "${config}" | jq -e '.kubernetes[0].executeHookOnSynchronization == false'
}

@test "e2e: queue and resync config" {
  shell-op::on pod::handle -k Pod -q slow -r 30m

  local config
  config="$(shell-op::config)"

  echo "${config}" | jq -e '.kubernetes[0].queue == "slow"'
  echo "${config}" | jq -e '.kubernetes[0].resynchronizationPeriod == "30m"'
}

@test "e2e: include-snapshots config" {
  shell-op::on pod::handle -k Pod -e Added
  shell-op::cron "*/5 * * * *" cron::tick --include-snapshots pod::handle

  local config
  config="$(shell-op::config)"

  echo "${config}" | jq -e '.schedule[0].includeSnapshotsFrom == ["pod::handle"]'
}

@test "e2e: apiVersion parsing variations" {
  shell-op::on pod::handle -k Pod
  shell-op::on svc::handle -k v1/Service
  shell-op::on mesh::handle -k apps/v1/Deployment

  local config
  config="$(shell-op::config)"

  # No apiVersion for bare kind
  echo "${config}" | jq -e '.kubernetes[0].kind == "Pod"'
  echo "${config}" | jq -e '.kubernetes[0] | has("apiVersion") | not'

  # v1 prefix
  echo "${config}" | jq -e '.kubernetes[1].kind == "Service"'
  echo "${config}" | jq -e '.kubernetes[1].apiVersion == "v1"'

  # group/version prefix
  echo "${config}" | jq -e '.kubernetes[2].kind == "Deployment"'
  echo "${config}" | jq -e '.kubernetes[2].apiVersion == "apps/v1"'
}

@test "e2e: multiple label selectors" {
  shell-op::on pod::handle -k Pod -l "app=web,tier=frontend,env=prod"

  local config
  config="$(shell-op::config)"

  echo "${config}" | jq -e '.kubernetes[0].labelSelector.matchLabels.app == "web"'
  echo "${config}" | jq -e '.kubernetes[0].labelSelector.matchLabels.tier == "frontend"'
  echo "${config}" | jq -e '.kubernetes[0].labelSelector.matchLabels.env == "prod"'
}

# ── Full dispatch e2e ──────────────────────────────────

@test "e2e: full lifecycle — config + startup + k8s event + cron" {
  local -a _log=()

  pod::handle() {
    local event name
    :args "pod" "${@}"
    _log+=("k8s:${event}:${name}")
  }
  cron::tick() {
    _log+=("cron")
  }
  startup::init() {
    _log+=("startup")
  }

  shell-op::on pod::handle -k v1/Pod -e Added
  shell-op::cron "*/5 * * * *" cron::tick

  # 1. Config should be valid
  local config
  config="$(shell-op::run --config --startup startup::init)"
  echo "${config}" | jq -e '.configVersion == "v1"'
  echo "${config}" | jq -e 'has("onStartup")'
  echo "${config}" | jq -e 'has("kubernetes")'
  echo "${config}" | jq -e 'has("schedule")'

  # 2. Startup dispatch
  cat > "${_tmp}/ctx.json" << 'JSON'
[{"binding":"onStartup"}]
JSON
  BINDING_CONTEXT_PATH="${_tmp}/ctx.json"
  shell-op::run --startup startup::init
  [[ "${_log[0]}" == "startup" ]]

  # 3. K8s event dispatch
  cat > "${_tmp}/ctx.json" << 'JSON'
[{"type":"Event","binding":"pod::handle","watchEvent":"Added","object":{"kind":"Pod","metadata":{"name":"nginx","namespace":"default"}}}]
JSON
  shell-op::run
  [[ "${_log[1]}" == "k8s:Added:nginx" ]]

  # 4. Cron dispatch
  cat > "${_tmp}/ctx.json" << 'JSON'
[{"type":"Schedule","binding":"cron::tick"}]
JSON
  shell-op::run
  [[ "${_log[2]}" == "cron" ]]
}
