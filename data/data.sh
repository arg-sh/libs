#!/usr/bin/env bash
# @file data
# @brief Structured data access for YAML/JSON
# @description
#   Read and write structured data (YAML/JSON) with clean bash syntax.
#   Wraps yq for batch operations — single subprocess for N fields.
#
#   Usage:
#     data::get <file> [var=.path | .path] ...   # read fields
#     data::set <file> [.path=var] ...            # write fields
#     data::each <file> <array-path> [var=.field] ... # iterate arrays
#     data::merge <base> <overlay> ...            # deep merge files
set -euo pipefail

# @description Read fields from a YAML/JSON file.
#   var=.path → assigns to variable (nameref)
#   .path     → outputs to stdout
#   Supports any yq expression: .path // "default", .path | length, .path | keys
# @arg $1 string File path (or - for stdin)
# @arg $@ string Field bindings (var=.path or .path)
# @example
#   # Batch read into variables (1 yq call)
#   local domain version
#   data::get config.yaml domain=.spec.domain version=.spec.version
#
#   # Single value to stdout
#   echo "Version: $(data::get config.yaml .spec.version)"
#
#   # Mixed
#   data::get config.yaml .spec.version count='.items | length'
data::get() {
  local _file="${1}"; shift
  [[ $# -gt 0 ]] || { echo "data::get: no fields specified" >&2; return 1; }

  local -a _var_names=() _expressions=()
  local _arg

  # Parse arguments: var=.expr or .expr
  for _arg in "${@}"; do
    if [[ "${_arg}" == *=* ]]; then
      _var_names+=("${_arg%%=*}")
      _expressions+=("${_arg#*=}")
    else
      _var_names+=("")
      _expressions+=("${_arg}")
    fi
  done

  # Build single yq expression: [(.expr1 // ""), (.expr2 // ""), ...] | .[]
  local _yq_expr="" _i _expr
  for (( _i=0; _i < ${#_expressions[@]}; _i++ )); do
    _expr="${_expressions[_i]}"
    # Don't wrap expressions that already handle null (contain //)
    if [[ "${_expr}" == *"//"* ]]; then
      [[ -z "${_yq_expr}" ]] || _yq_expr+=", "
      _yq_expr+="(${_expr})"
    else
      [[ -z "${_yq_expr}" ]] || _yq_expr+=", "
      _yq_expr+="(${_expr} // \"\")"
    fi
  done

  # Single yq call — one line per expression
  local -a _values=()
  local _src="${_file}"
  [[ "${_file}" != "-" ]] || _src="/dev/stdin"
  mapfile -t _values < <(yq -r "[${_yq_expr}] | .[]" "${_src}")

  # Assign results
  for (( _i=0; _i < ${#_var_names[@]}; _i++ )); do
    if [[ -n "${_var_names[_i]}" ]]; then
      # shellcheck disable=SC2178
      local -n _ref="${_var_names[_i]}"
      _ref="${_values[_i]:-}"
    else
      echo "${_values[_i]:-}"
    fi
  done
}

# @description Write fields from variables into a YAML/JSON file.
#   .path=var   → overwrite path with variable value
#   .path[]=var → append to array
#   Detects scalar, indexed array (-a), and associative array (-A).
# @arg $1 string File path
# @arg $@ string Field bindings (.path=var)
# @example
#   domain="prod.example.com"
#   data::set config.yaml .spec.domain=domain
#
#   local -A labels=(["env"]="prod" ["team"]="infra")
#   data::set config.yaml .metadata.labels=labels
data::set() {
  local _file="${1}"; shift
  [[ $# -gt 0 ]] || { echo "data::set: no fields specified" >&2; return 1; }

  local _yq_expr="" _arg _path _var

  for _arg in "${@}"; do
    _path="${_arg%%=*}"
    _var="${_arg#*=}"

    # shellcheck disable=SC2178
    local -n _ref="${_var}"

    local _append=0
    if [[ "${_path}" == *"[]" ]]; then
      _append=1
      _path="${_path%\[\]}"
    fi

    # Detect variable type
    local _type
    _type="$(declare -p "${_var}" 2>/dev/null)" || _type=""

    if [[ "${_type}" == *"declare -A"* ]]; then
      # Associative array → JSON object
      local _json="{"
      local _k _first=1
      for _k in "${!_ref[@]}"; do
        (( _first )) && _first=0 || _json+=","
        _json+="\"${_k}\":\"${_ref[${_k}]}\""
      done
      _json+="}"
      if (( _append )); then
        _yq_expr+=" | ${_path} += [${_json}]"
      else
        _yq_expr+=" | ${_path} = ${_json}"
      fi
    elif [[ "${_type}" == *"declare -a"* ]]; then
      # Indexed array → JSON array
      local _json="[" _v _first=1
      for _v in "${_ref[@]}"; do
        (( _first )) && _first=0 || _json+=","
        _json+="\"${_v}\""
      done
      _json+="]"
      if (( _append )); then
        _yq_expr+=" | ${_path} += ${_json}"
      else
        _yq_expr+=" | ${_path} = ${_json}"
      fi
    else
      # Scalar
      if (( _append )); then
        _yq_expr+=" | ${_path} += [\"${_ref}\"]"
      else
        _yq_expr+=" | ${_path} = \"${_ref}\""
      fi
    fi
  done

  yq -i "${_yq_expr:3}" "${_file}"  # strip leading " | "
}

# @description Iterate array elements, binding fields per element.
#   Reads the entire array in a single yq call, iterates via read.
# @arg $1 string File path (or process substitution)
# @arg $2 string Array path with [] (e.g. '.items[]')
# @arg $@ string Field bindings (var=.field)
# @example
#   while data::each config.yaml '.spec.nodes[]' name=.hostname role=.role; do
#     echo "${name}: ${role}"
#   done
#
#   while data::each <(kubectl get pods -o json) '.items[]' \
#     pod=.metadata.name node=.spec.nodeName; do
#     echo "${pod} on ${node}"
#   done

# Internal state for data::each iteration
declare -g __DATA_EACH_LINES=""
declare -gi __DATA_EACH_IDX=0
declare -g __DATA_EACH_FILE=""
declare -g __DATA_EACH_PATH=""

data::each() {
  local _file="${1}" _path="${2}"; shift 2

  # Detect new iteration (different file/path or first call)
  if [[ "${_file}:${_path}" != "${__DATA_EACH_FILE}:${__DATA_EACH_PATH}" ]]; then
    # Build yq expression for all fields as TSV
    local -a _fields=() _var_names=()
    local _arg
    for _arg in "${@}"; do
      if [[ "${_arg}" == *=* ]]; then
        _var_names+=("${_arg%%=*}")
        _fields+=("${_arg#*=}")
      else
        _var_names+=("${_arg}")
        _fields+=(".${_arg}")
      fi
    done

    local _yq_fields=""
    local _f
    for _f in "${_fields[@]}"; do
      [[ -z "${_yq_fields}" ]] || _yq_fields+=", "
      _yq_fields+="(${_f} // \"\")"
    done

    local _src="${_file}"
    [[ "${_file}" != "-" ]] || _src="/dev/stdin"
    __DATA_EACH_LINES=$(yq -r "${_path} | [${_yq_fields}] | @tsv" "${_src}")
    __DATA_EACH_IDX=0
    __DATA_EACH_FILE="${_file}"
    __DATA_EACH_PATH="${_path}"
  fi

  # Read next line
  __DATA_EACH_IDX=$(( __DATA_EACH_IDX + 1 ))
  local _line
  _line=$(sed -n "${__DATA_EACH_IDX}p" <<< "${__DATA_EACH_LINES}") || {
    __DATA_EACH_FILE=""
    return 1
  }
  [[ -n "${_line}" ]] || { __DATA_EACH_FILE=""; return 1; }

  # Parse TSV and assign to variables
  local -a _var_names=()
  local _arg
  for _arg in "${@}"; do
    if [[ "${_arg}" == *=* ]]; then
      _var_names+=("${_arg%%=*}")
    else
      _var_names+=("${_arg}")
    fi
  done

  local IFS=$'\t'
  local -a _vals
  read -ra _vals <<< "${_line}"

  local _i
  for (( _i=0; _i < ${#_var_names[@]}; _i++ )); do
    # shellcheck disable=SC2178
    local -n _ref="${_var_names[_i]}"
    _ref="${_vals[_i]:-}"
  done
}

# @description Deep merge YAML/JSON files. Later files override earlier ones.
# @arg $@ string Files to merge (at least 2)
# @stdout Merged YAML output
# @example
#   data::merge base.yaml overlay.yaml > merged.yaml
data::merge() {
  [[ $# -ge 2 ]] || { echo "data::merge: need at least 2 files" >&2; return 1; }
  yq eval-all '. as $item ireduce ({}; . * $item)' "${@}"
}
