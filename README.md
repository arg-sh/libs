# argsh libs

Official plugin libraries for [argsh](https://github.com/arg-sh/argsh).

## Libraries

| Library | Description | Builtin |
|---------|-------------|---------|
| [jaml](jaml/) | Structured data access for YAML/JSON | Planned |

## Usage

```bash
# Add to your project
argsh lib add jaml

# Use as library (import)
import jaml
jaml::get config.yaml domain=.spec.cluster.domain

# Use as CLI (executable)
argsh run jaml get config.yaml .spec.domain
# or execute directly
.argsh/libs/jaml/jaml set config.yaml .spec.domain="example.com"
```

## Structure

Each library is both an importable library and a standalone executable:

```text
<lib>/
├── argsh-plugin.yml    # metadata
├── <lib>               # executable argsh script (import + CLI)
├── <lib>.bats          # tests
└── src/                # optional Rust builtin
    ├── Cargo.toml
    └── lib.rs
```

## Development

```bash
# Run tests for a specific lib
bats jaml/jaml.bats

# Run all tests
bats */*.bats
```

## Publishing

Libraries are distributed as OCI artifacts via `ghcr.io/arg-sh/libs`.
