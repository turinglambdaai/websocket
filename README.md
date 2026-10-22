# websocket

**English** · [中文](README.zh-CN.md)

[![CI](https://github.com/turinglambdaai/websocket/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/websocket/actions/workflows/ci.yml)

RFC 6455 WebSocket client and server for Racket. A protocol library, not a
framework: connections become Racket-port-shaped objects and everything
else — routing, sessions, serialization — stays with the caller.

## Install

```
raco pkg install websocket
```

## Use

Client:

```racket
(require websocket)
(define conn (ws-connect "ws://localhost:8080/chat"))
(ws-send-text! conn "hello")
(define msg (ws-recv conn))          ; (ws-message 'text #"hello back")
(ws-close! conn)
```

Server:

```racket
(require websocket racket/tcp)
(define listener (tcp-listen 8080 16 #t "127.0.0.1"))
(ws-serve listener
          (λ (conn)
            (let loop ()
              (define m (ws-recv conn))
              (unless (eof-object? m)
                (ws-send-text! conn "welcome")
                (loop)))))
```

What you get:

- RFC 6455 compliant: opening handshake, frame codec, masking,
  fragmentation, control frames, close handshake, UTF-8 validation
- `ws://` and `wss://` client URLs (plain TCP and TLS)
- Thread-safe sends: one thread can sit in `ws-recv` while another sends
- Transparent ping/pong while receiving; protocol violations close the
  connection with the right status code (1002/1007)
- The raw frame codec is exposed for proxies and testing

Limitations: no permessage-deflate, no background keepalive thread.

## Development

```
raco pkg install --auto --link .
raco test tests
raco setup --check-pkg-deps -l websocket
```

## License

[MIT](LICENSE)
