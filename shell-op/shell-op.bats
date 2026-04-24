#!/usr/bin/env bats
# shellcheck shell=bash disable=SC2034

setup() {
  source argsh
  source "${BATS_TEST_DIRNAME}/shell-op"
  _tmp="$(mktemp -d)"

  # Reset state between tests
  __SHELLOP_BINDINGS=()
  __SHELLOP_STARTUP=-1
  __SHELLOP_STARTUP_HANDLER=""
}

teardown() {
  rm -rf "${_tmp}"
}

# ── shell-op::on ───────────────────────────────────────

@test "on: minimal binding" {
  shell-op::on -k Pod pod::handle
  local config
  config="$(shell-op::config)"
  [[ "$(echo "${config}" | jq -r '.kubernetes[0].kind')" == "Pod" ]]
  [[ "$(echo "${config}" | jq -r '.kubernetes[0].name')" == "pod::handle" ]]
}

@test "on: full binding with all options" {
  shell-op::on \
    -k apps/v1/Deployment \
    -e Added -e Modified \
    -l "app=web,tier=frontend" \
    -f '.metadata.name' \
    -n production \
    deploy::handle

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

@test "on: apiVersion parsed from kind" {
  shell-op::on -k v1/Pod pod::handle
  local config
  config="$(shell-op::config)"
  [[ "$(echo "${config}" | jq -r '.kubernetes[0].apiVersion')" == "v1" ]]
  [[ "$(echo "${config}" | jq -r '.kubernetes[0].kind')" == "Pod" ]]
}

@test "on: kind capitalized" {
  shell-op::on -k pod pod::handle
  local config
  config="$(shell-op::config)"
  [[ "$(echo "${config}" | jq -r '.kubernetes[0].kind')" == "Pod" ]]
}

@test "on: multiple kinds auto-groups" {
  shell-op::on -k Pod -k Service pod::handle
  local config
  config="$(shell-op::config)"
  [[ "$(echo "${config}" | jq -r '.kubernetes | length')" == "2" ]]
  [[ "$(echo "${config}" | jq -r '.kubernetes[0].group')" == "pod::handle" ]]
  [[ "$(echo "${config}" | jq -r '.kubernetes[1].group')" == "pod::handle" ]]
}

@test "on: explicit group" {
  shell-op::on -k Pod -g mesh pod::handle
  local config
  config="$(shell-op::config)"
  [[ "$(echo "${config}" | jq -r '.kubernetes[0].group')" == "mesh" ]]
}

@test "on: --no-sync" {
  shell-op::on -k Pod --no-sync pod::handle
  local config
  config="$(shell-op::config)"
  [[ "$(echo "${config}" | jq -r '.kubernetes[0].executeHookOnSynchronization')" == "false" ]]
}

@test "on: missing handler fails" {
  run shell-op::on -k Pod
  [[ "${status}" -ne 0 ]]
  [[ "${output}" == *"handler function required"* ]]
}

@test "on: missing kind fails" {
  run shell-op::on pod::handle
  [[ "${status}" -ne 0 ]]
  [[ "${output}" == *"at least one --kind required"* ]]
}

@test "on: unknown flag fails" {
  run shell-op::on -k Pod --foo bar pod::handle
  [[ "${status}" -ne 0 ]]
  [[ "${output}" == *"unknown flag"* ]]
}

@test "on: --help shows usage" {
  run shell-op::on --help
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == *"Register a Kubernetes watch binding"* ]]
  [[ "${output}" == *"--kind"* ]]
}

@test "on: repeated events accumulate" {
  shell-op::on -k Pod -e Added -e Modified -e Deleted pod::handle
  local config
  config="$(shell-op::config)"
  [[ "$(echo "${config}" | jq -r '.kubernetes[0].executeHookOnEvent | length')" == "3" ]]
}

# ── shell-op::cron ─────────────────────────────────────

@test "cron: basic schedule" {
  shell-op::cron "*/5 * * * *" cron::handle
  local config
  config="$(shell-op::config)"
  [[ "$(echo "${config}" | jq -r '.schedule[0].name')" == "cron::handle" ]]
  [[ "$(echo "${config}" | jq -r '.schedule[0].crontab')" == "*/5 * * * *" ]]
}

