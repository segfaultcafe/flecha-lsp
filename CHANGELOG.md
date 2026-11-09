# Changelog

## 0.1.0 - 2026-11-09

- Implement JSON-RPC 2.0 and LSP `Content-Length` framing over standard IO.
- Synchronize full documents through `didOpen`, `didChange`, and `didClose`.
- Bridge editor buffers to `flecha analyze --stdio` and publish syntax and
  semantic diagnostics using UTF-16 LSP positions.
- Discover an optional Longbow package graph for dependency-aware analysis.
- Provide versioned Linux, macOS, and Windows release archives.
