# frozen_string_literal: true

# Build the Rust crate as a Ruby native extension using rb_sys/mkmf.
# create_rust_makefile generates a Makefile that drives `cargo build` and
# installs the resulting cdylib as `carve/carve.so`.
require "mkmf"
require "rb_sys/mkmf"

create_rust_makefile("carve/carve")
