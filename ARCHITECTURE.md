# Flecha LSP Architecture

## Status

This document defines the intended architecture for `flecha-lsp`. The project
is in the bootstrap phase: JSON serialization and deserialization work, while
the LSP transport and compiler analysis server described here still need to be
implemented.

The first end-to-end target is deliberately narrow:

```text
editor starts flecha-lsp
  → initialize succeeds
  → editor opens an unsaved Flecha document
  → the workspace compiler analyzes its in-memory text
  → diagnostics are published
  → shutdown succeeds
```

## Design principles

1. **The compiler is the language authority.** The LSP must not maintain a
   second parser or approximate Flecha's semantic rules.
2. **Versions are independent.** The LSP, compiler, and analysis protocol have
   separate release versions.
3. **Protocol boundaries are stable.** Compiler implementation objects, ASTs,
   and C++ ABI details never cross the process boundary.
4. **Unsaved text is first-class.** Analysis reads document overlays before
   consulting the filesystem.
5. **Start sequentially.** Flecha 0.3.1 uses blocking I/O, so the first server
   favors correctness over concurrency.
6. **Ship vertical slices.** Diagnostics must work end to end before broad LSP
   feature coverage is attempted.

## System context

```text
┌──────────────────────┐
│ Editor or LSP client │
└──────────┬───────────┘
           │ LSP 3.17 / JSON-RPC 2.0
           │ Content-Length framing over stdin/stdout
           ▼
┌──────────────────────┐
│     flecha-lsp       │
│   written in Flecha  │
└──────────┬───────────┘
           │ versioned analysis protocol / JSON-RPC 2.0
           │ private child-process pipes
           ▼
┌──────────────────────┐
│ flecha analyze       │
│ --stdio              │
└──────────┬───────────┘
           │ unstable in-process compiler APIs
           ▼
┌──────────────────────┐
│ Flecha frontend      │
│ modules + syntax +   │
│ semantic analysis    │
└──────────────────────┘
```

### Editor

The editor owns the user interface and starts `flecha-lsp`. It only knows the
standard LSP protocol.

### `flecha-lsp`

The language-server binary owns:

- editor-facing LSP framing and JSON-RPC dispatch;
- LSP lifecycle validation;
- open-document text and document versions;
- URI handling and position conversion;
- workspace-to-toolchain selection;
- lifecycle management for compiler analysis processes; and
- translation between compiler diagnostics and LSP diagnostics.

It does not own Flecha parsing, name resolution, type checking, or import
semantics.

### Compiler analysis server

The workspace compiler will expose a proposed command:

```sh
flecha analyze --stdio
```

This mode owns:

- source overlays for unsaved documents;
- project and dependency loading;
- syntax and semantic analysis;
- compiler-native byte ranges; and
- stable protocol responses containing diagnostics and semantic facts.

The analysis server and compiler frontend ship together, so their internal API
can evolve without becoming a public ABI.

## Process model

The editor starts one `flecha-lsp` process. The LSP starts one compiler analysis
process per workspace/compiler pair.

```text
one editor session
  └── flecha-lsp
      ├── workspace A → Flecha 0.4 analyzer
      └── workspace B → Flecha 0.5 analyzer
```

The initial implementation may support only one workspace, but data structures
and protocol messages must not assume there can only ever be one.

The analyzer is a private child process. It does not listen on a network port
or survive its parent LSP. Its standard error should be inherited so an unread
log pipe cannot fill and deadlock the server.

## Editor transport

LSP messages use JSON-RPC 2.0 with the standard header framing:

```text
Content-Length: <UTF-8 byte count>\r\n
\r\n
<JSON body>
```

### Framing requirements

- `Content-Length` is required and must appear exactly once.
- Header parsing ends at `\r\n\r\n`.
- The body is read as exactly the declared number of bytes.
- Partial reads and several messages in one operating-system read are normal.
- Header names are compared case-insensitively.
- Unknown headers are ignored.
- The initial maximum header section is 8 KiB.
- The initial maximum message body is 64 MiB.
- End-of-file between messages is a clean disconnect.
- End-of-file inside a header or body is a protocol failure.
- Every outgoing frame is flushed before reading the next editor request.

