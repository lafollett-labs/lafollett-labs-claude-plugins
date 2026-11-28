### Added
- **sdlc**: two review agents. `pe-rust` reviews Cargo workspaces, idiomatic Rust,
  `unsafe` and FFI, and WebAssembly via wasm-bindgen, checks each exported signature
  against its TypeScript call sites, and runs `cargo fmt --check`, clippy with
  `-D warnings`, `cargo test` and the wasm32 build. `pe-devtools` reviews local dev
  scripts, git hooks and hook config under a single-operator threat model, and hands
  workflows and infrastructure to `pe-github-actions` and `pe-aws-infra`. `review`
  routes `*.rs`, `Cargo.toml`, `Cargo.lock`, `rust-toolchain*` and `.cargo/config(.toml)`
  to `pe-rust`, and shell scripts under `scripts/dev/`, `.githooks/**`, `.husky/**`, lefthook config and any
  `scripts/**/*.sh` with a `# pe: devtools` header to `pe-devtools`.
