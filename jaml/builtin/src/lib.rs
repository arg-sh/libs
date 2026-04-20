//! jaml loadable builtins — native YAML/JSON access for bash.
//!
//! Provides three builtins:
//!   jaml::get  — read fields from a YAML/JSON file into variables or stdout
//!   jaml::set  — write variable values into a YAML/JSON file
//!   jaml::each — iterate array elements, binding fields per element
//!
//! Load: enable -f libjaml.so jaml::get jaml::set jaml::each

use argsh_plugin_shared::{
    self as shell, BashBuiltin, BuiltinFunc, SyncPtr, WordList, BUILTIN_ENABLED,
};
use serde_yaml::Value;
use std::ffi::{c_char, c_int};
use std::sync::Mutex;

// ── Path navigation ─────────────────────────────────────────────

/// Navigate a serde_yaml::Value by dot-separated path.
/// Supports `.foo.bar`, `.foo[0].bar`, and bare `.` for root.
fn navigate<'a>(root: &'a Value, path: &str) -> Option<&'a Value> {
    let path = path.strip_prefix('.').unwrap_or(path);
    if path.is_empty() {
        return Some(root);
    }

    let mut current = root;
    for segment in split_path(path) {
        current = match segment {
            PathSegment::Key(key) => match current {
                Value::Mapping(map) => map.get(Value::String(key.to_string()))?,
                _ => return None,
            },
            PathSegment::Index(idx) => match current {
                Value::Sequence(seq) => seq.get(idx)?,
                _ => return None,
            },
        };
    }
    Some(current)
}

enum PathSegment<'a> {
    Key(&'a str),
    Index(usize),
}

/// Split a path like "foo.bar[0].baz" into segments.
fn split_path(path: &str) -> Vec<PathSegment<'_>> {
    let mut segments = Vec::new();
    for part in path.split('.') {
        if part.is_empty() {
            continue;
        }
        if let Some(bracket_pos) = part.find('[') {
            let key = &part[..bracket_pos];
            if !key.is_empty() {
                segments.push(PathSegment::Key(key));
            }
            // Parse [N] indices — may be chained like [0][1]
            let rest = &part[bracket_pos..];
            let mut remaining = rest;
            while let Some(start) = remaining.find('[') {
                if let Some(end) = remaining[start..].find(']') {
                    let idx_str = &remaining[start + 1..start + end];
                    if let Ok(idx) = idx_str.parse::<usize>() {
                        segments.push(PathSegment::Index(idx));
                    }
                    remaining = &remaining[start + end + 1..];
                } else {
                    break;
                }
            }
        } else {
            segments.push(PathSegment::Key(part));
        }
    }
    segments
}

/// Convert a Value to a display string (scalars as-is, null → empty).
fn value_to_string(v: &Value) -> String {
    match v {
        Value::Null => String::new(),
        Value::Bool(b) => if *b { "true" } else { "false" }.to_string(),
        Value::Number(n) => n.to_string(),
        Value::String(s) => s.clone(),
        // For complex types, output as JSON for composability
        _ => serde_json::to_string(v).unwrap_or_default(),
    }
}

/// Set a value at a dot-separated path in a YAML document (mutable).
/// Creates intermediate mappings as needed.
fn set_at_path(root: &mut Value, path: &str, val: Value) {
    let path = path.strip_prefix('.').unwrap_or(path);
    if path.is_empty() {
        *root = val;
        return;
    }

    let segments = split_path(path);
    let mut current = root;

    for (i, seg) in segments.iter().enumerate() {
        let is_last = i == segments.len() - 1;
        match seg {
            PathSegment::Key(key) => {
                if !current.is_mapping() {
                    *current = Value::Mapping(serde_yaml::Mapping::new());
                }
                let map = current.as_mapping_mut().unwrap();
                let yaml_key = Value::String(key.to_string());
                if is_last {
                    map.insert(yaml_key, val);
                    return;
                }
                if !map.contains_key(&yaml_key) {
                    map.insert(yaml_key.clone(), Value::Mapping(serde_yaml::Mapping::new()));
                }
                current = map.get_mut(&yaml_key).unwrap();
            }
            PathSegment::Index(idx) => {
                if !current.is_sequence() {
                    *current = Value::Sequence(Vec::new());
                }
                let seq = current.as_sequence_mut().unwrap();
                while seq.len() <= *idx {
                    seq.push(Value::Null);
                }
                if is_last {
                    seq[*idx] = val;
                    return;
                }
                current = &mut seq[*idx];
            }
        }
    }
}

