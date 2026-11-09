# Flecha LSP

`flecha-lsp` is an experimental Language Server Protocol implementation for
Flecha, written in Flecha. The current vertical slice publishes compiler
diagnostics for unsaved files while keeping all parsing and semantic analysis
inside the Flecha compiler.

## What works

- LSP/JSON-RPC 2.0 over standard input and standard output;
- `Content-Length` framing, including partial reads and consecutive messages;
- `initialize`, `initialized`, `shutdown`, and `exit` lifecycle messages;
- full-document `textDocument/didOpen`, `textDocument/didChange`, and
  `textDocument/didClose` synchronization;
- syntax and semantic diagnostics for editor buffers, including unsaved text;
- conversion from compiler UTF-8 byte offsets to LSP UTF-16 positions;
- `file://` URI decoding;
- optional Longbow `target/package-graph.json` discovery; and
- compiler selection through `FLECHA_COMPILER`.

The server currently advertises only:

```json
{
  "capabilities": {
    "textDocumentSync": 1
  }
}
```

`textDocumentSync: 1` means full synchronization. Each change must contain one
complete replacement document; incremental range edits are not accepted.

Completion, hover, go-to-definition, references, rename, formatting, semantic
tokens, and other language features are not implemented yet.

## Architecture

```text
Editor
  │ LSP / JSON-RPC 2.0 / Content-Length / stdio
  ▼
flecha-lsp
  ├── transport and JSON-RPC dispatch
  ├── LSP lifecycle and full-document synchronization
  ├── URI and UTF-16 position conversion
  └── analyzer protocol client
          │ JSON-RPC 2.0 / Content-Length / private pipes
          ▼
      flecha analyze --stdio
          ├── source overlays for unsaved documents
          ├── project and dependency loading
          └── parser and semantic analyzer
```

`flecha-lsp` starts `flecha analyze --stdio` as a child process. It forwards
full document text to the compiler, requests diagnostics synchronously, then
translates the compiler's byte ranges into LSP ranges. The LSP does not link to
the compiler's C++ implementation and does not duplicate its frontend.

Standard output is reserved exclusively for LSP frames. Logs and failures go
to standard error.

See [ARCHITECTURE.md](ARCHITECTURE.md) for protocol and module details and
[docs/editors.md](docs/editors.md) for editor setup.

## Requirements

- Flecha and Longbow 0.3.2, or a compatible newer 0.3.x toolchain, to build the
  server;
- a Flecha compiler that implements `flecha analyze --stdio` protocol 1.0;
- access to the Flecha registry when `flecha/json` is not already cached; and
- a workspace exposed to the editor as a local `file://` URI.

Verify the tools and analyzer command:

```sh
flecha --version
longbow --version
flecha analyze --stdio
```

The last command waits for framed protocol input. Appearing idle is expected;
terminate that manual probe with Ctrl-C.

Flecha 0.3.2 is the first compiler release that provides the analyzer backend.
Release qualification exercises that published compiler through a real child
process rather than a mock protocol endpoint.

By default the server resolves `flecha` from `PATH`. To select another compiler:

```sh
export FLECHA_COMPILER=/absolute/path/to/flecha
```

## Build and test

```sh
longbow fetch
longbow build
longbow test --verbose
```

The executable is written to `target/flecha-lsp`. To install it for the current
user:

```sh
install -Dm755 target/flecha-lsp "$HOME/.local/bin/flecha-lsp"
```

Ensure `$HOME/.local/bin` is in the environment inherited by the editor.

`longbow run` starts the language server, so it also waits for framed LSP input;
it is not an interactive command-line interface.

## Binary releases

Release `v0.1.0` provides archives for Linux x86-64, macOS x86-64 and arm64,
and Windows x86-64. Each archive contains `bin/flecha-lsp` (or
`bin/flecha-lsp.exe`) and the matching documentation. Verify the archive using
the published `SHA256SUMS`, extract it, and place its `bin` directory on the
editor's `PATH`.

The release pipeline builds and tests each native executable using the pinned
Flecha 0.3.2 toolchain. A separate end-to-end gate starts the packaged server
with that published compiler, opens a document containing a semantic error,
verifies the published diagnostic, and performs the LSP shutdown sequence.

## Project discovery

On `initialize`, the server converts the client's non-null `rootUri` (or legacy
`rootPath`) to an absolute workspace path and checks exactly:

```text
<workspace>/target/package-graph.json
```

If the file exists, its absolute path is sent to the analyzer so imports and
package identities use Longbow's resolved graph. The LSP never runs a build to
create it. Run `longbow build` in the Flecha project before starting the editor
when dependency-aware diagnostics are required.

If the graph is absent, initialization continues and the analyzer uses its
workspace-based fallback behavior.

Clients may initialize without a workspace by sending null or omitted
`rootUri` and `rootPath` values. The LSP handshake completes without starting
the analyzer. When the first document opens, the server walks upward from its
directory to find the nearest `longbow.toml`; a standalone source uses its
immediate directory. That discovered directory becomes the analyzer workspace
for the session.

## Diagnostics flow

For an open or changed document, the server performs this lockstep sequence:

1. decode the `file://` URI and full document text;
2. send `document/open` or `document/change` to the analyzer;
3. request `document/diagnostics`;
4. convert `startByte` and `endByte` to zero-based LSP line/UTF-16 positions;
5. publish `textDocument/publishDiagnostics` with the document version.

On `didClose`, the overlay is removed from the analyzer and the LSP publishes
an empty diagnostic list for that URI.

## Current limitations

- diagnostics are the only language-intelligence feature;
- synchronization is full-document only and accepts exactly one content change;
- analysis is sequential and blocks handling of the next editor message;
- only local absolute `file://` workspace and document URIs are accepted;
- UTF-16 is always used for outgoing diagnostic positions;
- there is no cancellation, background debounce, analyzer restart, or
  multi-workspace process pool;
- lifecycle ordering is tracked but not yet exhaustively rejected;
- analyzer snapshot versions are parsed, but stale-result suppression is not
  implemented yet; and
- VS Code requires a client extension; this repository does not ship one yet.

## Repository layout

```text
src/
├── main.fl          # starts the analyzer child and owns process cleanup
├── transport/       # Content-Length reader and writer
├── rpc/             # generic JSON-RPC envelopes
├── lsp/             # params, file URIs, and UTF-16 positions
├── project/         # optional Longbow package-graph discovery
├── analyzer/        # private compiler protocol client and diagnostic DTOs
└── server/          # lifecycle, dispatch, and diagnostic publication
```

## Contributing

- Never write logs to standard output.
- Keep the compiler as the language authority.
- Preserve raw JSON-RPC IDs and notification semantics.
- Add protocol tests for malformed, fragmented, and non-ASCII input.
- Extend the compiler analysis protocol with stable data, not compiler AST or
  C++ implementation objects.
