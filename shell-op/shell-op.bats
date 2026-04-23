#!/usr/bin/env bats
# shellcheck shell=bash disable=SC2034

setup() {
  source "${BATS_TEST_DIRNAME}/shell-op"
  _tmp="$(mktemp -d)"

  # Reset state between tests
  __SHELLOP_K8S_NAMES=()
  __SHELLOP_K8S_KIND=()
  __SHELLOP_K8S_API=()
  __SHELLOP_K8S_EVENTS=()
  __SHELLOP_K8S_LABELS=()
  __SHELLOP_K8S_FIELDS=()
  __SHELLOP_K8S_JQ=()
  __SHELLOP_K8S_NS=()
  __SHELLOP_SCHED_NAMES=()
  __SHELLOP_SCHED_CRON=()
  __SHELLOP_STARTUP=-1
  __SHELLOP_HANDLERS=()
}

teardown() {
  rm -rf "${_tmp}"
}

# ── shell-op::kubernetes ───────────────────────────────

@test "kubernetes: minimal binding with kind only" {
  shell-op::kubernetes "watch-pods" kind=Pod
  local config
  config="$(shell-op::config)"
  [[ "$(echo "${config}" | jq -r '.kubernetes[0].name')" == "watch-pods" ]]
  [[ "$(echo "${config}" | jq -r '.kubernetes[0].kind')" == "Pod" ]]
}

@test "kubernetes: full binding with all options" {
  shell-op::kubernetes "watch-deploys" \
    kind=Deployment apiVersion=apps/v1 \
    events=Added,Modified \
    labels="app=web,tier=frontend" \
    jqFilter='.metadata.name' \
    namespace=production

  local config
  config="$(shell-op::config)"

  [[ "$(echo "${config}" | jq -r '.kubernetes[0].kind')" == "Deployment" ]]
  [[ "$(echo "${config}" | jq -r '.kubernetes[0].apiVersion')" == "apps/v1" ]]
  [[ "$(echo "${config}" | jq -r '.kubernetes[0].jqFilter')" == ".metadata.name" ]]
  [[ "$(echo "${config}" | jq -r '.kubernetes[0].executeHookOnEvent | length')" == "2" ]]
  [[ "$(echo "${config}" | jq -r '.kubernetes[0].executeHookOnEvent[0]')" == "Added" ]]
  [[ "$(echo "${config}" | jq -r '.kubernetes[0].executeHookOnEvent[1]')" == "Modified" ]]
  [[ "$(echo "${config}" | jq -r '.kubernetes[0].labelSelector.matchLabels.app')" == "web" ]]
  [[ "$(echo "${config}" | jq -r '.kubernetes[0].labelSelector.matchLabels.tier')" == "frontend" ]]
  [[ "$(echo "${config}" | jq -r '.kubernetes[0].namespace.nameSelector.matchNames[0]')" == "production" ]]
}

@test "kubernetes: missing kind fails" {
  run shell-op::kubernetes "bad" apiVersion=v1
  [[ "${status}" -ne 0 ]]
  [[ "${output}" == *"kind= is required"* ]]
}

@test "kubernetes: unknown key fails" {
  run shell-op::kubernetes "bad" kind=Pod foo=bar
  [[ "${status}" -ne 0 ]]
  [[ "${output}" == *"unknown key"* ]]
}

@test "kubernetes: multiple bindings" {
  shell-op::kubernetes "pods" kind=Pod events=Added
  shell-op::kubernetes "svcs" kind=Service events=Deleted

  local config
  config="$(shell-op::config)"
  [[ "$(echo "${config}" | jq -r '.kubernetes | length')" == "2" ]]
  [[ "$(echo "${config}" | jq -r '.kubernetes[0].name')" == "pods" ]]
  [[ "$(echo "${config}" | jq -r '.kubernetes[1].name')" == "svcs" ]]
}

@test "kubernetes: field selector" {
  shell-op::kubernetes "watch" kind=Pod \
    fields="status.phase=Running,metadata.name=nginx"

  local config
  config="$(shell-op::config)"
  [[ "$(echo "${config}" | jq -r '.kubernetes[0].fieldSelector.matchExpressions | length')" == "2" ]]
  [[ "$(echo "${config}" | jq -r '.kubernetes[0].fieldSelector.matchExpressions[0].field')" == "status.phase" ]]
  [[ "$(echo "${config}" | jq -r '.kubernetes[0].fieldSelector.matchExpressions[0].value')" == "Running" ]]
}