// ── File I/O helpers ────────────────────────────────────────────

fn read_yaml_file(path: &str) -> Result<Value, String> {
    if path == "-" {
        let stdin = std::io::stdin();
        serde_yaml::from_reader(stdin.lock()).map_err(|e| format!("parse error: {}", e))
    } else {
        let content = std::fs::read_to_string(path)
            .map_err(|e| format!("{}: {}", path, e))?;
        if content.trim().is_empty() {
            return Ok(Value::Mapping(serde_yaml::Mapping::new()));
        }
        serde_yaml::from_str(&content).map_err(|e| format!("{}: {}", path, e))
    }
}

fn write_yaml_file(path: &str, doc: &Value) -> Result<(), String> {
    let content = serde_yaml::to_string(doc).map_err(|e| format!("serialize: {}", e))?;
    std::fs::write(path, content).map_err(|e| format!("{}: {}", path, e))
}

// ── jaml::get ───────────────────────────────────────────────────

/// jaml::get <file> [var=.path | .path] ...
fn jaml_get(args: &[String]) -> c_int {
    if args.is_empty() {
        shell::write_stderr("jaml::get: usage: jaml::get <file> [var=.path | .path] ...");
        return 2;
    }

    let file = &args[0];
    if args.len() < 2 {
        shell::write_stderr("jaml::get: no fields specified");
        return 1;
    }

    let doc = match read_yaml_file(file) {
        Ok(d) => d,
        Err(e) => {
            shell::write_stderr(&format!("jaml::get: {}", e));
            return 1;
        }
    };

    for arg in &args[1..] {
        if let Some((var, path)) = arg.split_once('=') {
            let val = navigate(&doc, path)
                .map(value_to_string)
                .unwrap_or_default();
            shell::set_scalar(var, &val);
        } else {
            let val = navigate(&doc, arg)
                .map(value_to_string)
                .unwrap_or_default();
            print!("{}", val);
            // Add newline for non-empty output
            if !val.is_empty() {
                println!();
            }
        }
    }

    0
}

// ── jaml::set ───────────────────────────────────────────────────

/// jaml::set <file> [.path=var] ...
fn jaml_set(args: &[String]) -> c_int {
    if args.is_empty() {
        shell::write_stderr("jaml::set: usage: jaml::set <file> [.path=var] ...");
        return 2;
    }

    let file = &args[0];
    if args.len() < 2 {
        shell::write_stderr("jaml::set: no fields specified");
        return 1;
    }

    // Read existing file or start with empty mapping
    let mut doc = if std::path::Path::new(file).exists() {
        match read_yaml_file(file) {
            Ok(d) => d,
            Err(e) => {
                shell::write_stderr(&format!("jaml::set: {}", e));
                return 1;
            }
        }
    } else {
        Value::Mapping(serde_yaml::Mapping::new())
    };

    for arg in &args[1..] {
        // .path=var — split on first '='
        let Some((path, var)) = arg.split_once('=') else {
            shell::write_stderr(&format!("jaml::set: invalid arg '{}' (expected .path=var)", arg));
            return 1;
        };

        let val_str = shell::get_scalar(var).unwrap_or_default();

        // Detect type: try number, bool, then fall back to string
        let yaml_val = if val_str.is_empty() {
            Value::String(String::new())
        } else if let Ok(n) = val_str.parse::<i64>() {
            Value::Number(n.into())
        } else if let Ok(n) = val_str.parse::<f64>() {
            Value::Number(serde_yaml::Number::from(n))
        } else if val_str == "true" {
            Value::Bool(true)
        } else if val_str == "false" {
            Value::Bool(false)
        } else {
            Value::String(val_str)
        };

        set_at_path(&mut doc, path, yaml_val);
    }

    if let Err(e) = write_yaml_file(file, &doc) {
        shell::write_stderr(&format!("jaml::set: {}", e));
        return 1;
    }

    0
}

