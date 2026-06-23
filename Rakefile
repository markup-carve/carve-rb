# frozen_string_literal: true

require "rake/testtask"

# rake-compiler provides the `compile` task that drives extconf.rb ->
# Makefile -> cargo build, installing the cdylib into lib/carve/.
require "rake/extensiontask"

GEMSPEC = Gem::Specification.load("carve.gemspec")

Rake::ExtensionTask.new("carve", GEMSPEC) do |ext|
  # The Rust crate lives here; extconf.rb (rb_sys/mkmf) builds it.
  ext.ext_dir = "ext/carve"
  # Install the compiled object under lib/carve/ so `require "carve/carve"`
  # finds it.
  ext.lib_dir = "lib/carve"
end

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false
end

# Always (re)build the native extension before running the tests.
task test: :compile

task default: %i[compile test]