# ── shell-op::schedule ─────────────────────────────────

@test "schedule: cron binding" {
  shell-op::schedule "every-5m" "*/5 * * * *"
  local config
  config="$(shell-op::config)"
  [[ "$(echo "${config}" | jq -r '.schedule[0].name')" == "every-5m" ]]
  [[ "$(echo "${config}" | jq -r '.schedule[0].crontab')" == "*/5 * * * *" ]]
}

@test "schedule: missing crontab fails" {
  run shell-op::schedule "bad" ""
  [[ "${status}" -ne 0 ]]
  [[ "${output}" == *"crontab is required"* ]]
}

@test "schedule: multiple schedules" {
  shell-op::schedule "fast" "*/1 * * * *"
  shell-op::schedule "slow" "0 * * * *"

  local config
  config="$(shell-op::config)"
  [[ "$(echo "${config}" | jq -r '.schedule | length')" == "2" ]]
}

# ── shell-op::startup ─────────────────────────────────

@test "startup: default order" {
  shell-op::startup
  local config
  config="$(shell-op::config)"
  [[ "$(echo "${config}" | jq -r '.onStartup')" == "1" ]]
}

@test "startup: custom order" {
  shell-op::startup 10
  local config
  config="$(shell-op::config)"
  [[ "$(echo "${config}" | jq -r '.onStartup')" == "10" ]]
}

# ── shell-op::config ──────────────────────────────────

@test "config: empty config is valid JSON" {
  local config
  config="$(shell-op::config)"
  [[ "$(echo "${config}" | jq -r '.configVersion')" == "v1" ]]
  # No kubernetes, schedule, or startup keys
  [[ "$(echo "${config}" | jq 'has("kubernetes")')" == "false" ]]
  [[ "$(echo "${config}" | jq 'has("schedule")')" == "false" ]]
  [[ "$(echo "${config}" | jq 'has("onStartup")')" == "false" ]]
}

@test "config: combined bindings" {
  shell-op::startup 1
  shell-op::schedule "cron" "*/5 * * * *"
  shell-op::kubernetes "pods" kind=Pod events=Added

  local config
  config="$(shell-op::config)"
  [[ "$(echo "${config}" | jq 'has("onStartup")')" == "true" ]]
  [[ "$(echo "${config}" | jq 'has("schedule")')" == "true" ]]
  [[ "$(echo "${config}" | jq 'has("kubernetes")')" == "true" ]]
}

# ── shell-op::on + shell-op::run ──────────────────────

@test "on: registers handler" {
  shell-op::on Event my_handler
  [[ "${__SHELLOP_HANDLERS["Event"]}" == "my_handler" ]]
}

@test "on: missing handler fails" {
  run shell-op::on Event ""
  [[ "${status}" -ne 0 ]]
}

@test "run: --config outputs config" {
  shell-op::kubernetes "pods" kind=Pod
  local config
  config="$(shell-op::run --config)"
  [[ "$(echo "${config}" | jq -r '.configVersion')" == "v1" ]]
  [[ "$(echo "${config}" | jq -r '.kubernetes[0].kind')" == "Pod" ]]
}

@test "run: dispatches Event to handler" {
  cat > "${_tmp}/ctx.json" << 'JSON'
[{"type":"Event","binding":"watch-pods","object":{"metadata":{"name":"nginx-abc"}}}]
JSON
  BINDING_CONTEXT_PATH="${_tmp}/ctx.json"

  _test_handler_called=""
  test_handler() { _test_handler_called="yes-${1}"; }

  shell-op::on Event test_handler
  shell-op::run

  [[ "${_test_handler_called}" == "yes-0" ]]
}