// ── jaml::each ──────────────────────────────────────────────────

/// Per-iteration state for jaml::each.
struct EachState {
    file: String,
    path: String,
    elements: Vec<Value>,
    index: usize,
}

static EACH_STATE: Mutex<Option<EachState>> = Mutex::new(None);

/// jaml::each <file> <array_path> [var=.field] ...
///
/// On first call (or when file:path changes): parse file, navigate to array,
/// store elements. Each call advances the index and sets variables from the
/// current element. Returns 0 while iterating, 1 when exhausted.
fn jaml_each(args: &[String]) -> c_int {
    if args.len() < 2 {
        shell::write_stderr("jaml::each: usage: jaml::each <file> <array_path> [var=.field] ...");
        return 2;
    }

    let file = &args[0];
    let array_path = &args[1];
    let bindings = &args[2..];

    let mut state_guard = EACH_STATE.lock().unwrap();

    // Check if we need to re-initialize
    let needs_init = match state_guard.as_ref() {
        None => true,
        Some(s) => s.file != *file || s.path != *array_path,
    };

    if needs_init {
        let doc = match read_yaml_file(file) {
            Ok(d) => d,
            Err(e) => {
                shell::write_stderr(&format!("jaml::each: {}", e));
                *state_guard = None;
                return 1;
            }
        };

        // Strip trailing [] from path for navigation
        let nav_path = array_path.trim_end_matches("[]");
        let array_val = if nav_path.is_empty() || nav_path == "." {
            &doc
        } else {
            match navigate(&doc, nav_path) {
                Some(v) => v,
                None => {
                    shell::write_stderr(&format!(
                        "jaml::each: path '{}' not found",
                        nav_path
                    ));
                    *state_guard = None;
                    return 1;
                }
            }
        };

        let elements = match array_val {
            Value::Sequence(seq) => seq.clone(),
            _ => {
                shell::write_stderr(&format!(
                    "jaml::each: '{}' is not an array",
                    nav_path
                ));
                *state_guard = None;
                return 1;
            }
        };

        *state_guard = Some(EachState {
            file: file.clone(),
            path: array_path.clone(),
            elements,
            index: 0,
        });
    }

    let state = state_guard.as_mut().unwrap();

    // Check if exhausted
    if state.index >= state.elements.len() {
        *state_guard = None;
        return 1;
    }

    let element = &state.elements[state.index].clone();
    state.index += 1;

    // Drop lock before setting variables (bind_variable is not reentrant-safe
    // with our lock, but we already extracted what we need).
    drop(state_guard);

    // Set variables from bindings
    for binding in bindings {
        let (var, field_path) = if let Some((v, p)) = binding.split_once('=') {
            (v, p)
        } else {
            // bare name → use as both variable name and .field
            (binding.as_str(), binding.as_str())
        };

        // Prepend dot if not present for navigation
        let nav = if field_path.starts_with('.') {
            field_path.to_string()
        } else {
            format!(".{}", field_path)
        };

        let val = navigate(element, &nav)
            .map(value_to_string)
            .unwrap_or_default();
        shell::set_scalar(var, &val);
    }

    0
}

// ── Builtin registration ────────────────────────────────────────

