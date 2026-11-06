# Flecha LSP

`flecha-lsp` is an experimental language server for the Flecha programming
language, written in Flecha itself.

The server will implement the Language Server Protocol (LSP) for editors while
delegating language intelligence to the Flecha compiler selected by each
project. This keeps editor integration independent from compiler releases and
avoids duplicating Flecha's parser and semantic rules in the language server.

> [!IMPORTANT]
> The project is currently in its bootstrap phase. JSON serialization and
> deserialization have been validated with Flecha 0.3.1, but the executable is
> not yet a usable language server.

## Goals

- Implement the editor-facing LSP server in Flecha.
- Keep `flecha-lsp` independently versioned from the Flecha compiler.
- Use the compiler chosen by the workspace as the source of language truth.
- Support unsaved documents through in-memory source overlays.
- Begin with diagnostics, then add hover, definition, references, and
  completion.
- Exercise Flecha and its standard library through a substantial real-world
  tool.

## Architecture

```text
Editor
  │ LSP over JSON-RPC and stdin/stdout
  ▼
flecha-lsp
  ├── message framing
  ├── JSON-RPC dispatch
  ├── LSP lifecycle and document state
  └── analyzer client
          │ versioned analysis protocol over child-process pipes
          ▼
      flecha analyze --stdio
          └── tokenizer, parser, module loader, and semantic analyzer
```

`flecha-lsp` is a separate binary. It will start the workspace compiler in an
analysis-server mode and communicate with it through private pipes. There is no
global daemon, TCP listener, or binary linkage to the compiler's C++ internals.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the complete design and delivery
plan.

## Current status

The repository currently proves that a Flecha program can:

- consume the public `flecha/json` package;
- deserialize JSON into a decorated Flecha structure;
- represent owning arrays in protocol structures; and
- build and run with the released Flecha 0.3.1 toolchain.

The next milestone is an editor-independent JSON-RPC loop that reads a framed
`initialize` request and writes a valid response.

## Prerequisites

- Flecha and Longbow 0.3.1
- A platform supported by the Flecha toolchain
- Access to the public Flecha package registry for the first dependency fetch

Verify the toolchain:

```sh
flecha --version
longbow --version
```

Both commands should report compatible versions.

## Building

Fetch the locked dependencies and build the program:

```sh
longbow fetch
longbow build
```

During development, use:

```sh
longbow check
longbow test
longbow run
```

The current `main.fl` runs a JSON deserialization proof rather than an LSP
server.

## Planned repository layout

```text
src/
├── main.fl
├── transport/
│   └── framing.fl
├── rpc/
│   ├── message.fl
│   ├── reader.fl
│   ├── writer.fl
│   └── dispatcher.fl
├── lsp/
│   ├── server.fl
│   ├── initialize.fl
│   ├── documents.fl
│   └── diagnostics.fl
├── text/
│   └── positions.fl
└── analyzer/
    ├── client.fl
    └── protocol.fl
```

## Delivery roadmap

1. `Content-Length` message framing with malformed-input and fragmentation
   tests.
2. JSON-RPC requests, notifications, responses, and errors.
3. LSP `initialize`, `initialized`, `shutdown`, and `exit` lifecycle.
4. Full-document synchronization for open, changed, and closed files.
5. A versioned `flecha analyze --stdio` protocol in the compiler.
6. Syntax and semantic diagnostics for in-memory documents.
7. Hover, go-to-definition, references, and completion.
8. Incremental synchronization, cancellation, and concurrent analysis when
   the language/runtime can support them cleanly.

## Protocol discipline

Standard output is reserved exclusively for LSP messages. Diagnostics and
debug logs must be written to standard error. A single stray line on standard
output corrupts the editor connection.

The initial implementation will be sequential because Flecha 0.3.1 exposes
blocking standard streams and child-process pipes. The protocol is designed so
nonblocking I/O and cancellation can be added later without changing editor
behavior.

## Versioning

Three versions are intentionally independent:

```text
flecha-lsp version
Flecha compiler version
compiler analysis protocol version
```

The LSP negotiates the analysis protocol with the workspace compiler. A
compatible protocol matters; matching product versions do not.

## Contributing

Keep early changes small and vertically testable. In particular:

- do not write logs to standard output;
- do not expose compiler AST objects through the analysis protocol;
- add tests for fragmented and malformed protocol input;
- preserve document versions in asynchronous-looking results; and
- prefer a working diagnostic path over broad, partially implemented LSP
  coverage.

