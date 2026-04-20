# jaml

Structured data access for YAML/JSON — batch read/write, array iteration, and template rendering for [argsh](https://github.com/arg-sh/argsh).

Replaces repetitive `yq`/`jq` one-liners with clean, batch-optimized bash functions. One `yq` call for N fields instead of N subprocesses.

## Install

```bash
argsh lib add jaml
```

## Usage

### `jaml::get` — batch read

```bash
import jaml

local domain version namespace
jaml::get config.yaml \
  domain=.spec.cluster.domain \
  version=.spec.kubernetes.version \
  namespace='.spec.cluster.namespace // "default"'

# Or output to stdout
echo "Version: $(jaml::get config.yaml .spec.version)"
```

### `jaml::set` — batch write

```bash
local domain="prod.example.com"
local -a servers=(10.0.0.1 10.0.0.2)
local -A labels=(["env"]="prod" ["team"]="infra")

jaml::set config.yaml \
  .spec.cluster.domain=domain \
  .spec.dns.servers=servers \
  .metadata.labels=labels
```

Detects variable type automatically: scalar → string, `-a` → array, `-A` → object.

### `jaml::each` — array iteration

```bash
while jaml::each config.yaml '.spec.nodes.extraMounts[]' \
  host=.hostPath container=.containerPath readonly='.readOnly // false'
do
  echo "${host} → ${container} (readonly: ${readonly})"
done
```

#### Nested arrays with `^` parent access

```bash
while jaml::each <(kubectl get pods -o json) '.items[].spec.containers[]' \
  pod='^.metadata.name' container=.name image=.image
do
  echo "${pod}/${container}: ${image}"
done
```

`^` = parent element, `^^` = grandparent.

### `jaml::render` — template rendering

```bash
jaml::render deployment.tmpl.yaml config.yaml > deployment.yaml
```

Replaces `{{ .path.to.value }}` placeholders with values from the data file.

### `jaml::merge` — deep merge

```bash
jaml::merge base.yaml overlay.yaml > merged.yaml
```

## CLI

Each function is also available as a standalone command:

```bash
# As executable
argsh run jaml get config.yaml .spec.domain
argsh run jaml set config.yaml .spec.domain=domain
argsh run jaml each config.yaml '.items[]' name=.name status=.status
argsh run jaml render template.yaml data.yaml
argsh run jaml merge base.yaml overlay.yaml
```

## Native Builtin (Rust)

Optional `libjaml.so` eliminates the `yq` dependency entirely — all parsing happens in-process via `serde_yaml`/`serde_json`.

```bash
# Build
cd builtin && cargo build --release
# Load
enable -f target/release/libjaml.so jaml::get jaml::set jaml::each
```

~512K with LTO. Falls back to the bash+yq implementation transparently when not loaded.

## Structure

```text
jaml/
├── README.md           # this file
├── argsh-plugin.yml    # metadata
├── jaml                # bash library + CLI executable
├── jaml.bats           # tests (23 tests)
└── builtin/            # Rust native builtin
    ├── Cargo.toml
    └── src/lib.rs
```

## License

MIT