Standard output is protocol-only. All logging goes to standard error.

## JSON-RPC representation

Generated `@json` methods are appropriate for method-specific parameter and
result structures, but not for the generic JSON-RPC envelope. The envelope has
heterogeneous `params` and `result` values, and request IDs may be absent,
`null`, numeric, or textual.

The envelope will therefore be parsed manually with `json::Reader`.

```flecha
enum RpcIdKind {
    default Missing,
    Null,
    Number,
    String,
}

structure RpcId {
    RpcIdKind kind;
    i64 number;
    string text;
};

structure RpcRequest {
    RpcId id;
    string method;
    own []u8 params;
    bool hasParams;
};
```

`Reader::position()` and `Reader::skipValue()` allow the parser to capture the
raw JSON range of `params`. After method dispatch, that range is decoded into a
typed structure:

```flecha
params, err := InitializeParams::fromJson(request.params);
```

Responses are built with `json::Writer`. The response writer emits the
JSON-RPC envelope, writes the request ID according to `RpcIdKind`, and lets the
handler write a typed result or error object.

The RPC layer must distinguish:

- request: method and ID, expects a response;
- notification: method without ID, never receives a response;
- success response: ID and result;
- error response: ID and JSON-RPC error; and
- malformed message: parse error or invalid request.

The initial implementation accepts integer and string request IDs. Fractional
numeric IDs are rejected because LSP request IDs are integer or string values.

## LSP lifecycle

The server state machine is:

```text
Starting
   │ initialize
   ▼
Initialized
   │ shutdown
   ▼
ShutdownRequested
   │ exit
   ▼
Exited
```

Required initial methods:

- `initialize` request;
- `initialized` notification;
- `shutdown` request; and
- `exit` notification.

Before initialization, every request other than `initialize` is rejected.
After `shutdown`, new feature requests are rejected while `exit` remains valid.
Receiving `exit` without a prior successful `shutdown` results in a nonzero
process exit status, as required by LSP.

## Initial server capabilities

The first server advertises full-document synchronization:

```json
{
  "capabilities": {
    "textDocumentSync": 1
  }
}
```

Full synchronization is intentional. Applying incremental edits requires
correct LSP position decoding and adds risk before the diagnostic path exists.
Incremental synchronization can be introduced later without changing the
document-store abstraction.

## Document model

The initial document store handles:

- `textDocument/didOpen`;
- `textDocument/didChange` with one full-text change;
- `textDocument/didClose`; and
- monotonically increasing document versions.

Conceptually:

```flecha
structure Document {
    string uri;
    i64 version;
    string text;
};
```

Rules:

- the URI is the document identity;
- stale or duplicate versions do not replace newer text;
- closed documents are removed from the in-memory overlay;
- analyzer results carry the document version that produced them; and
- results for an older version are discarded.

The editor-provided URI remains canonical in the LSP. Filesystem conversion is
performed only at the compiler boundary and must correctly handle percent
encoding and platform path rules.

## Position model

The compiler should report source ranges as UTF-8 byte offsets. Byte offsets
are compact, unambiguous, and match compiler source buffers.

LSP positions use a line and character pair. UTF-16 code units are the default
character encoding unless the client and server negotiate another encoding.
The LSP therefore owns a line index for each open document and converts:

```text
UTF-8 byte offset ↔ line and negotiated character offset
```

The conversion layer must correctly handle:

- ASCII;
- multibyte UTF-8 code points;
- code points represented by two UTF-16 code units;
- `\n` and `\r\n`; and
- offsets at the end of a line or document.

If a client offers UTF-8 position encoding, the server may select it. Otherwise
UTF-16 conversion is mandatory.

## Analysis protocol

The compiler-facing protocol is not LSP. It is a smaller, Flecha-specific
protocol with its own version and capability negotiation.

Initial methods:

```text
initialize
document/open
document/change
document/close
document/diagnostics
shutdown
```