// jaml::get
static JAML_GET_LONG_DOC: [SyncPtr; 4] = [
    SyncPtr(c"Read fields from a YAML/JSON file.".as_ptr()),
    SyncPtr(c"  var=.path  assigns to bash variable".as_ptr()),
    SyncPtr(c"  .path      prints to stdout".as_ptr()),
    SyncPtr(std::ptr::null()),
];

extern "C" fn jaml_get_fn(wl: *const WordList) -> c_int {
    std::panic::catch_unwind(|| jaml_get(&shell::word_list_to_vec(wl))).unwrap_or(1)
}

#[export_name = "jaml::get_struct"]
pub static mut JAML_GET_STRUCT: BashBuiltin = BashBuiltin {
    name: c"jaml::get".as_ptr(),
    function: jaml_get_fn as BuiltinFunc,
    flags: BUILTIN_ENABLED,
    short_doc: c"jaml::get <file> [var=.path | .path] ...".as_ptr(),
    long_doc: JAML_GET_LONG_DOC.as_ptr().cast(),
    handle: std::ptr::null(),
};

#[export_name = "jaml::get_builtin_load"]
pub extern "C" fn jaml_get_load(_name: *const c_char) -> c_int { 1 }

#[export_name = "jaml::get_builtin_unload"]
pub extern "C" fn jaml_get_unload(_name: *const c_char) {}

// jaml::set
static JAML_SET_LONG_DOC: [SyncPtr; 3] = [
    SyncPtr(c"Write variable values into a YAML/JSON file.".as_ptr()),
    SyncPtr(c"  .path=var  reads bash variable and sets at path".as_ptr()),
    SyncPtr(std::ptr::null()),
];

extern "C" fn jaml_set_fn(wl: *const WordList) -> c_int {
    std::panic::catch_unwind(|| jaml_set(&shell::word_list_to_vec(wl))).unwrap_or(1)
}

#[export_name = "jaml::set_struct"]
pub static mut JAML_SET_STRUCT: BashBuiltin = BashBuiltin {
    name: c"jaml::set".as_ptr(),
    function: jaml_set_fn as BuiltinFunc,
    flags: BUILTIN_ENABLED,
    short_doc: c"jaml::set <file> [.path=var] ...".as_ptr(),
    long_doc: JAML_SET_LONG_DOC.as_ptr().cast(),
    handle: std::ptr::null(),
};

#[export_name = "jaml::set_builtin_load"]
pub extern "C" fn jaml_set_load(_name: *const c_char) -> c_int { 1 }

#[export_name = "jaml::set_builtin_unload"]
pub extern "C" fn jaml_set_unload(_name: *const c_char) {}

// jaml::each
static JAML_EACH_LONG_DOC: [SyncPtr; 4] = [
    SyncPtr(c"Iterate array elements, binding fields per element.".as_ptr()),
    SyncPtr(c"  Returns 0 while iterating, 1 when exhausted.".as_ptr()),
    SyncPtr(c"  Re-initializes when file:path changes.".as_ptr()),
    SyncPtr(std::ptr::null()),
];

extern "C" fn jaml_each_fn(wl: *const WordList) -> c_int {
    std::panic::catch_unwind(|| jaml_each(&shell::word_list_to_vec(wl))).unwrap_or(1)
}

#[export_name = "jaml::each_struct"]
pub static mut JAML_EACH_STRUCT: BashBuiltin = BashBuiltin {
    name: c"jaml::each".as_ptr(),
    function: jaml_each_fn as BuiltinFunc,
    flags: BUILTIN_ENABLED,
    short_doc: c"jaml::each <file> <array_path> [var=.field] ...".as_ptr(),
    long_doc: JAML_EACH_LONG_DOC.as_ptr().cast(),
    handle: std::ptr::null(),
};

#[export_name = "jaml::each_builtin_load"]
pub extern "C" fn jaml_each_load(_name: *const c_char) -> c_int { 1 }

#[export_name = "jaml::each_builtin_unload"]
pub extern "C" fn jaml_each_unload(_name: *const c_char) {}
