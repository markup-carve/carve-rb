# frozen_string_literal: true

require "rake/testtask"

require "rubygems/package_task"
# rake-compiler provides `compile` (extconf.rb -> Makefile -> cargo build,
# installing the cdylib into lib/carve/) and the `native:<platform>` tasks
# rb-sys-dock runs to build the precompiled gems in release.yml.
#
# Plain Rake::ExtensionTask rather than RbSys::ExtensionTask: the latter finds
# the crate with `cargo metadata` from the repository root, which has no
# Cargo.toml, and names the binary after the crate (`carve-rb`).
require "rake/extensiontask"

GEMSPEC = Gem::Specification.load("carve.gemspec")

# `rake gem` packages the source gem, `rake native:<platform> gem` a platform
# gem carrying lib/carve/<ruby minor>/carve.<dlext> per Ruby ABI.
Gem::PackageTask.new(GEMSPEC).define

Rake::ExtensionTask.new("carve", GEMSPEC) do |ext|
  ext.ext_dir = "ext/carve"
  ext.lib_dir = "lib/carve"
  ext.source_pattern = "**/*.{rs,toml,lock}"
  # rb-sys-dock exports RUBY_TARGET inside its build image.
  ext.cross_compile = ENV.key?("RUBY_TARGET")
  ext.cross_platform = [ENV["RUBY_TARGET"]].compact
  ext.cross_compiling do |spec|
    # A platform gem compiles nothing at install time, so it needs neither
    # rb_sys nor the crate sources.
    spec.dependencies.reject! { |dep| dep.name == "rb_sys" }
    spec.files.reject! { |file| file.start_with?("ext/") }
    spec.extensions.clear
  end
end

# The 0.2 engine has a new contract. The inherited 0.1 tests stay for
# `test_legacy`; these files exercise the 0.2 boundary and the
# version-independent safety and CI checks.
TEST_FILES = FileList[
  "test/v2_test.rb",
  "test/native_host_test.rb",
  "test/panic_unwind_test.rb",
  "test/ci_verdict_test.rb",
  "test/release_gate_wiring_test.rb",
  "test/release_version_test.rb",
]

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = TEST_FILES
  t.warning = false
end

# The same files against an extension that is already in lib/carve/ (CI copies
# in the one the release gate's `gem install` compiled), so no second compile.
Rake::TestTask.new(:test_installed) do |t|
  t.libs << "test" << "lib"
  t.test_files = TEST_FILES
  t.warning = false
end

Rake::TestTask.new(:test_legacy) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false
end

# Always (re)build the native extension before running the tests.
task test: :compile
task test_legacy: :compile

# The remaining 0.1 fixtures are still outside the 0.2 suite, but the 30
# assertions migrated to the 0.2 API run on every next2 CI build.
task :test_ported do
  sh "ruby -Ilib -Itest scripts/check_ported_legacy.rb"
end
task test: :test_ported
task test_installed: :test_ported

task default: %i[compile test]
