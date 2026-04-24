#!/usr/bin/env bats
# shellcheck shell=bash disable=SC2034

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

# stub handlers for registration (to::declared validation)
pod::handle() { :; }
deploy::handle() { :; }
mesh::handle() { :; }
cron::handle() { :; }
fast::tick() { :; }
slow::tick() { :; }
init::handler() { :; }

# ── shell-op::on ───────────────────────────────────────

@test "on: minimal binding" {
  shell-op::on pod::handle -k Pod
  local config
  config="$(shell-op::config)"
  [[ "$(echo "${config}" | jq -r '.kubernetes[0].kind')" == "Pod" ]]
  [[ "$(echo "${config}" | jq -r '.kubernetes[0].name')" == "pod::handle" ]]
}

@test "on: full binding with all options" {
  shell-op::on deploy::handle \
    -k apps/v1/Deployment \
    -e Added -e Modified \
    -l "app=web,tier=frontend" \
    -f '.metadata.name' \
    -n production

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
  shell-op::on pod::handle -k v1/Pod
  local config
  config="$(shell-op::config)"
  [[ "$(echo "${config}" | jq -r '.kubernetes[0].apiVersion')" == "v1" ]]
  [[ "$(echo "${config}" | jq -r '.kubernetes[0].kind')" == "Pod" ]]
}

@test "on: kind capitalized" {
  shell-op::on pod::handle -k pod
  local config
  config="$(shell-op::config)"
  [[ "$(echo "${config}" | jq -r '.kubernetes[0].kind')" == "Pod" ]]
}

@test "on: multiple kinds auto-groups" {
  shell-op::on pod::handle -k Pod -k Service
  local config
  config="$(shell-op::config)"
  [[ "$(echo "${config}" | jq -r '.kubernetes | length')" == "2" ]]
  [[ "$(echo "${config}" | jq -r '.kubernetes[0].group')" == "pod::handle" ]]
  [[ "$(echo "${config}" | jq -r '.kubernetes[1].group')" == "pod::handle" ]]
}

@test "on: explicit group" {
  shell-op::on pod::handle -k Pod -g mesh
  local config
  config="$(shell-op::config)"
  [[ "$(echo "${config}" | jq -r '.kubernetes[0].group')" == "mesh" ]]
}

@test "on: --no-sync" {
  shell-op::on pod::handle -k Pod --no-sync
  local config
  config="$(shell-op::config)"
  [[ "$(echo "${config}" | jq -r '.kubernetes[0].executeHookOnSynchronization')" == "false" ]]
}

@test "on: missing handler fails" {
  run shell-op::on -k Pod
  [[ "${status}" -ne 0 ]]
}

@test "on: missing kind fails" {
  run shell-op::on pod::handle
  [[ "${status}" -ne 0 ]]
}

@test "on: undeclared handler fails" {
  run shell-op::on nonexistent::handler -k Pod
  [[ "${status}" -ne 0 ]]
}

@test "on: --help shows usage" {
  run shell-op::on --help
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == *"Register a Kubernetes watch binding"* ]]
  [[ "${output}" == *"--kind"* ]]
}

@test "on: repeated events accumulate" {
  shell-op::on pod::handle -k Pod -e Added -e Modified -e Deleted
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

@test "cron: missing args fails" {
  run shell-op::cron
  [[ "${status}" -ne 0 ]]
}

@test "cron: undeclared handler fails" {
  run shell-op::cron "*/5 * * * *" nonexistent::handler
  [[ "${status}" -ne 0 ]]
}

@test "cron: --help shows usage" {
  run shell-op::cron --help
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == *"Register a schedule binding"* ]]
}

# ── startup (via shell-op::run) ───────────────────────

@test "startup: --startup in config" {
  local config
  config="$(shell-op::run --config --startup init::handler)"
  [[ "$(echo "${config}" | jq -r '.onStartup')" == "1" ]]
}

