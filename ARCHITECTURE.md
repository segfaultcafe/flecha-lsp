# Flecha LSP Architecture

## Current scope

The implemented vertical slice is deliberately narrow: an editor starts
`flecha-lsp`, initializes a workspace, sends complete in-memory documents, and
receives Flecha compiler diagnostics. The compiler remains the single source of
truth for tokenization, parsing, module loading, and semantic analysis.

```text
editor starts flecha-lsp
  → flecha-lsp starts flecha analyze --stdio
  → initialize negotiates analyzer protocol 1.0
  → didOpen/didChange forwards an in-memory overlay
  → compiler returns byte-based diagnostics
  → flecha-lsp publishes UTF-16 LSP ranges
  → shutdown and exit stop both processes
```

## Process boundary

```text
┌──────────────────────┐
│ Editor or LSP client │
└──────────┬───────────┘
           │ LSP / JSON-RPC 2.0
           │ Content-Length over stdin/stdout
           ▼
┌──────────────────────┐
│      flecha-lsp      │
│  written in Flecha   │
└──────────┬───────────┘
           │ analyzer JSON-RPC 2.0
           │ Content-Length over private pipes
           ▼
┌──────────────────────┐
│ flecha analyze       │
│ --stdio              │
└──────────┬───────────┘
           │ compiler-internal APIs
           ▼
┌──────────────────────┐
│ Flecha frontend      │
└──────────────────────┘
```

`src/main.fl` selects the compiler from `FLECHA_COMPILER`, falling back to
`flecha` from `PATH`. It starts the analyzer without invoking a shell, pipes its
stdin/stdout into the server, waits for it at shutdown, and reports failures on
standard error.

No network listener, global daemon, binary compiler linkage, or public C++ ABI
is involved.

## Editor transport

Both incoming and outgoing editor messages use:

```text
Content-Length: <UTF-8 byte count>\r\n
\r\n
<JSON body>
```

The framing implementation:

- requires exactly one `Content-Length` header;
- compares header names case-insensitively and ignores unknown headers;
- requires CRLF header endings and `\r\n\r\n` termination;
- supports fragmented reads and multiple buffered messages;
- reads exactly the declared body byte count;
- limits headers to 8 KiB and bodies to 64 MiB;
- treats EOF between frames as a clean disconnect;
- treats EOF inside a frame as truncation; and
- flushes every outgoing message.

Standard output is protocol-only. A single diagnostic or debug line there
would corrupt the editor connection.

## JSON-RPC layer

The generic envelope is decoded manually because `params` is heterogeneous and
IDs can be absent, `null`, integer, or string values. Raw `params` bytes are
retained for method-specific parsing. Fractional IDs are rejected.

The server currently emits:

- success responses that preserve the request ID;
- JSON-RPC errors, including parse error `-32700`, invalid params `-32602`, and
  method not found `-32601`; and
- server notifications without IDs.

Requests receive responses. Notifications never receive JSON-RPC responses;
unknown notifications are ignored.

## LSP lifecycle

The state representation is:

```text
Uninitialized → Initializing → Ready → Shutdown → Exited
```

- `initialize` requires a local `rootUri`, initializes the analyzer, and returns
  `textDocumentSync: 1`.
- `initialized` moves the server from `Initializing` to `Ready`.
- `shutdown` shuts down the analyzer and returns `null`.
- `exit` stops the editor loop.

The states are tracked, but strict rejection of every out-of-order message and
the LSP-mandated nonzero exit status for `exit` before `shutdown` remain future
hardening work.

## Full-document synchronization

Supported notifications are:

```text
textDocument/didOpen
textDocument/didChange
textDocument/didClose
```

`didOpen` and `didChange` carry a nonnegative version and complete UTF-8 text.
`didChange` must contain exactly one content change without a `range`; range-
based incremental edits are rejected by the parameter parser. File URIs are
percent-decoded to absolute paths before crossing the compiler boundary.

The compiler analyzer owns the source overlays. The LSP forwards:

```text
document/open(path, version, text)
document/change(path, version, text)
document/close(path)
```

After open or change, the LSP synchronously requests
`document/diagnostics(path)`. After close, it publishes an empty diagnostic list
for the original editor URI.

