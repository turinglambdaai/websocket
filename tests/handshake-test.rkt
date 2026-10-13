#lang racket/base

;; Opening handshake (RFC 6455 section 4): accept-key vectors, request
;; parsing/validation, response writing and validation.

(require rackunit
         racket/port
         racket/string
         net/base64
         websocket)

;; ---- RFC 6455 section 1.3 key vector ----

(check-equal? (ws-accept-key "dGhlIHNhbXBsZSBub25jZQ==")
              "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")

;; ---- client keys ----

(define k (ws-new-key))
(check-equal? (string-length k) 24)
(check-equal? (bytes-length (base64-decode (string->bytes/latin-1 k))) 16)

;; ---- server request parsing ----

(define good-request
  (string->bytes/latin-1
   (string-append
    "GET /chat?room=1 HTTP/1.1\r\n"
    "Host: example.com\r\n"
    "Upgrade: websocket\r\n"
    "Connection: keep-alive, Upgrade\r\n"
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
    "Sec-WebSocket-Version: 13\r\n\r\n")))

(define req (ws-read-upgrade-request! (open-input-bytes good-request)))
(check-equal? (ws-upgrade-method req) "GET")
(check-equal? (ws-upgrade-path req) "/chat?room=1")
(check-equal? (ws-upgrade-header req "sec-websocket-key") "dGhlIHNhbXBsZSBub25jZQ==")
(check-equal? (ws-upgrade-header req "nope") #f)

;; wrong method
(check-exn exn:fail:websocket?
           (λ () (ws-read-upgrade-request!
                  (open-input-bytes (string->bytes/latin-1
                                     "POST / HTTP/1.1\r\nHost: x\r\n\r\n")))))
;; missing Upgrade header
(check-exn exn:fail:websocket?
           (λ () (ws-read-upgrade-request!
                  (open-input-bytes (string->bytes/latin-1
                                     "GET / HTTP/1.1\r\nHost: x\r\n\r\n")))))
;; Upgrade present but wrong value
(check-exn exn:fail:websocket?
           (λ () (ws-read-upgrade-request!
                  (open-input-bytes (string->bytes/latin-1
                                     "GET / HTTP/1.1\r\nUpgrade: h2c\r\n\r\n")))))
;; Connection header without the Upgrade token
(check-exn exn:fail:websocket?
           (λ () (ws-read-upgrade-request!
                  (open-input-bytes (string->bytes/latin-1
                                     "GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: keep-alive\r\n\r\n")))))
;; missing key
(check-exn exn:fail:websocket?
           (λ () (ws-read-upgrade-request!
                  (open-input-bytes (string->bytes/latin-1
                                     "GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")))))
;; key that is not base64 of 16 bytes
(check-exn exn:fail:websocket?
           (λ () (ws-read-upgrade-request!
                  (open-input-bytes (string->bytes/latin-1
                                     "GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: c2hvcnQ=\r\n\r\n")))))
;; wrong version
(check-exn exn:fail:websocket?
           (λ () (ws-read-upgrade-request!
                  (open-input-bytes (string->bytes/latin-1
                                     "GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 8\r\n\r\n")))))

;; ---- server accept response ----

(define resp-out (open-output-bytes))
(ws-write-accept-response! resp-out "dGhlIHNhbXBsZSBub25jZQ==")
(check-true (string-contains?
             (bytes->string/latin-1 (get-output-bytes resp-out))
             "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))
(check-true (string-contains?
             (bytes->string/latin-1 (get-output-bytes resp-out))
             "HTTP/1.1 101 Switching Protocols"))

;; ---- client side ----

(define req-out (open-output-bytes))
(ws-write-upgrade-request! req-out "example.com:8080" "/chat" k)
(define sent (bytes->string/latin-1 (get-output-bytes req-out)))
(check-true (string-contains? sent "GET /chat HTTP/1.1\r\n"))
(check-true (string-contains? sent "Host: example.com:8080\r\n"))
(check-true (string-contains? sent "Sec-WebSocket-Version: 13\r\n"))

(define good-response
  (string->bytes/latin-1
   (string-append
    "HTTP/1.1 101 Switching Protocols\r\n"
    "Upgrade: websocket\r\n"
    "Connection: Upgrade\r\n"
    "Sec-WebSocket-Accept: " (ws-accept-key k) "\r\n\r\n")))
(check-not-exn (λ () (ws-read-upgrade-response! (open-input-bytes good-response) k)))

;; rejection status
(check-exn exn:fail:websocket?
           (λ () (ws-read-upgrade-response!
                  (open-input-bytes
                   (string->bytes/latin-1 "HTTP/1.1 400 Bad Request\r\n\r\n"))
                  k)))
;; accept mismatch
(check-exn exn:fail:websocket?
           (λ () (ws-read-upgrade-response!
                  (open-input-bytes
                   (string->bytes/latin-1
                    "HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: zzz==\r\n\r\n"))
                  k)))