An initialization request includes:

```json
{
  "protocolMajor": 1,
  "protocolMinor": 0,
  "workspace": "/absolute/workspace/path"
}
```

The response includes the compiler version, negotiated protocol version, and
capabilities. Peers with different protocol major versions are incompatible.
A newer minor version may add optional methods or fields.

Diagnostics cross the boundary as stable data transfer objects:

```json
{
  "uri": "file:///project/src/main.fl",
  "version": 4,
  "diagnostics": [
    {
      "code": "FLECHA-S0004",
      "startByte": 20,
      "endByte": 25,
      "severity": "error",
      "message": "unknown name"
    }
  ]
}
```

AST nodes, compiler pointers, C++ class names, and implementation-specific
symbol objects are forbidden in the public protocol.

## Source overlays

The analyzer needs a source-provider abstraction shared by `check`, `build`,
and analysis-server entry points.

```text
source request
  ├── matching open document → use in-memory overlay
  └── otherwise              → read from filesystem
```

Overlays are keyed by normalized document identity and carry a version. Module
loading must consult the provider for every source file, not only the initially
requested file. This allows unsaved changes in imported modules to participate
in analysis.

## Toolchain discovery

The LSP must start the compiler intended for the workspace. The initial search
order is:

1. an explicit editor initialization option;
2. `FLECHA_COMPILER`;
3. a project-specific toolchain mechanism when Flecha defines one; and
4. `flecha` resolved from `PATH`.

The selected executable path and reported compiler version are logged to
standard error. A missing compiler is surfaced to the editor as a clear
user-facing error rather than silently falling back to a different frontend.

## Sequential execution model

Flecha 0.3.1 exposes blocking standard streams and child-process pipes. The
first implementation therefore uses lockstep processing:

1. read one editor message;
2. validate and dispatch it;
3. send at most one analyzer request;
4. wait for its response;
5. answer or notify the editor; and
6. read the next editor message.

Editor messages arriving during analysis remain buffered by the operating
system. This does not provide cancellation or background diagnostics, but it is
correct and sufficient for the first vertical slice.

The analyzer must not send unsolicited messages in the initial protocol.
Strict request-response behavior prevents two blocking streams from requiring
concurrent readers.

Future nonblocking I/O or concurrency may add:

- request cancellation;
- debounced background diagnostics;
- parallel workspace analysis; and
- analyzer stderr capture.

These are implementation improvements, not protocol redesigns.

## Failure handling

### Editor protocol failures

- A malformed frame terminates the connection after logging to standard error.
- Valid JSON-RPC parse and method errors receive JSON-RPC error responses when
  an ID is available.
- Notifications never receive responses, including on handler failure.

### Analyzer failures

- Unexpected analyzer EOF marks the workspace analyzer unavailable.
- The active editor request receives an internal-error response.
- Open document state remains in the LSP so a replacement analyzer can be
  initialized and repopulated later.
- Automatic restart is deferred until the basic server is reliable.

### Stale results

Every document-dependent result includes a document version. The LSP discards
results that do not match its current version before publishing them.

## Security and robustness

- Reject message lengths that overflow `usize` or exceed configured limits.
- Never allocate from an unvalidated `Content-Length`.
- Treat source text and URIs as untrusted input.
- Do not invoke a shell when starting the compiler.
- Pass compiler arguments directly through `std::process::Command`.
- Do not accept network connections.
- Do not execute project code during analysis.
- Keep registry and dependency resolution behavior in Longbow/compiler layers,
  not in the LSP.

## Planned module layout

```text
src/
├── main.fl                    # process entry and top-level error handling
├── transport/
│   └── framing.fl             # Content-Length reader and writer
├── rpc/
│   ├── message.fl             # IDs, requests, responses, and errors
│   ├── reader.fl              # manual envelope decoder
│   ├── writer.fl              # envelope encoder
│   └── dispatcher.fl          # method registration and dispatch
├── lsp/
│   ├── server.fl              # lifecycle and main loop
│   ├── initialize.fl          # capability negotiation
│   ├── documents.fl           # didOpen/didChange/didClose
│   └── diagnostics.fl         # analyzer-to-LSP translation
├── text/
│   └── positions.fl           # byte/UTF-8/UTF-16 position conversion
└── analyzer/
    ├── client.fl              # child process and lockstep requests
    └── protocol.fl            # versioned analysis DTOs
```