## Diagnostic positions

The analyzer returns stable diagnostic data rather than compiler objects:

```json
{
  "code": "FLECHA-S0004",
  "file": "/project/src/main.fl",
  "startByte": 20,
  "endByte": 25,
  "severity": "error",
  "message": "unknown name"
}
```

Compiler ranges are UTF-8 byte offsets into the synchronized source text. LSP
diagnostic ranges are zero-based `{line, character}` positions where character
counts UTF-16 code units. `Position::at` scans the current document and:

- counts ASCII and BMP code points as one UTF-16 unit;
- counts supplementary code points as two units;
- resets the character count after LF; and
- rejects offsets outside the text or inside a UTF-8 sequence.

Compiler `error`, `warning`, and `note` severities map to LSP severities 1, 2,
and 3 respectively. Published diagnostics include `source: "flecha"`, the
compiler code, message, range, and current document version.

UTF-16 is currently fixed; position-encoding negotiation is not implemented.

## Analyzer protocol

The private compiler protocol also uses JSON-RPC 2.0 and `Content-Length`, but
it is not LSP. It runs synchronously over child-process pipes.

The initialization request uses protocol version 1.0:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolMajor": 1,
    "protocolMinor": 0,
    "workspace": "/absolute/workspace",
    "packageGraph": "/absolute/workspace/target/package-graph.json"
  }
}
```

`packageGraph` is omitted when the graph does not exist. Other implemented
methods are `document/open`, `document/change`, `document/close`,
`document/diagnostics`, and `shutdown`. Request IDs are monotonically increasing
integers, and each request waits for its matching response before editor
processing continues.

AST nodes, compiler pointers, C++ class names, and symbol objects never cross
this boundary.

## Package graph discovery

Initialization converts the editor's `rootUri` into a workspace path and tests
for `<workspace>/target/package-graph.json`. Discovery is read-only: the LSP
does not invoke Longbow or generate a graph.

When present, the absolute graph path is included in analyzer initialization,
allowing compiler module loading to use Longbow's resolved identities and
dependencies. When absent, the field is omitted and the analyzer retains its
workspace fallback behavior.

## Sequential execution

The current implementation is lockstep:

1. read and dispatch one editor message;
2. send zero or more analyzer requests;
3. wait for each analyzer response;
4. publish diagnostics or write the editor response;
5. read the next editor message.

This keeps ownership and blocking I/O simple, but provides no cancellation,
debounce, background diagnostics, or concurrent workspace analysis.

## Module boundaries

```text
src/
├── main.fl
├── transport/
│   ├── framing.fl
│   ├── reader.fl
│   └── writer.fl
├── rpc/
│   ├── message.fl
│   ├── id.fl
│   ├── request.fl
│   └── response.fl
├── lsp/
│   ├── lsp.fl
│   ├── params.fl
│   ├── uri.fl
│   └── position.fl
├── project/
│   └── context.fl
├── analyzer/
│   ├── analyzer.fl
│   ├── client.fl
│   └── diagnostics.fl
└── server/
    ├── server.fl
    ├── loop.fl
    ├── dispatch.fl
    └── diagnostics.fl
```

Transport knows framing, RPC knows envelopes, LSP knows editor data, analyzer
knows the compiler protocol, and server coordinates the layers.

## Tests

The current suite covers:

- framing success, fragmentation, size limits, truncation, and invalid headers;
- JSON-RPC IDs, raw params, responses, and invalid payloads;
- analyzer request/response framing and diagnostic DTO parsing;
- LSP initialize/document params and URI conversion;
- UTF-8 byte offset to UTF-16 conversion;
- analyzer initialization and package-graph forwarding; and
- an in-memory end-to-end lifecycle including open/change/close diagnostics.

Run all tests with:

```sh
longbow test --verbose
```

## Known gaps and next features

The current server is diagnostics-only. Near-term hardening includes strict
lifecycle validation, stale diagnostic suppression, analyzer recovery, and
process-level editor harnesses. Language features should then be added by
extending the stable analyzer protocol, in roughly this order:

1. hover;
2. go-to-definition;
3. references and symbols;
4. completion;
5. rename and semantic tokens; and
6. incremental synchronization and cancellation.
