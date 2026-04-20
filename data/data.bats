#!/usr/bin/env bats
# shellcheck shell=bash disable=SC2034

setup() {
  source "${BATS_TEST_DIRNAME}/data.sh"
  _tmp="$(mktemp -d)"
  cat > "${_tmp}/test.yaml" << 'YAML'
metadata:
  name: myapp
spec:
  cluster:
    domain: prod.example.com
    namespace: default
  kubernetes:
    version: v1.28.0
  nodes:
    controlPlane: 3
    workers: 5
    extraMounts:
      - hostPath: /data
        containerPath: /mnt/data
        readOnly: true
      - hostPath: /logs
        containerPath: /var/log
        readOnly: false
  dns:
    servers:
      - 10.0.0.1
      - 10.0.0.2
YAML
  cat > "${_tmp}/test.json" << 'JSON'
{
  "items": [
    {"name": "pod-1", "node": "worker-1", "status": "Running"},
    {"name": "pod-2", "node": "worker-2", "status": "Pending"},
    {"name": "pod-3", "node": "worker-1", "status": "Running"}
  ]
}
JSON
}

teardown() {
  rm -rf "${_tmp}"
}

# ── data::get ──────────────────────────────────────────

@test "data::get: single value to variable" {
  local domain
  data::get "${_tmp}/test.yaml" domain=.spec.cluster.domain
  [[ "${domain}" == "prod.example.com" ]]
}

@test "data::get: single value to stdout" {
  local result
  result=$(data::get "${_tmp}/test.yaml" .spec.cluster.domain)
  [[ "${result}" == "prod.example.com" ]]
}

@test "data::get: batch read (multiple variables)" {
  local domain version namespace
  data::get "${_tmp}/test.yaml" \
    domain=.spec.cluster.domain \
    version=.spec.kubernetes.version \
    namespace=.spec.cluster.namespace
  [[ "${domain}" == "prod.example.com" ]]
  [[ "${version}" == "v1.28.0" ]]
  [[ "${namespace}" == "default" ]]
}

@test "data::get: mixed stdout and variable" {
  local version
  local stdout_val
  stdout_val=$(data::get "${_tmp}/test.yaml" .metadata.name version=.spec.kubernetes.version)
  [[ "${stdout_val}" == "myapp" ]]
  [[ "${version}" == "v1.28.0" ]]
}

@test "data::get: with default value (// operator)" {
  local missing
  data::get "${_tmp}/test.yaml" missing='.spec.nonexistent // "fallback"'
  [[ "${missing}" == "fallback" ]]
}

@test "data::get: null returns empty string" {
  local val
  data::get "${_tmp}/test.yaml" val=.spec.nonexistent
  [[ "${val}" == "" ]]
}

@test "data::get: length expression" {
  local count
  data::get "${_tmp}/test.yaml" count='.spec.nodes.extraMounts | length'
  [[ "${count}" == "2" ]]
}

@test "data::get: keys expression" {
  local keys
  keys=$(data::get "${_tmp}/test.yaml" '.spec | keys')
  [[ "${keys}" == *"cluster"* ]]
  [[ "${keys}" == *"kubernetes"* ]]
}

@test "data::get: works with JSON files" {
  local name
  data::get "${_tmp}/test.json" name='.items[0].name'
  [[ "${name}" == "pod-1" ]]
}

@test "data::get: stdin support" {
  local name
  name=$(cat "${_tmp}/test.json" | data::get - '.items[0].name')
  [[ "${name}" == "pod-1" ]]
}

@test "data::get: numeric values" {
  local cp workers
  data::get "${_tmp}/test.yaml" cp=.spec.nodes.controlPlane workers=.spec.nodes.workers
  [[ "${cp}" == "3" ]]
  [[ "${workers}" == "5" ]]
}

# ── data::set ──────────────────────────────────────────

@test "data::set: scalar value" {
  local domain="staging.example.com"
  data::set "${_tmp}/test.yaml" .spec.cluster.domain=domain
  local result
  result=$(yq -r '.spec.cluster.domain' "${_tmp}/test.yaml")
  [[ "${result}" == "staging.example.com" ]]
}

