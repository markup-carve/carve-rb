//! Native Ruby binding for the Carve markup language.
//!
//! Wraps the `carve` crate (carve-rs) with magnus, exposing a `Carve` Ruby
//! module:
//!
//! * `Carve.to_html(source)` -> HTML String
//! * `Carve.to_html_with_extensions(source, extensions)` -> HTML String,
//!   where `extensions` is an Array of extension name Strings/Symbols.
//! * `Carve.to_html_full(source, extensions, mode, renderers)` -> HTML String,
//!   the static-render-mode primitive: `mode` is `"interactive"` (default) or
//!   `"static"`; `renderers` is a Hash of build-time renderer callables.
//!
//! The pure-Ruby wrapper in `lib/carve.rb` adds the keyword-argument form
//! `Carve.to_html(source, extensions: [...], mode: ..., renderers: {...})` on
//! top of these primitives.

use carve_rs::{
    Autolink, CarveExtension, Citations, CodeCallouts, Details, ExternalLinks, FencedRender,
    HeadingPermalinks, ListTable, MathBlock, Mode, Options, Spoiler, StaticRenderers, TabNormalize,
    TableOfContents,
    Wikilinks,
};
use magnus::value::{InnerValue, Opaque};
use magnus::{function, prelude::*, Error, RArray, RHash, Ruby, Value};

/// HTML-escape a string for the renderer-failure fallback path.
///
/// carve-rs emits a *present* static renderer's return value verbatim (it is
/// the renderer's job to produce safe HTML). So when our Ruby wrapper has to
/// fall back to the construct source - because the callable raised or returned
/// a non-string - that source MUST be escaped here, or a source containing HTML
/// (e.g. `<img onerror=...>`) would be emitted raw. The no-renderer path inside
/// carve-rs already escapes its `<pre><code>` source block; this keeps the
/// failing-renderer floor equally safe rather than a raw-passthrough hole.
fn escape_html(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for ch in s.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(ch),
        }
    }
    out
}

/// Build an owned, boxed extension instance from a Ruby-facing name.
///
/// Accepts both snake_case (`math_block`) and hyphenated (`math-block`) forms
/// so symbols and strings map cleanly. Returns `None` for an unknown name; the
/// caller turns that into a Ruby `ArgumentError`.
fn extension_for(name: &str) -> Option<Box<dyn CarveExtension>> {
    // Normalize: lowercase, hyphens -> underscores, strip surrounding space.
    let key = name.trim().to_ascii_lowercase().replace('-', "_");
    let ext: Box<dyn CarveExtension> = match key.as_str() {
        "autolink" => Box::new(Autolink::new()),
        "details" => Box::new(Details::new()),
        "list_table" | "listtable" => Box::new(ListTable::new()),
        "math_block" | "mathblock" | "math" => Box::new(MathBlock::new()),
        "heading_permalinks" | "permalinks" => Box::new(HeadingPermalinks::new()),
        "citations" => Box::new(Citations::new()),
        "code_callouts" | "codecallouts" => Box::new(CodeCallouts::new()),
        "tab_normalize" | "tabnormalize" => Box::new(TabNormalize::new()),
        "wikilinks" => Box::new(Wikilinks::new()),
        "external_links" | "externallinks" => Box::new(ExternalLinks::new()),
        // The mermaid preset carries the static-renderer key, so a static
        // render can consult `renderers: {'mermaid' => ...}`. (Plain
        // `FencedRender::new("text")`/`new("mermaid")` would degrade to source
        // even with a renderer supplied, since it has no static-renderer key.)
        // `fenced_render` now maps to the mermaid preset (was the no-key
        // `text` claim before static mode) to match the carve-py sibling and
        // expose a renderer-capable default; `mermaid` is an explicit alias.
        "fenced_render" | "fencedrender" | "mermaid" => Box::new(FencedRender::mermaid()),
        // Graphviz/DOT preset; its static path consults
        // `renderers: {'graphviz' => ...}`, else degrades to the DOT source.
        "fenced_render_graphviz" | "graphviz" | "dot" => Box::new(FencedRender::graphviz()),
        // Chart.js preset (JSON mode); its static path consults
        // `renderers: {'chart' => ...}`, else degrades to the JSON source.
        "fenced_render_chart" | "chart" => Box::new(FencedRender::chart()),
        "spoiler" => Box::new(Spoiler::new()),
        "table_of_contents" | "tableofcontents" | "toc" => Box::new(TableOfContents::new()),
        _ => return None,
    };
    Some(ext)
}

