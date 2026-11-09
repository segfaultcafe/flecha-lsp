#!/usr/bin/env python3

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def frame(message: dict) -> bytes:
    body = json.dumps(message, separators=(",", ":")).encode("utf-8")
    return f"Content-Length: {len(body)}\r\n\r\n".encode("ascii") + body


def parse_frames(data: bytes) -> list[dict]:
    messages: list[dict] = []
    position = 0
    while position < len(data):
        boundary = data.find(b"\r\n\r\n", position)
        if boundary < 0:
            raise AssertionError("server output contains an incomplete header")
        header = data[position:boundary].decode("ascii")
        fields = {}
        for line in header.split("\r\n"):
            name, separator, value = line.partition(":")
            if not separator:
                raise AssertionError(f"malformed LSP header: {line!r}")
            fields[name.lower()] = value.strip()
        if "content-length" not in fields:
            raise AssertionError("server output omits Content-Length")
        length = int(fields["content-length"])
        body_start = boundary + 4
        body_end = body_start + length
        if body_end > len(data):
            raise AssertionError("server output contains an incomplete body")
        messages.append(json.loads(data[body_start:body_end]))
        position = body_end
    return messages


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", required=True, type=Path)
    parser.add_argument("--compiler", required=True, type=Path)
    arguments = parser.parse_args()

    server = arguments.server.resolve()
    compiler = arguments.compiler.resolve()
    if not server.is_file() or not compiler.is_file():
        raise SystemExit("server and compiler must name existing executables")

    with tempfile.TemporaryDirectory(prefix="flecha-lsp-e2e-") as directory:
        workspace = Path(directory).resolve()
        source = workspace / "main.fl"
        text = "module main;\ni32 main() { return missing_name; }\n"
        source.write_text(text, encoding="utf-8")

        requests = [
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {"rootUri": workspace.as_uri()},
            },
            {"jsonrpc": "2.0", "method": "initialized", "params": {}},
            {
                "jsonrpc": "2.0",
                "method": "textDocument/didOpen",
                "params": {
                    "textDocument": {
                        "uri": source.as_uri(),
                        "languageId": "flecha",
                        "version": 1,
                        "text": text,
                    }
                },
            },
            {"jsonrpc": "2.0", "id": 2, "method": "shutdown"},
            {"jsonrpc": "2.0", "method": "exit"},
        ]
        payload = b"".join(frame(request) for request in requests)
        environment = os.environ.copy()
        environment["FLECHA_COMPILER"] = str(compiler)
        result = subprocess.run(
            [str(server)],
            input=payload,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            cwd=workspace,
            timeout=30,
            check=False,
        )

    if result.returncode != 0:
        raise AssertionError(
            "flecha-lsp failed with exit code "
            f"{result.returncode}: {result.stderr.decode(errors='replace')}"
        )

    messages = parse_frames(result.stdout)
    initialize = next(
        (message for message in messages if message.get("id") == 1), None
    )
    if initialize is None or initialize.get("result", {}).get(
        "capabilities", {}
    ).get("textDocumentSync") != 1:
        raise AssertionError("initialize did not negotiate full document sync")

    diagnostics = next(
        (
            message
            for message in messages
            if message.get("method") == "textDocument/publishDiagnostics"
        ),
        None,
    )
    if diagnostics is None:
        raise AssertionError("the server did not publish diagnostics")
    published = diagnostics.get("params", {}).get("diagnostics", [])
    if not any(
        diagnostic.get("code") == "FLECHA-S0002"
        and "missing_name" in diagnostic.get("message", "")
        for diagnostic in published
    ):
        raise AssertionError(
            f"expected unknown-name diagnostic, received: {published!r}"
        )

    shutdown = next(
        (message for message in messages if message.get("id") == 2), None
    )
    if shutdown is None or shutdown.get("result", object()) is not None:
        raise AssertionError("shutdown did not return a null result")

    print("flecha-lsp end-to-end analyzer bridge: pass")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