@test "data::set: indexed array" {
  local -a servers=(10.0.0.10 10.0.0.11)
  data::set "${_tmp}/test.yaml" .spec.dns.servers=servers
  local count
  count=$(yq -r '.spec.dns.servers | length' "${_tmp}/test.yaml")
  [[ "${count}" == "2" ]]
  local first
  first=$(yq -r '.spec.dns.servers[0]' "${_tmp}/test.yaml")
  [[ "${first}" == "10.0.0.10" ]]
}

@test "data::set: associative array (object)" {
  local -A labels=(["env"]="prod" ["team"]="infra")
  data::set "${_tmp}/test.yaml" .metadata.labels=labels
  local env
  env=$(yq -r '.metadata.labels.env' "${_tmp}/test.yaml")
  [[ "${env}" == "prod" ]]
}

@test "data::set: append to array" {
  local new_server="10.0.0.99"
  data::set "${_tmp}/test.yaml" '.spec.dns.servers[]=new_server'
  local count
  count=$(yq -r '.spec.dns.servers | length' "${_tmp}/test.yaml")
  [[ "${count}" == "3" ]]
}

@test "data::set: multiple fields at once" {
  local domain="new.example.com" namespace="staging"
  data::set "${_tmp}/test.yaml" \
    .spec.cluster.domain=domain \
    .spec.cluster.namespace=namespace
  local d n
  d=$(yq -r '.spec.cluster.domain' "${_tmp}/test.yaml")
  n=$(yq -r '.spec.cluster.namespace' "${_tmp}/test.yaml")
  [[ "${d}" == "new.example.com" ]]
  [[ "${n}" == "staging" ]]
}

# ── data::each ───────────────────────────────────────��─

@test "data::each: iterate yaml array" {
  local -a hosts=() containers=()
  local hostPath containerPath
  while data::each "${_tmp}/test.yaml" '.spec.nodes.extraMounts[]' \
    hostPath=.hostPath containerPath=.containerPath
  do
    hosts+=("${hostPath}")
    containers+=("${containerPath}")
  done
  [[ ${#hosts[@]} -eq 2 ]]
  [[ "${hosts[0]}" == "/data" ]]
  [[ "${containers[1]}" == "/var/log" ]]
}

@test "data::each: iterate json array" {
  local -a names=() nodes=()
  local name node
  while data::each "${_tmp}/test.json" '.items[]' \
    name=.name node=.node
  do
    names+=("${name}")
    nodes+=("${node}")
  done
  [[ ${#names[@]} -eq 3 ]]
  [[ "${names[0]}" == "pod-1" ]]
  [[ "${nodes[2]}" == "worker-1" ]]
}

@test "data::each: process substitution" {
  local -a names=()
  local name
  while data::each <(echo '{"items":[{"n":"a"},{"n":"b"}]}') '.items[]' name=.n; do
    names+=("${name}")
  done
  [[ ${#names[@]} -eq 2 ]]
  [[ "${names[0]}" == "a" ]]
  [[ "${names[1]}" == "b" ]]
}

# ── data::merge ────────────────────────────────────────

@test "data::merge: deep merge two files" {
  cat > "${_tmp}/base.yaml" << 'YAML'
spec:
  domain: base.com
  port: 8080
YAML
  cat > "${_tmp}/overlay.yaml" << 'YAML'
spec:
  domain: overlay.com
  tls: true
YAML
  local result
  result=$(data::merge "${_tmp}/base.yaml" "${_tmp}/overlay.yaml")
  local domain port tls
  domain=$(echo "${result}" | yq -r '.spec.domain')
  port=$(echo "${result}" | yq -r '.spec.port')
  tls=$(echo "${result}" | yq -r '.spec.tls')
  [[ "${domain}" == "overlay.com" ]]
  [[ "${port}" == "8080" ]]
  [[ "${tls}" == "true" ]]
}