@test "cron: multiple schedules" {
  shell-op::cron "*/1 * * * *" fast::tick
  shell-op::cron "0 * * * *" slow::tick

  local config
  config="$(shell-op::config)"
  [[ "$(echo "${config}" | jq -r '.schedule | length')" == "2" ]]
}

@test "cron: missing crontab fails" {
  run shell-op::cron "" handler
  [[ "${status}" -ne 0 ]]
}

@test "cron: missing handler fails" {
  run shell-op::cron "*/5 * * * *" ""
  [[ "${status}" -ne 0 ]]
}

# ── shell-op::startup ─────────────────────────────────

@test "startup: registers handler" {
  shell-op::startup my::init
  local config
  config="$(shell-op::config)"
  [[ "$(echo "${config}" | jq -r '.onStartup')" == "1" ]]
  [[ "${__SHELLOP_STARTUP_HANDLER}" == "my::init" ]]
}

@test "startup: custom order" {
  shell-op::startup my::init 10
  local config
  config="$(shell-op::config)"
  [[ "$(echo "${config}" | jq -r '.onStartup')" == "10" ]]
}

# ── shell-op::config ──────────────────────────────────

@test "config: empty is valid JSON" {
  local config
  config="$(shell-op::config)"
  [[ "$(echo "${config}" | jq -r '.configVersion')" == "v1" ]]
  [[ "$(echo "${config}" | jq 'has("kubernetes")')" == "false" ]]
  [[ "$(echo "${config}" | jq 'has("schedule")')" == "false" ]]
  [[ "$(echo "${config}" | jq 'has("onStartup")')" == "false" ]]
}

@test "config: combined bindings" {
  shell-op::startup init::handler
  shell-op::cron "*/5 * * * *" cron::handle
  shell-op::on -k Pod -e Added pod::handle

  local config
  config="$(shell-op::config)"
  [[ "$(echo "${config}" | jq 'has("onStartup")')" == "true" ]]
  [[ "$(echo "${config}" | jq 'has("schedule")')" == "true" ]]
  [[ "$(echo "${config}" | jq 'has("kubernetes")')" == "true" ]]
}

# ── shell-op::run ──────────────────────────────────────

@test "run: --config outputs config" {
  shell-op::on -k Pod pod::handle
  local config
  config="$(shell-op::run --config)"
  [[ "$(echo "${config}" | jq -r '.configVersion')" == "v1" ]]
  [[ "$(echo "${config}" | jq -r '.kubernetes[0].kind')" == "Pod" ]]
}

@test "run: dispatches k8s Event to handler" {
  cat > "${_tmp}/ctx.json" << 'JSON'
[{"type":"Event","binding":"pod::handle","watchEvent":"Added","object":{"kind":"Pod","metadata":{"name":"nginx","namespace":"default"}}}]
JSON
  BINDING_CONTEXT_PATH="${_tmp}/ctx.json"

  _result=""
  pod::handle() {
    local event name namespace
    local -a args=("${__SHELLOP_K8S_ARGS[@]}")
    :args "test" "${@}"
    _result="${event}:${name}:${namespace}"
  }

  shell-op::on -k Pod -e Added pod::handle
  shell-op::run

  [[ "${_result}" == "Added:nginx:default" ]]
}

@test "run: dispatches cron to handler" {
  cat > "${_tmp}/ctx.json" << 'JSON'
[{"type":"Schedule","binding":"cron::handle"}]
JSON
  BINDING_CONTEXT_PATH="${_tmp}/ctx.json"

  _result=""
  cron::handle() {
    local event binding
    local -a args=("${__SHELLOP_CRON_ARGS[@]}")
    :args "test" "${@}"
    _result="${event}:${binding}"
  }

  shell-op::cron "*/5 * * * *" cron::handle
  shell-op::run

  [[ "${_result}" == "Schedule:cron::handle" ]]
}

