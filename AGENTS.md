# AGENTS.md

## What this is

`websocket` — an RFC 6455 WebSocket client/server protocol library for
Racket. Single-collection package (`websocket` = collection = package
name). Part of a family line of protocol libraries (isotp, crc, pcap,
tiff, ...). It is deliberately NOT a framework: no routing, no
middleware, no sessions.

## Layout

- `frame.rkt` — RFC 6455 §5 frame codec, pure bytes in/out, no I/O policy
- `handshake.rkt` — §4 opening handshake (server parse + accept key, client request/response)
- `conn.rkt` — connection object, connect/accept/serve, send/recv/close
- `main.rkt` — re-exports everything
- `tests/` — golden vectors + loopback integration (require the `websocket` collection, not relative paths)
- `scribblings/` — Scribble docs

## Conventions

- Code comments in English.
- Frame payloads are always plaintext; `masked?`/`mask-key` describe the
  wire representation only. Keep that invariant.
- Test protocol edges against RFC vectors (the §1.3 accept-key vector,
  the §5.7 "Hello" frames) — never just self-roundtrip.
- Network tests bind 127.0.0.1 on a retry-picked port (tcp-listen cannot
  report its bound port).

## Quality gates (before any release)

1. `raco test tests` — all green
2. `raco setup --check-pkg-deps -l websocket` — zero violations
3. `raco setup -l websocket` — docs build clean

## Known family pitfalls this package must respect

- Multi-collection packages must declare scribblings in the
  collection-level info.rkt; this package is single-collection, keep it
  that way.
- `case` does not match strings — symbol opcodes only.
- Test installs in a scratch `PLTUSERHOME` with `--scope user` to avoid
  polluting the system package set.