@test "run: dispatches by binding name over type" {
  cat > "${_tmp}/ctx.json" << 'JSON'
[{"type":"Event","binding":"my-binding"}]
JSON
  BINDING_CONTEXT_PATH="${_tmp}/ctx.json"

  _which=""
  type_handler() { _which="type"; }
  binding_handler() { _which="binding"; }

  shell-op::on Event type_handler
  shell-op::on my-binding binding_handler
  shell-op::run

  [[ "${_which}" == "binding" ]]
}

# ── Context accessors ─────────────────────────────────

@test "object: extracts fields from context" {
  cat > "${_tmp}/ctx.json" << 'JSON'
[{"type":"Event","object":{"metadata":{"name":"nginx","namespace":"default"},"spec":{"replicas":3}}}]
JSON
  BINDING_CONTEXT_PATH="${_tmp}/ctx.json"

  local name namespace
  shell-op::object name=.metadata.name namespace=.metadata.namespace
  [[ "${name}" == "nginx" ]]
  [[ "${namespace}" == "default" ]]
}

@test "object: prints to stdout without var=" {
  cat > "${_tmp}/ctx.json" << 'JSON'
[{"type":"Event","object":{"metadata":{"name":"nginx"}}}]
JSON
  BINDING_CONTEXT_PATH="${_tmp}/ctx.json"

  local result
  result="$(shell-op::object .metadata.name)"
  [[ "${result}" == "nginx" ]]
}

@test "filter: extracts filterResult" {
  cat > "${_tmp}/ctx.json" << 'JSON'
[{"type":"Event","filterResult":{"name":"nginx","status":"Running"}}]
JSON
  BINDING_CONTEXT_PATH="${_tmp}/ctx.json"

  local name status
  shell-op::filter name=.name status=.status
  [[ "${name}" == "nginx" ]]
  [[ "${status}" == "Running" ]]
}

@test "type: reads event type" {
  cat > "${_tmp}/ctx.json" << 'JSON'
[{"type":"Synchronization","binding":"pods"}]
JSON
  BINDING_CONTEXT_PATH="${_tmp}/ctx.json"

  [[ "$(shell-op::type)" == "Synchronization" ]]
}

@test "binding: reads binding name" {
  cat > "${_tmp}/ctx.json" << 'JSON'
[{"type":"Event","binding":"watch-pods"}]
JSON
  BINDING_CONTEXT_PATH="${_tmp}/ctx.json"

  [[ "$(shell-op::binding)" == "watch-pods" ]]
}

@test "count: returns context length" {
  cat > "${_tmp}/ctx.json" << 'JSON'
[{"type":"Event"},{"type":"Event"},{"type":"Synchronization"}]
JSON
  BINDING_CONTEXT_PATH="${_tmp}/ctx.json"

  [[ "$(shell-op::count)" == "3" ]]
}

@test "snapshots: iterates objects" {
  cat > "${_tmp}/ctx.json" << 'JSON'
[{"type":"Synchronization","objects":[{"object":{"metadata":{"name":"a"}}},{"object":{"metadata":{"name":"b"}}}]}]
JSON
  BINDING_CONTEXT_PATH="${_tmp}/ctx.json"

  local count=0
  shell-op::snapshots | while read -r _; do
    count=$(( count + 1 ))
  done
  [[ "$(shell-op::snapshots | wc -l)" == "2" ]]
}

@test "snapshots: iterates named binding snapshots" {
  cat > "${_tmp}/ctx.json" << 'JSON'
[{"type":"Synchronization","snapshots":{"pods":[{"object":{"metadata":{"name":"x"}}},{"object":{"metadata":{"name":"y"}}}]}}]
JSON
  BINDING_CONTEXT_PATH="${_tmp}/ctx.json"

  [[ "$(shell-op::snapshots "pods" | wc -l)" == "2" ]]
}

# ── CLI ────────────────────────────────────────────────

@test "init: scaffolds hook file" {
  source argsh
  cd "${_tmp}"
  main::init --name my-hook
  [[ -f "hooks/my-hook.sh" ]]
  [[ -x "hooks/my-hook.sh" ]]
  [[ "$(head -1 hooks/my-hook.sh)" == "#!/usr/bin/env bash" ]]
  grep -q "shell-op::kubernetes" "hooks/my-hook.sh"
  grep -q "shell-op::run" "hooks/my-hook.sh"
}
