# argsh libs

Official plugin libraries for [argsh](https://github.com/arg-sh/argsh).

## Libraries

| Library | Description | Builtin |
|---------|-------------|---------|
| [data](data/) | Structured data access for YAML/JSON | Planned |

## Usage

```bash
# Add to your project
argsh lib add argsh@data

# Use in scripts
import data
data::get config.yaml domain=.spec.cluster.domain
```

## Structure

Each library is self-contained:

```text
<lib>/
├── argsh-plugin.yml    # metadata
├── <lib>.sh            # bash library
├── <lib>.bats          # tests
└── src/                # optional Rust builtin
    ├── Cargo.toml
    └── lib.rs
```

## Development

```bash
# Run tests for a specific lib
bats data/data.bats

# Run all tests
bats *//*.bats
```

## Publishing

Libraries are distributed as OCI artifacts via `ghcr.io/arg-sh/libs`.
