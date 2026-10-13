#lang scribble/manual

@(require (for-label websocket
                     racket/base
                     racket/tcp)
          scribble/example)

@title{websocket: RFC 6455 WebSockets}
@defmodule[websocket]

This package implements the @hyperlink["https://datatracker.ietf.org/doc/html/rfc6455"]{RFC 6455}
WebSocket protocol, both client and server side. It is a protocol
library, not a framework: connections become Racket-port-shaped
objects and everything else — routing, sessions, serialization —
stays with the caller. It composes with @racket[tcp-listen] /
@racket[tcp-accept] on the server side and @racketid[ws]:// /
@racketid[wss]:// URLs on the client side.

@section{A first client}

@examples[#:eval (make-base-eval) #:label ""
  (eval:alts (require websocket)
    (void))
  (eval:alts (define conn (ws-connect "ws://localhost:8080/chat"))
    (void))
  (eval:alts (ws-send-text! conn "hello")
    (void))
  (eval:alts (define msg (ws-recv conn))
    (void))
  (eval:alts (ws-close! conn)
    (void))]

@section{A first server}

A server accepts raw TCP connections and upgrades them. @racket[ws-serve]
wires the accept loop and one handler thread per connection; for
integration with an existing event loop, call @racket[ws-accept]
yourself on the two directions of a @racket[tcp-accept] result.

@examples[#:eval (make-base-eval) #:label ""
  (eval:alts (require websocket racket/tcp)
    (void))
  (eval:alts (define listener (tcp-listen 8080 16 #t "127.0.0.1"))
    (void))
  (eval:alts (ws-serve listener (λ (conn) (ws-send-text! conn "welcome")))
    (void))]

@section{Messages}

@defproc[(ws-recv [conn ws?]) (or/c ws-message? eof-object?)]

Blocks for the next complete message. Control frames are handled
transparently: pings are answered with pongs, pongs are consumed.
Once the peer closes (or closes back after us), @racket[eof] is
returned. Protocol violations raise @racket[exn:fail:websocket?] after
sending the appropriate close frame (@racket[1002] protocol error,
@racket[1007] invalid UTF-8).

@defstruct*[ws-message ([type (or/c 'text 'binary)] [payload bytes?])]

@section{API}

@defproc[(ws-connect [url string?]
                     [#:headers headers (listof (cons/c string? string?)) '()])
         ws?]

Opens a @racketid[ws]:// or @racketid[wss]:// connection (plain TCP or
TLS), performs the opening handshake, and returns the connection.
Additional handshake headers can be supplied via @racket[headers].
Every handshake failure — rejection, malformed response, or a
connection reset mid-handshake — raises @racket[exn:fail:websocket?].

@defproc[(ws-accept [in input-port?] [out output-port?]) ws?]

Performs the server side of the opening handshake on an already
accepted TCP connection and returns the connection.

@defproc[(ws-serve [listener tcp-listener?] [handler (-> ws? any/c)]) thread?]

Runs an accept loop on @racket[listener] in a fresh thread, upgrading
each connection and running @racket[handler] with it in its own
thread. The loop exits when the listener is closed.

@defproc[(ws-send-text! [conn ws?] [text string?]) void?]
@defproc[(ws-send-binary! [conn ws?] [payload bytes?]) void?]

Send one complete data message. Writes are serialized across threads.

@defproc[(ws-ping! [conn ws?] [payload bytes? #""]) void?]

Sends a ping control frame (payload at most 125 bytes).

@defproc[(ws-close! [conn ws?]
                    [code exact-nonnegative-integer? 1000]
                    [reason string? ""])
         void?]

Sends a close frame (once) and closes the ports. Idempotent.

@section{Frames, if you need them}

The underlying RFC 6455 section 5 frame codec is exposed for proxies,
tests, and unusual plumbing. Frame payloads are always plaintext; the
wire representation (@racket[frame-masked?], @racket[frame-mask-key])
is carried alongside.

@defproc[(opcode? [v any/c]) boolean?]

Opcode symbols: @racket['continuation], @racket['text],
@racket['binary], @racket['close], @racket['ping], @racket['pong].

@defproc[(data-opcode? [v any/c]) boolean?]

@defproc[(control-opcode? [v any/c]) boolean?]

@defproc[(frame* [#:opcode opcode opcode?]
                 [#:payload payload bytes?]
                 [#:fin? fin? boolean? #t]
                 [#:masked? masked? boolean? #f]
                 [#:mask-key mask-key (or/c bytes? #f) #f])
         frame?]

Constructs a frame. When @racket[masked?] is set without a
@racket[mask-key], @racket[write-frame!] generates a fresh random key.

@defstruct*[frame ([fin? boolean?]
                   [opcode opcode?]
                   [payload bytes?]
                   [masked? boolean?]
                   [mask-key (or/c bytes? #f)])]

@defproc[(write-frame! [out output-port?] [f frame?]) void?]

Encodes and writes one frame. Rejects invalid control frames.

@defproc[(read-frame! [in input-port?]
                      [#:role role (or/c 'server 'client 'any) 'any])
         (or/c frame? eof-object?)]

Reads one frame from @racket[in], returning @racket[eof] at a clean
connection boundary. With @racket[#:role 'server] unmasked client
frames are rejected; with @racket[#:role 'client] masked server frames
are rejected. RSV bits, reserved opcodes, and invalid control frames
raise @racket[exn:fail:websocket?].

@defproc[(mask-payload [payload bytes?] [key (or/c bytes? #f)]) bytes?]

XOR-applies the 4-byte @racket[key] to @racket[payload]; since masking
is self-inverse this both masks and unmasks. A @racket[#f] key returns
the payload unchanged.

@defproc[(utf-8-bytes? [b bytes?]) boolean?]

RFC 3629 validation: rejects stray continuation bytes, overlong
encodings, UTF-16 surrogates, and anything past U+10FFFF.

@defproc[(ws? [v any/c]) boolean?]

Predicate for connection objects.

@defproc[(exn:fail:websocket? [v any/c]) boolean?]

Raised for handshake failures and protocol violations.

@section{Limitations}

No permessage-deflate compression extension. No background keepalive
thread — pings are answered while you are in @racket[ws-recv]; run a
sender thread that calls @racket[ws-ping!] periodically if you need
liveness. The 63-bit length cap of the RFC applies.
