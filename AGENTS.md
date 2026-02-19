# Repository Guidelines

## Project Structure & Module Organization
This repository is a Zig project with a clear source/test split:

- `src/` — runtime code.
  - `src/cli/` for the CLI flow and docs (`src/cli/docs/`).
  - `src/client/` for client state/config.
  - `src/gui/` for desktop UI and SDL/WebGPU bridge.
  - `src/protocol/` for message types and protocol logic.
- `tests/` — Zig test suite (`tests/test_protocol.zig` and related cases).
- `docs/` — architecture and protocol references (`ARCHITECTURE.md`, `DATA_MODEL.md`).
- `build.zig` — build and dependency graph.
- Outputs are written under `zig-out/` (CLI: `zig-out/bin/zss`, GUI: `zig-out/bin/zss-gui`).

## Build, Test, and Development Commands
- `zig build` — build CLI artifact.
- `./zig-out/bin/zss --help` — verify CLI starts and inspect options.
- `zig build gui` — build desktop GUI (Linux/Windows/macOS only).
- `zig build run-gui` — build and run GUI.
- `zig build test` — compile and run the Zig test suite.
- `zig build run -- [args]` — run CLI with arguments from source build step.
- If source code changes, you must run `zig build` and `zig build test` and confirm both pass before pushing to any remote.

## Coding Style & Naming Conventions
- Follow Zig style (`zig fmt`) and standard indentation.
- Use snake_case for file and symbol names (`project_state`, `chat_client`) and PascalCase for struct/enum types.
- Keep command modules close to command docs when behavior changes.
- Prefer small, focused files/functions; colocate protocol serializers/parsers with their types.
- When adding external API or protocol behavior, update docs in `docs/` to keep behavior discoverable.

## Testing Guidelines
- Use `std.testing` and Zig `test` blocks.
- Existing tests use descriptive names, e.g., `test "Project type"`.
- Place new integration/unit coverage under `tests/` with module-focused file names.
- New protocol/serialization changes should include positive + negative-path tests.
- Run `zig build test` before opening a PR.

## Commit & Pull Request Guidelines
- Project history favors Conventional-style prefixes (for example `feat:`, `fix:`, `feat(gui):`, `test:`).
- Keep commit titles concise and imperative, include issue references when applicable (`#123`).
- PRs should include:
  - Summary of what changed.
  - Commands run and results (`zig build`, `zig build test`, GUI build/run when relevant).
  - Screenshots only for user-visible GUI changes.
  - Mention of protocol/schema compatibility impact, if any.

## Optional Notes
- Default websocket target used by UI/settings examples is `ws://127.0.0.1:18790`.
- Do not commit credentials, tokens, or machine-specific paths.
