#!/usr/bin/env bats
# shellcheck shell=bash disable=SC2034

setup() {
  source "${BATS_TEST_DIRNAME}/jaml"
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

# ── jaml::get ──────────────────────────────────────────

@test "jaml::get: single value to variable" {
  local domain
  jaml::get "${_tmp}/test.yaml" domain=.spec.cluster.domain
  [[ "${domain}" == "prod.example.com" ]]
}

@test "jaml::get: single value to stdout" {
  local result
  result=$(jaml::get "${_tmp}/test.yaml" .spec.cluster.domain)
  [[ "${result}" == "prod.example.com" ]]
}

@test "jaml::get: batch read (multiple variables)" {
  local domain version namespace
  jaml::get "${_tmp}/test.yaml" \
    domain=.spec.cluster.domain \
    version=.spec.kubernetes.version \
    namespace=.spec.cluster.namespace
  [[ "${domain}" == "prod.example.com" ]]
  [[ "${version}" == "v1.28.0" ]]
  [[ "${namespace}" == "default" ]]
}

@test "jaml::get: mixed stdout and variable" {
  local version
  # Variable assignment + stdout in same call (no subshell — subshells lose namerefs)
  run jaml::get "${_tmp}/test.yaml" .metadata.name
  [[ "${output}" == "myapp" ]]
  # Variable-only call
  jaml::get "${_tmp}/test.yaml" version=.spec.kubernetes.version
  [[ "${version}" == "v1.28.0" ]]
}

@test "jaml::get: with default value (// operator)" {
  local missing
  jaml::get "${_tmp}/test.yaml" missing='.spec.nonexistent // "fallback"'
  [[ "${missing}" == "fallback" ]]
}

@test "jaml::get: null returns empty string" {
  local val
  jaml::get "${_tmp}/test.yaml" val=.spec.nonexistent
  [[ "${val}" == "" ]]
}

@test "jaml::get: length expression" {
  local count
  jaml::get "${_tmp}/test.yaml" count='.spec.nodes.extraMounts | length'
  [[ "${count}" == "2" ]]
}

@test "jaml::get: keys expression" {
  local count
  jaml::get "${_tmp}/test.yaml" count='.spec | keys | length'
  [[ "${count}" == "4" ]]
}

@test "jaml::get: works with JSON files" {
  local name
  jaml::get "${_tmp}/test.json" name='.items[0].name'
  [[ "${name}" == "pod-1" ]]
}

@test "jaml::get: stdin support" {
  local name
  name=$(cat "${_tmp}/test.json" | jaml::get - '.items[0].name')
  [[ "${name}" == "pod-1" ]]
}

@test "jaml::get: numeric values" {
  local cp workers
  jaml::get "${_tmp}/test.yaml" cp=.spec.nodes.controlPlane workers=.spec.nodes.workers
  [[ "${cp}" == "3" ]]
  [[ "${workers}" == "5" ]]
}

# ── jaml::set ──────────────────────────────────────────

@test "jaml::set: scalar value" {
  local domain="staging.example.com"
  jaml::set "${_tmp}/test.yaml" .spec.cluster.domain=domain
  local result
  result=$(yq -r '.spec.cluster.domain' "${_tmp}/test.yaml")
  [[ "${result}" == "staging.example.com" ]]
}

@test "jaml::set: indexed array" {
  local -a servers=(10.0.0.10 10.0.0.11)
  jaml::set "${_tmp}/test.yaml" .spec.dns.servers=servers
  local count
  count=$(yq -r '.spec.dns.servers | length' "${_tmp}/test.yaml")
  [[ "${count}" == "2" ]]
  local first
  first=$(yq -r '.spec.dns.servers[0]' "${_tmp}/test.yaml")
  [[ "${first}" == "10.0.0.10" ]]
}

@test "jaml::set: associative array (object)" {
  local -A labels=(["env"]="prod" ["team"]="infra")
  jaml::set "${_tmp}/test.yaml" .metadata.labels=labels
  local env
  env=$(yq -r '.metadata.labels.env' "${_tmp}/test.yaml")
  [[ "${env}" == "prod" ]]
}

@test "jaml::set: append to array" {
  local new_server="10.0.0.99"
  jaml::set "${_tmp}/test.yaml" '.spec.dns.servers[]=new_server'
  local count
  count=$(yq -r '.spec.dns.servers | length' "${_tmp}/test.yaml")
  [[ "${count}" == "3" ]]
}

@test "jaml::set: multiple fields at once" {
  local domain="new.example.com" namespace="staging"
  jaml::set "${_tmp}/test.yaml" \
    .spec.cluster.domain=domain \
    .spec.cluster.namespace=namespace
  local d n
  d=$(yq -r '.spec.cluster.domain' "${_tmp}/test.yaml")
  n=$(yq -r '.spec.cluster.namespace' "${_tmp}/test.yaml")
  [[ "${d}" == "new.example.com" ]]
  [[ "${n}" == "staging" ]]
}

# ── jaml::each ───────────────────────────────────────��─

@test "jaml::each: iterate yaml array" {
  local -a hosts=() containers=()
  local hostPath containerPath
  while jaml::each "${_tmp}/test.yaml" '.spec.nodes.extraMounts[]' \
    hostPath=.hostPath containerPath=.containerPath
  do
    hosts+=("${hostPath}")
    containers+=("${containerPath}")
  done
  [[ ${#hosts[@]} -eq 2 ]]
  [[ "${hosts[0]}" == "/data" ]]
  [[ "${containers[1]}" == "/var/log" ]]
}

@test "jaml::each: iterate json array" {
  local -a names=() nodes=()
  local name node
  while jaml::each "${_tmp}/test.json" '.items[]' \
    name=.name node=.node
  do
    names+=("${name}")
    nodes+=("${node}")
  done
  [[ ${#names[@]} -eq 3 ]]
  [[ "${names[0]}" == "pod-1" ]]
  [[ "${nodes[2]}" == "worker-1" ]]
}

@test "jaml::each: process substitution" {
  local -a names=()
  local name
  while jaml::each <(echo '{"items":[{"n":"a"},{"n":"b"}]}') '.items[]' name=.n; do
    names+=("${name}")
  done
  [[ ${#names[@]} -eq 2 ]]
  [[ "${names[0]}" == "a" ]]
  [[ "${names[1]}" == "b" ]]
}

# ── jaml::merge ────────────────────────────────────────

@test "jaml::merge: deep merge two files" {
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
  result=$(jaml::merge "${_tmp}/base.yaml" "${_tmp}/overlay.yaml")
  local domain port tls
  domain=$(echo "${result}" | yq -r '.spec.domain')
  port=$(echo "${result}" | yq -r '.spec.port')
  tls=$(echo "${result}" | yq -r '.spec.tls')
  [[ "${domain}" == "overlay.com" ]]
  [[ "${port}" == "8080" ]]
  [[ "${tls}" == "true" ]]
}

# ── jaml::each with ^ parent access ──────────────────

@test "jaml::each: parent access with ^" {
  cat > "${_tmp}/nested.json" << 'JSON'
{"items":[{"name":"pod-1","containers":[{"name":"nginx","image":"nginx:1.25"},{"name":"sidecar","image":"envoy:1.28"}]},{"name":"pod-2","containers":[{"name":"app","image":"myapp:2.0"}]}]}
JSON
  local -a results=()
  local pod container
  while jaml::each "${_tmp}/nested.json" '.items[].containers[]' \
    pod='^.name' container=.name
  do
    results+=("${pod}/${container}")
  done
  [[ ${#results[@]} -eq 3 ]]
  [[ "${results[0]}" == "pod-1/nginx" ]]
  [[ "${results[1]}" == "pod-1/sidecar" ]]
  [[ "${results[2]}" == "pod-2/app" ]]
}

# ── jaml::render ──────────────────────────────────────

@test "jaml::render: basic template" {
  cat > "${_tmp}/tmpl.yaml" << 'YAML'
server:
  host: {{ .spec.domain }}
  port: {{ .spec.port }}
YAML
  cat > "${_tmp}/data.yaml" << 'YAML'
spec:
  domain: prod.example.com
  port: 8443
YAML
  local result
  result="$(jaml::render "${_tmp}/tmpl.yaml" "${_tmp}/data.yaml")"
  [[ "${result}" == *"host: prod.example.com"* ]]
  [[ "${result}" == *"port: 8443"* ]]
}

@test "jaml::render: missing values render empty" {
  cat > "${_tmp}/tmpl.txt" << 'TXT'
Hello {{ .name }}, welcome to {{ .missing }}!
TXT
  cat > "${_tmp}/data.yaml" << 'YAML'
name: world
YAML
  local result
  result="$(jaml::render "${_tmp}/tmpl.txt" "${_tmp}/data.yaml")"
  [[ "${result}" == "Hello world, welcome to !" ]]
}
