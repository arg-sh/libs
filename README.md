<h3 align="center">
	<img src="https://raw.githubusercontent.com/arg-sh/argsh/main/argsh.svg" width="48" alt="argsh logo"/>
	<br/>
	argsh libs
</h3>

<h6 align="center">
  <a href="https://arg.sh/plugins/overview">Overview</a>
  ·
  <a href="https://arg.sh/plugins/authoring">Authoring</a>
  ·
  <a href="https://github.com/arg-sh/argsh">argsh</a>
</h6>

<p align="center">
	<a href="https://github.com/arg-sh/libs/stargazers">
		<img alt="Stargazers" src="https://img.shields.io/github/stars/arg-sh/libs?style=for-the-badge&logo=starship&color=C9CBFF&logoColor=D9E0EE&labelColor=302D41"></a>
	<a href="https://github.com/arg-sh/libs/releases/latest">
		<img alt="Releases" src="https://img.shields.io/github/release/arg-sh/libs.svg?style=for-the-badge&logo=github&color=F2CDCD&logoColor=D9E0EE&labelColor=302D41"/></a>
</p>

&nbsp;

<p align="left">
Official plugin libraries for <a href="https://github.com/arg-sh/argsh">argsh</a> — installable via <code>argsh lib add</code>. Each library is both an importable module and a standalone CLI executable.
</p>

&nbsp;

### 📦 Install

```bash
# Add a library to your project
argsh lib add jaml

# Or install globally
argsh lib add --global jaml
```

Libraries install to `.argsh/libs/` (project-local) or `~/.local/share/argsh/libs/` (global). The import system resolves them automatically.

&nbsp;

### 📚 Libraries

| Library | Description | Version | Builtin |
|---------|-------------|---------|---------|
| [`jaml`](jaml/) | Structured data access for YAML/JSON — batch read/write, array iteration, template rendering | 0.1.0 | [`libjaml.so`](jaml/builtin/) |

&nbsp;

### 🧪 Usage

Each library works two ways — as an imported module or as a standalone executable:

```bash
#!/usr/bin/env argsh

# As a library
import jaml

local domain version
jaml::get config.yaml \
  domain=.spec.cluster.domain \
  version=.spec.kubernetes.version

# Iterate arrays
while jaml::each config.yaml '.spec.nodes[]' \
  name=.hostname role=.role
do
  echo "${name} (${role})"
done

# Render templates
jaml::render deployment.tmpl.yaml config.yaml > deployment.yaml
```

```bash
# As a CLI executable
argsh run jaml get config.yaml .spec.domain
argsh run jaml set config.yaml .spec.domain=domain
argsh run jaml each config.yaml '.items[]' name=.name
```

&nbsp;

### ⚡ Native Builtins (Rust)

Libraries can ship optional Rust builtins for zero-subprocess performance. When the `.so` is available, the bash wrappers are bypassed entirely.

```bash
# Build the jaml builtin
cd jaml-builtin && cargo build --release
# Output: target/release/libjaml.so

# Load into bash
enable -f target/release/libjaml.so jaml::get jaml::set jaml::each
```

The Cargo workspace compiles all builtin crates together, sharing dependencies (`serde`, `serde_yaml`, `serde_json`) across libraries.

| Crate | Output | Size |
|---|---|---|
| `jaml/builtin` | `libjaml.so` | ~512K |
| `shared` | (static lib) | — |

&nbsp;

### 🗂️ Structure

```text
<lib>/
├── README.md           # library documentation
├── argsh-plugin.yml    # metadata (name, version, requires)
├── <lib>               # executable argsh script (import + CLI)
├── <lib>.bats          # tests
└── builtin/            # optional Rust builtin
    ├── Cargo.toml
    └── src/lib.rs
```

&nbsp;

### 🔧 Development

```bash
# Run tests for a specific lib
argsh test jaml/jaml.bats

# Run all tests
argsh test */*.bats

# Build Rust builtins
cargo build --release

# Run Rust tests
cargo test
```

&nbsp;

### 🚀 Publishing

Libraries are distributed as OCI artifacts via `ghcr.io/arg-sh/libs`. Each file becomes a separate OCI layer with a typed media type.

```bash
# Publish from library directory
cd jaml && argsh lib publish

# Publish to a custom registry
argsh lib publish --registry harbor.mycompany.com/argsh
```

&nbsp;

### 📜 License

MIT — see [LICENSE](https://github.com/arg-sh/argsh/blob/main/LICENSE).

&nbsp;

<p align="center">Copyright &copy; 2026-present <a href="https://github.com/fentas" target="_blank">Jan Guth</a>
<p align="center"><a href="https://github.com/arg-sh/argsh/blob/main/LICENSE"><img src="https://img.shields.io/static/v1.svg?style=for-the-badge&label=License&message=MIT&logoColor=d9e0ee&colorA=302d41&colorB=b7bdf8"/></a></p>
