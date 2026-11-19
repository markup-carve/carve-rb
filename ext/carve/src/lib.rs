//! Ruby transport for the public Carve 0.2 JSON boundary.
//!
//! Keeping one boundary lets the engine validate options, errors, and tree
//! shapes in the same place as its CLI and other language bindings.
mod host;
mod host_options;

use magnus::{function, prelude::*, Error, RArray, Ruby};
use std::any::Any;
use std::cell::RefCell;
use std::panic::{self, AssertUnwindSafe};
use std::sync::Once;

thread_local! {
    static PANIC_LOCATION: RefCell<Option<String>> = const { RefCell::new(None) };
}

fn install_panic_hook() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let previous = panic::take_hook();
        panic::set_hook(Box::new(move |info| {
            PANIC_LOCATION.with(|slot| {
                *slot.borrow_mut() = info
                    .location()
                    .map(|loc| format!("{}:{}:{}", loc.file(), loc.line(), loc.column()));
            });
            previous(info);
        }));
    });
}

fn panic_error(payload: Box<dyn Any + Send>) -> Error {
    let message = payload
        .downcast_ref::<String>()
        .cloned()
        .or_else(|| payload.downcast_ref::<&str>().map(|s| (*s).to_string()))
        .unwrap_or_else(|| "panic".to_string());
    let message = match PANIC_LOCATION.with(|slot| slot.borrow_mut().take()) {
        Some(at) => format!("the Carve engine panicked at {at}: {message}"),
        None => format!("the Carve engine panicked: {message}"),
    };
    let ruby = unsafe { Ruby::get_unchecked() };
    let class = ruby
        .define_module("Carve")
        .ok()
        .and_then(|module| module.const_get("EnginePanic").ok())
        .unwrap_or_else(|| ruby.exception_runtime_error());
    Error::new(class, message)
}

fn guard<T>(f: impl FnOnce() -> T) -> Result<T, Error> {
    panic::catch_unwind(AssertUnwindSafe(f)).map_err(panic_error)
}

fn g_call_json(request: String) -> Result<String, Error> {
    guard(|| ::carve::api::json::call(&request))
}

// The default parse response is already a JSON tree. Returning it directly
// avoids the public JSON boundary's Tree::read and re-encoding passes.
fn g_parse_json(source: String) -> Result<String, Error> {
    guard(|| ::carve::tree_json(&source, &::carve::Options::default()))
}

fn g_panic_probe() -> Result<String, Error> {
    guard(|| panic!("deliberate panic from the Carve extension panic probe"))
}

fn g_render_host(
    source: String,
    tree_json: Option<String>,
    options_json: String,
    renderer_names: RArray,
    renderer_callbacks: RArray,
    transform_callbacks: RArray,
) -> Result<String, Error> {
    guard(|| {
        host::render_host(
            source,
            tree_json,
            options_json,
            renderer_names,
            renderer_callbacks,
            transform_callbacks,
        )
    })?
}

#[magnus::init(name = "carve")]
fn init(ruby: &Ruby) -> Result<(), Error> {
    install_panic_hook();
    let module = ruby.define_module("Carve")?;
    module.define_error("EnginePanic", ruby.exception_standard_error())?;
    module.define_singleton_method("_call_json", function!(g_call_json, 1))?;
    module.define_singleton_method("_parse_json", function!(g_parse_json, 1))?;
    module.define_singleton_method("_render_host", function!(g_render_host, 6))?;
    module.define_singleton_method("_panic_probe", function!(g_panic_probe, 0))?;
    Ok(())
}
