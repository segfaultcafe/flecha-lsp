# Editor setup

Build or install `flecha-lsp` first:

```sh
longbow fetch
longbow build
install -Dm755 target/flecha-lsp "$HOME/.local/bin/flecha-lsp"
```

The editor must be able to find both `flecha-lsp` and the Flecha compiler. The
server resolves `flecha` from `PATH`, or uses an explicit compiler inherited
through:

```sh
export FLECHA_COMPILER=/absolute/path/to/flecha
```

For dependency-aware diagnostics, run `longbow build` once in the project so
`target/package-graph.json` exists. This is optional; the server still starts
without it.

## Neovim 0.11+

Neovim 0.11 provides `vim.lsp.config` and `vim.lsp.enable` in its built-in LSP
client. Add this to `init.lua` or another sourced Lua file:

```lua
vim.filetype.add({
  extension = {
    fl = 'flecha',
  },
})

vim.lsp.config('flecha_lsp', {
  cmd = { 'flecha-lsp' },
  filetypes = { 'flecha' },
  root_markers = { 'longbow.toml', '.git' },
})

vim.lsp.enable('flecha_lsp')
```

If the binary is not on the editor's `PATH`, use its absolute path in `cmd`.
To select a compiler only for this server:

```lua
vim.lsp.config('flecha_lsp', {
  cmd = { '/absolute/path/to/flecha-lsp' },
  cmd_env = {
    FLECHA_COMPILER = '/absolute/path/to/flecha',
  },
  filetypes = { 'flecha' },
  root_markers = { 'longbow.toml', '.git' },
})

vim.lsp.enable('flecha_lsp')
```

Open a `.fl` file, introduce a syntax or semantic error, and save or leave the
buffer modified. Diagnostics should update because the server receives the
complete in-memory buffer. Useful checks are:

```vim
:checkhealth vim.lsp
```

See the [official Neovim LSP documentation](https://neovim.io/doc/user/lsp)
for configuration activation and troubleshooting.

## Visual Studio Code

VS Code does not launch an arbitrary language server from `settings.json`.
It needs a language-client extension, and this repository does not ship a
packaged Flecha extension yet.

A development extension can use `vscode-languageclient`. Its language
contribution must associate `.fl` with `flecha`, for example:

```json
{
  "activationEvents": ["onLanguage:flecha"],
  "contributes": {
    "languages": [
      {
        "id": "flecha",
        "aliases": ["Flecha", "flecha"],
        "extensions": [".fl"]
      }
    ]
  }
}
```

The extension entry point can start the server like this:

```ts
import * as vscode from 'vscode';
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
} from 'vscode-languageclient/node';

let client: LanguageClient | undefined;

export function activate(_context: vscode.ExtensionContext): void {
  const serverOptions: ServerOptions = {
    command: process.env.FLECHA_LSP ?? 'flecha-lsp',
    options: {
      env: {
        ...process.env,
        FLECHA_COMPILER: process.env.FLECHA_COMPILER ?? 'flecha',
      },
    },
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: 'file', language: 'flecha' }],
  };

  client = new LanguageClient(
    'flecha-lsp',
    'Flecha Language Server',
    serverOptions,
    clientOptions,
  );
  client.start();
}

export async function deactivate(): Promise<void> {
  await client?.stop();
}
```

Set `FLECHA_LSP` to an absolute server path if it is not on `PATH`. Open the
Flecha project as the VS Code workspace folder so the client sends the expected
local `rootUri` and package-graph discovery starts at the project root.

The [official VS Code language-server extension guide](https://code.visualstudio.com/api/language-extensions/language-server-extension-guide)
describes the extension host, `LanguageClient`, and development workflow.

## Expected feature set

Both clients currently receive diagnostics only. The server does not advertise
completion, hover, definition, references, formatting, rename, or semantic
tokens, so editor commands for those features remain unavailable until the
corresponding protocol handlers are implemented.

## Troubleshooting

- If the server appears idle when run in a terminal, that is normal: it waits
  for `Content-Length` framed LSP input.
- If the editor reports that the server cannot start, use absolute paths for
  `flecha-lsp` and `FLECHA_COMPILER`.
- If imports are unresolved, run `longbow build` in the project and confirm
  `<project>/target/package-graph.json` exists.
- If diagnostics do not update, confirm the client is sending full-document
  changes rather than incremental ranges.
- Keep logs off standard output. Any unframed stdout text breaks the LSP
  connection.