Modules may be reorganized as implementation experience grows, but the
transport, RPC, LSP, text, and analyzer responsibilities should remain
separate.

## Testing strategy

### Framing tests

- one complete frame;
- one-byte-at-a-time fragmented input;
- several frames in one input buffer;
- mixed-case and unknown headers;
- duplicate or missing `Content-Length`;
- malformed, overflowing, and oversized lengths;
- truncated headers and bodies; and
- embedded newlines and non-ASCII JSON bodies.

### JSON-RPC tests

- numeric and string IDs;
- notifications;
- malformed JSON;
- unknown methods;
- invalid parameter shapes;
- success and error responses; and
- raw nested `params` extraction.

### LSP lifecycle tests

- successful initialization and shutdown;
- duplicate initialization;
- request before initialization;
- request after shutdown;
- `exit` with and without prior shutdown; and
- guarantee that standard output contains only framed messages.

### Document and position tests

- full-text replacement;
- stale versions;
- close and reopen;
- LF and CRLF indexing;
- UTF-8 and UTF-16 character positions; and
- stale diagnostic suppression.

### End-to-end tests

A harness starts the real `flecha-lsp` binary, writes framed messages, and
asserts exact protocol responses. Once the compiler server exists, the harness
opens a syntactically invalid unsaved file and verifies that a diagnostic is
published without writing the file to disk.

## Delivery plan

### Milestone 1: transport

- framed reader and writer;
- size limits and error reporting;
- fragmentation tests.

**Done when:** a test process can exchange several framed JSON bodies without
loss or protocol contamination.

### Milestone 2: JSON-RPC

- envelope reader and writer;
- IDs, notifications, and errors;
- dispatcher with unknown-method handling.

**Done when:** a fixture request receives a standards-shaped response with the
same ID.

### Milestone 3: LSP lifecycle

- initialize capabilities;
- initialized, shutdown, and exit;
- lifecycle state validation.

**Done when:** a generic LSP client can start and cleanly stop the server.

### Milestone 4: documents

- full synchronization;
- document versions;
- line and position index.

**Done when:** the server retains the latest unsaved UTF-8 document and maps its
byte offsets to negotiated LSP positions.

### Milestone 5: compiler analysis service

- `flecha analyze --stdio`;
- version handshake;
- source overlays;
- diagnostic DTOs.

**Done when:** the compiler returns syntax and semantic diagnostics for text
that does not exist on disk.

### Milestone 6: diagnostic vertical slice

- analyzer process management;
- document forwarding;
- range conversion;
- `textDocument/publishDiagnostics`.

**Done when:** an editor displays a Flecha compiler diagnostic for an unsaved
change.

### Later milestones

1. hover;
2. go-to-definition;
3. document and workspace symbols;
4. references;
5. completion;
6. incremental synchronization;
7. cancellation and concurrent analysis; and
8. semantic tokens and rename.

Each feature should extend the stable analysis protocol with semantic data,
not expose the compiler's internal model.

## Explicit non-goals for the first release

- reimplementing the Flecha parser in the LSP;
- linking directly against compiler C++ classes;
- running a machine-global analysis daemon;
- implementing every LSP type before the first vertical slice;
- incremental parsing;
- background concurrency or cancellation;
- formatting, refactoring, and semantic tokens; and
- dynamically loading editor or compiler plugins.

## Versioning policy

Example independent versions:

```text
flecha-lsp               0.2.0
Flecha compiler          0.5.3
analysis protocol        1.1
```

Compatibility is negotiated by analysis-protocol major and minor versions.
The compiler version is informational and may influence feature availability,
but it is not required to match the LSP version.

