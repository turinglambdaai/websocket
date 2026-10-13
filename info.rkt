#lang info

(define collection "websocket")
(define version "0.2")
(define deps '("base" "net-lib"))
(define build-deps '("scribble-lib" "racket-doc" "rackunit-lib"))
(define scribblings '(("scribblings/websocket.scrbl" ())))
(define pkg-desc "RFC 6455 WebSocket client and server")
(define license 'MIT)
(define pkg-authors '(turinglambdaai))
(define test-omit-paths '("scribblings"))