/// Map a Ruby-facing mode string to a carve-rs [`Mode`].
///
/// Rejects any unknown string with `ArgumentError`, mirroring the spec's
/// "MUST reject an unknown mode value" (no guessing) and the unknown-extension
/// error style. Omitting the mode in Ruby defaults to `"interactive"`, so
/// existing callers are unaffected.
fn parse_mode(ruby: &Ruby, mode: &str) -> Result<Mode, Error> {
    match mode {
        "interactive" => Ok(Mode::Interactive),
        "static" => Ok(Mode::Static),
        other => Err(Error::new(
            ruby.exception_arg_error(),
            format!(
                "Unknown Carve render mode: {other:?} (supported: \"interactive\", \"static\")"
            ),
        )),
    }
}

/// Invoke a stored Ruby callable's `call` method with `args`, returning its
/// String result or the HTML-escaped `fallback` on any failure.
///
/// "Any failure" = the callable raised, OR returned a value that is not a
/// String. Both degrade to the escaped fallback so a bad renderer never
/// produces blank output and can never inject raw HTML. The render runs
/// synchronously on the Ruby thread, so `Ruby::get()` succeeds here.
fn call_renderer<A>(callable: &Opaque<Value>, args: A, fallback: &str) -> String
where
    A: magnus::ArgList,
{
    let Ok(ruby) = Ruby::get() else {
        // Not on a Ruby thread - cannot call back; degrade safely.
        return escape_html(fallback);
    };
    let value: Value = callable.get_inner_with(&ruby);
    match value.funcall::<_, _, String>("call", args) {
        Ok(s) => s,
        // Callable raised, or returned a non-String: escaped-source fallback.
        Err(_) => escape_html(fallback),
    }
}

/// Wrap a Ruby diagram callable `(String) -> String` into a carve-rs closure.
///
/// On a raising / non-string-returning callable it degrades to the
/// HTML-escaped source (see [`call_renderer`]).
fn wrap_diagram(callable: Opaque<Value>) -> Box<dyn Fn(&str) -> String + 'static> {
    Box::new(move |src: &str| call_renderer(&callable, (src,), src))
}

/// Wrap a Ruby math callable `(String, bool) -> String` into a carve-rs
/// closure.
///
/// Same contract as [`wrap_diagram`] (including the HTML-escaped fallback), but
/// the callable receives the TeX source and a `display` flag (`true` for block
/// / display math, `false` for inline).
fn wrap_math(callable: Opaque<Value>) -> Box<dyn Fn(&str, bool) -> String + 'static> {
    Box::new(move |tex: &str, display: bool| call_renderer(&callable, (tex, display), tex))
}

/// Build a [`StaticRenderers`] from a Ruby Hash of callables.
///
/// Recognized keys (String or Symbol): `"mermaid"` / `"chart"` / `"graphviz"`
/// (callables `(String) -> String`) and `"math"` (callable
/// `(String, bool) -> String`). Unknown keys raise `ArgumentError`. A missing
/// key leaves that renderer absent, so the matching static path degrades to
/// source.
fn build_renderers(ruby: &Ruby, hash: RHash) -> Result<StaticRenderers, Error> {
    let mut out = StaticRenderers::default();
    // Collect (key, value) pairs; RHash::each is not exposed, so use foreach.
    let mut pairs: Vec<(String, Value)> = Vec::new();
    hash.foreach(|key: Value, value: Value| {
        // Accept both String and Symbol keys via to_string-style coercion.
        let name: String = key.to_r_string()?.to_string()?;
        pairs.push((name, value));
        Ok(magnus::r_hash::ForEach::Continue)
    })?;

    for (name, value) in pairs {
        let callable: Opaque<Value> = Opaque::from(value);
        match name.trim().to_ascii_lowercase().as_str() {
            "mermaid" => out.mermaid = Some(wrap_diagram(callable)),
            "chart" => out.chart = Some(wrap_diagram(callable)),
            "graphviz" => out.graphviz = Some(wrap_diagram(callable)),
            "math" => out.math = Some(wrap_math(callable)),
            other => {
                return Err(Error::new(
                    ruby.exception_arg_error(),
                    format!(
                        "Unknown Carve renderer key: {other:?} (supported: \"mermaid\", \"chart\", \"graphviz\", \"math\")"
                    ),
                ));
            }
        }
    }
    Ok(out)
}

