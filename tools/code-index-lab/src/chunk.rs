// Split source files into definition-level chunks with tree-sitter.
use serde::{Deserialize, Serialize};
use std::path::Path;
use tree_sitter::{Node, Parser};

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Chunk {
    pub path: String,
    pub start: usize, // 1-based, inclusive
    pub end: usize,
    pub symbol: String,
    pub kind: String,
    pub text: String,
}

const MAX_LINES: usize = 120; // longer definitions are split into windows
const WIN: usize = 80;
const OVERLAP: usize = 10;
const GAP_WIN: usize = 60;

pub fn chunk_repo(root: &Path, dirs: &[&str]) -> anyhow::Result<Vec<Chunk>> {
    let mut out = Vec::new();
    for d in dirs {
        for e in ignore::WalkBuilder::new(root.join(d)).build() {
            let e = e?;
            let p = e.path();
            let ext = p.extension().and_then(|s| s.to_str()).unwrap_or("");
            if !matches!(ext, "rs" | "ts" | "tsx") || p.to_string_lossy().ends_with(".d.ts") {
                continue;
            }
            let src = std::fs::read_to_string(p)?;
            let rel = p.strip_prefix(root)?.to_string_lossy().to_string();
            out.extend(chunk_file(&rel, ext, &src));
        }
    }
    Ok(out)
}

struct Def {
    start: usize, // 0-based row
    end: usize,
    symbol: String,
    kind: String,
}

pub fn chunk_file(rel: &str, ext: &str, src: &str) -> Vec<Chunk> {
    let mut parser = Parser::new();
    let lang: tree_sitter::Language = match ext {
        "rs" => tree_sitter_rust::LANGUAGE.into(),
        "tsx" => tree_sitter_typescript::LANGUAGE_TSX.into(),
        _ => tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(),
    };
    parser.set_language(&lang).expect("grammar");
    let tree = parser.parse(src, None).expect("parse");
    let mut defs = Vec::new();
    collect(tree.root_node(), src, "", &mut defs);
    defs.sort_by_key(|d| d.start);

    let lines: Vec<&str> = src.lines().collect();
    let mut covered = vec![false; lines.len()];
    let mut out = Vec::new();
    for d in &defs {
        let end = d.end.min(lines.len().saturating_sub(1));
        if covered[d.start..=end].iter().all(|c| *c) {
            continue; // nested in an already emitted definition
        }
        for c in &mut covered[d.start..=end] {
            *c = true;
        }
        emit(rel, &lines, d.start, end, &d.symbol, &d.kind, &mut out);
    }
    // Code outside any definition: imports, top-level statements, JSX roots.
    let mut i = 0;
    while i < lines.len() {
        if covered[i] {
            i += 1;
            continue;
        }
        let s = i;
        while i < lines.len() && !covered[i] && i - s < GAP_WIN {
            i += 1;
        }
        if lines[s..i].iter().any(|l| !l.trim().is_empty()) {
            emit(rel, &lines, s, i - 1, "", "gap", &mut out);
        }
    }
    out
}

fn emit(
    rel: &str,
    lines: &[&str],
    s: usize,
    e: usize,
    sym: &str,
    kind: &str,
    out: &mut Vec<Chunk>,
) {
    let mut push = |a: usize, b: usize| {
        out.push(Chunk {
            path: rel.to_string(),
            start: a + 1,
            end: b + 1,
            symbol: sym.to_string(),
            kind: kind.to_string(),
            text: lines[a..=b].join("\n"),
        })
    };
    if e - s + 1 <= MAX_LINES {
        return push(s, e);
    }
    let mut a = s;
    loop {
        let b = (a + WIN - 1).min(e);
        push(a, b);
        if b == e {
            break;
        }
        a = b + 1 - OVERLAP;
    }
}

fn name_of(n: Node, src: &str) -> String {
    n.child_by_field_name("name")
        .map(|c| src[c.byte_range()].to_string())
        .unwrap_or_default()
}

fn collect(n: Node, src: &str, scope: &str, defs: &mut Vec<Def>) {
    let kind = n.kind();
    let (start, end) = (n.start_position().row, n.end_position().row);
    let qual = |name: &str| {
        if scope.is_empty() {
            name.to_string()
        } else {
            format!("{scope}::{name}")
        }
    };
    match kind {
        // Rust
        "function_item" | "struct_item" | "enum_item" | "trait_item" | "macro_definition"
        | "const_item" | "static_item" | "type_item"
        // TypeScript
        | "function_declaration" | "interface_declaration" | "type_alias_declaration"
        | "enum_declaration" | "method_definition" => {
            defs.push(Def { start, end, symbol: qual(&name_of(n, src)), kind: kind.into() });
            // Nested closures/handlers inside big functions are reached by windowing.
            return;
        }
        "impl_item" => {
            let ty = n.child_by_field_name("type").map(|c| src[c.byte_range()].to_string()).unwrap_or_default();
            let mut cur = n.walk();
            for c in n.children(&mut cur) {
                collect(c, src, &ty, defs);
            }
            return;
        }
        "class_declaration" | "mod_item" => {
            let nm = name_of(n, src);
            let mut cur = n.walk();
            for c in n.children(&mut cur) {
                collect(c, src, &nm, defs);
            }
            return;
        }
        "lexical_declaration" | "variable_declaration" => {
            // const foo = (...) => ... / function(...) / useCallback(...)
            let mut cur = n.walk();
            for d in n.named_children(&mut cur) {
                if d.kind() != "variable_declarator" {
                    continue;
                }
                let nm = name_of(d, src);
                let is_fn = d
                    .child_by_field_name("value")
                    .map(|v| matches!(v.kind(), "arrow_function" | "function_expression" | "function" | "call_expression" | "object"))
                    .unwrap_or(false);
                if is_fn && !nm.is_empty() && end > start {
                    defs.push(Def { start, end, symbol: qual(&nm), kind: "const".into() });
                }
            }
            return;
        }
        _ => {}
    }
    let mut cur = n.walk();
    for c in n.children(&mut cur) {
        collect(c, src, scope, defs);
    }
}