@test "startup: custom order" {
  local config
  config="$(shell-op::run --config --startup init::handler --order 10)"
  [[ "$(echo "${config}" | jq -r '.onStartup')" == "10" ]]
}

@test "startup: no --startup means no onStartup in config" {
  local config
  config="$(shell-op::run --config)"
  [[ "$(echo "${config}" | jq 'has("onStartup")')" == "false" ]]
}

@test "startup: undeclared handler fails" {
  run shell-op::run --config --startup nonexistent::handler
  [[ "${status}" -ne 0 ]]
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
  shell-op::cron "*/5 * * * *" cron::handle
  shell-op::on pod::handle -k Pod -e Added

  local config
  config="$(shell-op::run --config --startup init::handler)"
  [[ "$(echo "${config}" | jq 'has("onStartup")')" == "true" ]]
  [[ "$(echo "${config}" | jq 'has("schedule")')" == "true" ]]
  [[ "$(echo "${config}" | jq 'has("kubernetes")')" == "true" ]]
}

# ── shell-op::run ──────────────────────────────────────

@test "run: --config outputs config" {
  shell-op::on pod::handle -k Pod
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
    :args "test" "${@}"
    _result="${event}:${name}:${namespace}"
  }

  shell-op::on pod::handle -k Pod -e Added
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
    :args "test" "${@}"
    _result="${event}:${binding}"
  }

  shell-op::cron "*/5 * * * *" cron::handle
  shell-op::run

  [[ "${_result}" == "Schedule:cron::handle" ]]
}

@test "run: startup calls handler" {
  cat > "${_tmp}/ctx.json" << 'JSON'
[{"binding":"onStartup"}]
JSON
  BINDING_CONTEXT_PATH="${_tmp}/ctx.json"

  _result=""
  init::handler() { _result="started"; }

  shell-op::run --startup init::handler

  [[ "${_result}" == "started" ]]
}

@test "run: startup without --startup is noop" {
  cat > "${_tmp}/ctx.json" << 'JSON'
[{"binding":"onStartup"}]
JSON
  BINDING_CONTEXT_PATH="${_tmp}/ctx.json"

  _result="untouched"
  shell-op::run

  [[ "${_result}" == "untouched" ]]
}

@test "run: unified event prefers watchEvent over type" {
  cat > "${_tmp}/ctx.json" << 'JSON'
[{"type":"Event","binding":"pod::handle","watchEvent":"Modified","object":{"kind":"Pod","metadata":{"name":"nginx","namespace":"default"}}}]
JSON
  BINDING_CONTEXT_PATH="${_tmp}/ctx.json"

  _result=""
  pod::handle() {
    local event
    :args "test" "${@}"
    _result="${event}"
  }

  shell-op::on pod::handle -k Pod
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
    :args "test" "${@}"
    _result="${event}:${type}"
  }

  shell-op::on pod::handle -k Pod
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
    :args "test" "${@}"
    _ctx_result="${ctx}"
  }

  shell-op::on pod::handle -k Pod
  shell-op::run

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
    _call_count=$(( _call_count + 1 ))
  }

  shell-op::on pod::handle -k Pod
  shell-op::run

  [[ "${_call_count}" == "2" ]]
}

@test "run: handler receives watchEvent separately" {
  cat > "${_tmp}/ctx.json" << 'JSON'
[{"type":"Event","binding":"pod::handle","watchEvent":"Deleted","object":{"kind":"Pod","metadata":{"name":"nginx","namespace":"default"}}}]
JSON
  BINDING_CONTEXT_PATH="${_tmp}/ctx.json"

  _result=""
  pod::handle() {
    local event type watchEvent
    :args "test" "${@}"
    _result="${event}:${type}:${watchEvent}"
  }

  shell-op::on pod::handle -k Pod
  shell-op::run

  [[ "${_result}" == "Deleted:Event:Deleted" ]]
}