@test "run: dispatches startup to handler" {
  cat > "${_tmp}/ctx.json" << 'JSON'
[{"type":"","binding":"onStartup"}]
JSON
  BINDING_CONTEXT_PATH="${_tmp}/ctx.json"

  _result=""
  init::handler() {
    local event
    local -a args=("${__SHELLOP_K8S_ARGS[@]}")
    :args "test" "${@}"
    _result="${event}"
  }

  shell-op::startup init::handler
  shell-op::run

  [[ "${_result}" == "onStartup" ]]
}

@test "run: unified event prefers watchEvent over type" {
  cat > "${_tmp}/ctx.json" << 'JSON'
[{"type":"Event","binding":"pod::handle","watchEvent":"Modified","object":{"kind":"Pod","metadata":{"name":"nginx","namespace":"default"}}}]
JSON
  BINDING_CONTEXT_PATH="${_tmp}/ctx.json"

  _result=""
  pod::handle() {
    local event
    local -a args=("${__SHELLOP_K8S_ARGS[@]}")
    :args "test" "${@}"
    _result="${event}"
  }

  shell-op::on -k Pod pod::handle
  shell-op::run

  [[ "${_result}" == "Modified" ]]
}

@test "run: Synchronization event dispatches" {
  cat > "${_tmp}/ctx.json" << 'JSON'
[{"type":"Synchronization","binding":"pod::handle","objects":[{"object":{"kind":"Pod","metadata":{"name":"a","namespace":"ns"}}}]}]
JSON
  BINDING_CONTEXT_PATH="${_tmp}/ctx.json"

  _result=""
  pod::handle() {
    local event type
    local -a args=("${__SHELLOP_K8S_ARGS[@]}")
    :args "test" "${@}"
    _result="${event}:${type}"
  }

  shell-op::on -k Pod pod::handle
  shell-op::run

  [[ "${_result}" == "Synchronization:Synchronization" ]]
}

@test "run: handler receives ctx as raw JSON" {
  cat > "${_tmp}/ctx.json" << 'JSON'
[{"type":"Event","binding":"pod::handle","watchEvent":"Added","object":{"kind":"Pod","metadata":{"name":"test","namespace":"default"}}}]
JSON
  BINDING_CONTEXT_PATH="${_tmp}/ctx.json"

  _ctx_result=""
  pod::handle() {
    local ctx
    local -a args=("${__SHELLOP_K8S_ARGS[@]}")
    :args "test" "${@}"
    _ctx_result="${ctx}"
  }

  shell-op::on -k Pod pod::handle
  shell-op::run

  # ctx should be valid JSON
  echo "${_ctx_result}" | jq -e '.type == "Event"'
}

@test "run: multiple context entries dispatched" {
  cat > "${_tmp}/ctx.json" << 'JSON'
[
  {"type":"Event","binding":"pod::handle","watchEvent":"Added","object":{"kind":"Pod","metadata":{"name":"a","namespace":"ns"}}},
  {"type":"Event","binding":"pod::handle","watchEvent":"Deleted","object":{"kind":"Pod","metadata":{"name":"b","namespace":"ns"}}}
]
JSON
  BINDING_CONTEXT_PATH="${_tmp}/ctx.json"

  _call_count=0
  pod::handle() {
    local -a args=("${__SHELLOP_K8S_ARGS[@]}")
    :args "test" "${@}"
    _call_count=$(( _call_count + 1 ))
  }

  shell-op::on -k Pod pod::handle
  shell-op::run

  [[ "${_call_count}" == "2" ]]
}

# ── CLI ────────────────────────────────────────────────

@test "init: scaffolds hook file" {
  cd "${_tmp}"
  main::init --name my-hook
  [[ -f "hooks/my-hook.sh" ]]
  [[ -x "hooks/my-hook.sh" ]]
  [[ "$(head -1 hooks/my-hook.sh)" == "#!/usr/bin/env bash" ]]
  grep -q "shell-op::on" "hooks/my-hook.sh"
  grep -q "shell-op::run" "hooks/my-hook.sh"
  grep -q "shell-op::cron" "hooks/my-hook.sh"
}
