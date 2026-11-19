//! Ruby callbacks for the native Carve 0.2 extension host.
use ::carve::api::{
    self, Channel, DocumentTransform, Extension, ExtensionDeclaration, RenderContext, Renderer,
    Tree,
};
use magnus::{
    prelude::*,
    value::{BoxValue, Opaque},
    Error, RArray, Ruby, Value,
};
use serde_json::Value as Json;
use std::collections::BTreeMap;

fn host_error(message: impl ToString) -> api::Error {
    api::Error::Option {
        option: "host".into(),
        message: message.to_string(),
    }
}

fn json_module(ruby: &Ruby) -> Result<Value, Error> {
    ruby.eval("JSON")
}

fn json_to_ruby(ruby: &Ruby, value: &Json) -> Result<Value, Error> {
    json_module(ruby)?.funcall("parse", (value.to_string(),))
}

fn ruby_to_json(ruby: &Ruby, value: Value) -> Result<Json, Error> {
    let text: String = json_module(ruby)?.funcall("generate", (value,))?;
    serde_json::from_str(&text).map_err(|e| Error::new(ruby.exception_arg_error(), e.to_string()))
}

struct RubyRenderer(Opaque<Value>);
impl Renderer for RubyRenderer {
    fn render(&self, node: &Json, _cx: &RenderContext<'_>) -> Result<String, api::Error> {
        let ruby = unsafe { Ruby::get_unchecked() };
        let callback = ruby.get_inner(self.0);
        let arg = json_to_ruby(&ruby, node).map_err(host_error)?;
        callback.funcall("call", (arg,)).map_err(host_error)
    }
}

struct RubyTransform(Opaque<Value>);
impl DocumentTransform for RubyTransform {
    fn transform(&self, view: Tree) -> Result<Tree, api::Error> {
        let ruby = unsafe { Ruby::get_unchecked() };
        let callback = ruby.get_inner(self.0);
        let value: Json = serde_json::from_str(&api::encode_tree(&view)).map_err(host_error)?;
        let arg = json_to_ruby(&ruby, &value).map_err(host_error)?;
        let result: Value = callback.funcall("call", (arg,)).map_err(host_error)?;
        let next = ruby_to_json(&ruby, result).map_err(host_error)?;
        api::decode_tree(&next.to_string())
    }
}

fn register(
    host: &mut api::Carve,
    name: String,
    renderers: Vec<(Channel, Box<dyn Renderer>)>,
    transform: Option<Box<dyn DocumentTransform>>,
) -> Result<(), Error> {
    let ruby = unsafe { Ruby::get_unchecked() };
    host.register_extension(Extension {
        declaration: ExtensionDeclaration {
            name,
            version: "1".into(),
            required: false,
            slots: Vec::new(),
        },
        renderers,
        transform,
    })
    .map_err(|e| Error::new(ruby.exception_arg_error(), e.to_string()))
}

/// Each BoxValue roots its callable for the complete synchronous render.
/// Opaque handles in the trait wrappers are accessed only with Ruby's GVL.
pub(super) fn render_host(
    source: String,
    tree_json: Option<String>,
    options_json: String,
    renderer_names: RArray,
    renderer_callbacks: RArray,
    transform_callbacks: RArray,
) -> Result<String, Error> {
    let renderer_names: Vec<String> = renderer_names.to_vec()?;
    let renderer_callbacks: Vec<Value> = (0..renderer_callbacks.len())
        .map(|i| renderer_callbacks.entry(i as isize))
        .collect::<Result<_, _>>()?;
    let transform_callbacks: Vec<Value> = (0..transform_callbacks.len())
        .map(|i| transform_callbacks.entry(i as isize))
        .collect::<Result<_, _>>()?;
    let ruby = unsafe { Ruby::get_unchecked() };
    let roots: Vec<BoxValue<Value>> = renderer_callbacks
        .into_iter()
        .chain(transform_callbacks.iter().copied())
        .map(BoxValue::new)
        .collect();
    let options: Json = serde_json::from_str(&options_json)
        .map_err(|e| Error::new(ruby.exception_arg_error(), e.to_string()))?;
    let mut opts = api::Options::default();
    if let Some(map) = options.as_object() {
        for key in map.keys() {
            if !matches!(key.as_str(), "mode" | "sections" | "rawHtml" | "extensions") {
                return Err(Error::new(
                    ruby.exception_arg_error(),
                    format!("native host does not read option {key}"),
                ));
            }
        }
    }
    if let Some(mode) = options.get("mode").and_then(Json::as_str) {
        opts.mode = match mode {
            "interactive" => api::Mode::Interactive,
            "static" => api::Mode::Static,
            _ => {
                return Err(Error::new(
                    ruby.exception_arg_error(),
                    "mode must be interactive or static",
                ))
            }
        };
    }
    if let Some(sections) = options.get("sections").and_then(Json::as_bool) {
        opts.sections = sections;
    }
    if let Some(raw) = options.get("rawHtml").and_then(Json::as_bool) {
        opts.raw_html = raw;
    }
    let mut host = api::Carve::new();
    if let Some(extensions) = options.get("extensions").and_then(Json::as_array) {
        for name in extensions.iter().filter_map(Json::as_str) {
            host.enable_standard(name, false)
                .map_err(|e| Error::new(ruby.exception_arg_error(), e.to_string()))?;
        }
    }
    let mut grouped: BTreeMap<String, Vec<(Channel, Box<dyn Renderer>)>> = BTreeMap::new();
    for (i, descriptor) in renderer_names.into_iter().enumerate() {
        let (name, channel) = descriptor
            .rsplit_once('\u{1f}')
            .ok_or_else(|| Error::new(ruby.exception_arg_error(), "invalid renderer descriptor"))?;
        let callback = Opaque::from(*roots[i].as_ref());
        let selected = match channel {
            "interactive" => Channel::Interactive,
            "static" => Channel::BuildTime,
            _ => {
                return Err(Error::new(
                    ruby.exception_arg_error(),
                    "invalid renderer channel",
                ))
            }
        };
        grouped
            .entry(name.to_string())
            .or_default()
            .push((selected, Box::new(RubyRenderer(callback))));
    }
    for (name, channels) in grouped {
        register(&mut host, name, channels, None)?;
    }
    let offset = roots.len() - transform_callbacks.len();
    for i in 0..transform_callbacks.len() {
        let callback = Opaque::from(*roots[offset + i].as_ref());
        register(
            &mut host,
            format!("host.transform.{i}"),
            Vec::new(),
            Some(Box::new(RubyTransform(callback))),
        )?;
    }
    let rendered = if let Some(text) = tree_json {
        let tree = api::decode_tree(&text)
            .map_err(|e| Error::new(ruby.exception_arg_error(), e.to_string()))?;
        host.render_tree_with_diagnostics(&tree, &opts)
    } else {
        host.render_with_diagnostics(source.as_str(), &opts)
    }
    .map_err(|e| Error::new(ruby.exception_arg_error(), e.to_string()))?;
    Ok(serde_json::json!({
        "html": rendered.html,
        "diagnostics": rendered.diagnostics,
        "suppressedDiagnostics": rendered.suppressed_diagnostics,
    })
    .to_string())
}