/// Render Carve source to HTML with no extensions enabled.
fn to_html(source: String) -> String {
    carve_rs::to_html(&source)
}

/// Render Carve source to HTML with the named extensions enabled.
///
/// `names` is a Ruby Array of Strings/Symbols. An unrecognized name raises a
/// Ruby `ArgumentError`. Always interactive mode, no renderers.
fn to_html_with_extensions(ruby: &Ruby, source: String, names: RArray) -> Result<String, Error> {
    let boxed = boxed_extensions(ruby, names)?;
    let mut options = Options::new();
    for ext in &boxed {
        options = options.with_extension(ext.as_ref());
    }
    Ok(carve_rs::to_html_with_options(&source, &options))
}

/// Collect owned, boxed extension instances from a Ruby Array of names.
///
/// carve_rs::Options holds `&dyn CarveExtension` with a lifetime tied to the
/// caller's scope, so the boxes must outlive the Options + render call; the
/// caller keeps the returned Vec alive across both.
fn boxed_extensions(ruby: &Ruby, names: RArray) -> Result<Vec<Box<dyn CarveExtension>>, Error> {
    let mut boxed: Vec<Box<dyn CarveExtension>> = Vec::with_capacity(names.len());
    for item in names.into_iter() {
        let name: String = item.to_r_string()?.to_string()?;
        match extension_for(&name) {
            Some(ext) => boxed.push(ext),
            None => {
                return Err(Error::new(
                    ruby.exception_arg_error(),
                    format!("Unknown Carve extension: {name:?}"),
                ));
            }
        }
    }
    Ok(boxed)
}

/// Full static-render-mode primitive: extensions + mode + renderers.
///
/// * `names` - Ruby Array of extension name Strings/Symbols (may be empty).
/// * `mode` - `"interactive"` (default) or `"static"`; unknown raises
///   `ArgumentError`.
/// * `renderers` - Ruby Hash of build-time renderer callables (keys
///   `mermaid` / `chart` / `graphviz` -> `(String) -> String`, `math` ->
///   `(String, bool) -> String`), consulted only on the static HTML path.
fn to_html_full(
    ruby: &Ruby,
    source: String,
    names: RArray,
    mode: String,
    renderers: RHash,
) -> Result<String, Error> {
    let parsed_mode = parse_mode(ruby, &mode)?;
    let static_renderers = build_renderers(ruby, renderers)?;
    let boxed = boxed_extensions(ruby, names)?;

    let mut options = Options::new()
        .with_mode(parsed_mode)
        .with_renderers(static_renderers);
    for ext in &boxed {
        options = options.with_extension(ext.as_ref());
    }
    Ok(carve_rs::to_html_with_options(&source, &options))
}

/// Entry point invoked by Ruby when the extension is loaded.
///
/// `name = "carve"` makes the macro emit the `Init_carve` symbol that matches
/// the compiled object `carve.so` (the [lib] name), even though the crate
/// package is named `carve-rb`.
#[magnus::init(name = "carve")]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let module = ruby.define_module("Carve")?;
    // Native primitives. The pure-Ruby wrapper in lib/carve.rb defines the
    // public `Carve.to_html(source, extensions:, mode:, renderers:)` on top of
    // these. `_to_html` is the no-extension fast path; the wrapper owns the
    // bare `to_html` name.
    module.define_singleton_method("_to_html", function!(to_html, 1))?;
    module.define_singleton_method(
        "to_html_with_extensions",
        function!(to_html_with_extensions, 2),
    )?;
    module.define_singleton_method("to_html_full", function!(to_html_full, 4))?;
    Ok(())
}
