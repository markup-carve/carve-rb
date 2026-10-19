#!/bin/sh
#
# Install a precompiled platform gem into an empty GEM_HOME, offline, and render
# one line through it.
#
# Usage: scripts/smoke-native-gem.sh <path/to/carve-lang-X.Y.Z-PLATFORM.gem>
#
# POSIX sh so it also runs in the Alpine image that smoke-tests the musl gem.
# `--local` is the point: a platform gem has no dependencies and nothing to
# compile, so an install that needs the network or a toolchain is a failure.

set -eu

gem_file=${1:?usage: $0 <path/to/carve-lang-X.Y.Z-PLATFORM.gem>}
want='<p>A <em>b</em> c</p>'

work="${RUNNER_TEMP:-/tmp}/carve-smoke-$$"
mkdir -p "$work"
GEM_HOME="$work/gems"
GEM_PATH="$GEM_HOME"
export GEM_HOME GEM_PATH
unset RUBYOPT RUBYLIB BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLE_PATH

gem install --local --no-document "$gem_file"

cd "$work"
got=$(ruby -e '
  require "carve"
  home = File.expand_path(ENV.fetch("GEM_HOME"))
  ext = $LOADED_FEATURES.grep(%r{/carve/\d+\.\d+/carve\.[^/]+\z})
  unless ext.length == 1 && File.expand_path(ext.first).start_with?(home)
    abort "no precompiled extension loaded from #{home}: #{$LOADED_FEATURES.grep(/carve/).inspect}"
  end
  spec = Gem.loaded_specs.fetch("carve-lang")
  warn "ruby #{RUBY_VERSION} #{RUBY_PLATFORM}: #{spec.full_name}, extensions=#{spec.extensions.inspect}, loaded #{ext.first}"
  $stdout.binmode
  puts Carve.to_html("A /b/ c")
')

echo "Carve.to_html(\"A /b/ c\") => $got"
if [ "$got" != "$want" ]; then
  echo "::error::expected $want"
  exit 1
fi
