# Prepare the next engine patch

This draft adds regression coverage for [the published engine gap](https://github.com/markup-carve/carve-rb/issues/142).
The committed dependency remains `carve-lang =0.1.6`. Rust 0.1.7 must be
published with the required fixes before this draft can be completed.

Before marking the PR ready:

1. Verify the published 0.1.7 crate includes the fixes and its release tag resolves
   to the tested Rust commit.
2. Set the exact engine requirement in `ext/carve/Cargo.toml` to `=0.1.7`.
3. Regenerate `ext/carve/Cargo.lock` from the registry:

```sh
CARGO_RESOLVER_INCOMPATIBLE_RUST_VERSIONS=fallback \
cargo update --manifest-path ext/carve/Cargo.toml -p carve-lang --precise 0.1.7
```

4. Build and test the published dependency:

```sh
CARVE_SPEC_CORPUS=/path/to/carve/tests/corpus bundle exec rake compile test
CARVE_ENGINE_BIN=/path/to/carve-rs/target/release/carve \
CARVE_PINNED_ENGINE_BIN=/path/to/carve-rs-0.1.7/target/release/carve \
CARVE_PARITY_CORPUS=/path/to/carve/tests/corpus \
CARVE_REQUIRE_PARITY=1 bundle exec ruby -Ilib -Itest test/binding_parity_test.rb
```

Remove this preparation checklist when completing the pin update.

Keep the draft open if the regressions or full corpus checks fail. Local path
substitutions are development checks; the final manifest and lock must resolve
the published crate.
