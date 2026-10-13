#lang racket/base

;; RFC 6455 section 4 opening handshake: server-side request parsing and
;; accept-key derivation, client-side request writing and response
;; validation. HTTP is parsed only down to exactly what the upgrade
;; needs — this is not an HTTP library.

(require racket/contract
         racket/random
         racket/string
         openssl/sha1
         net/base64
         "frame.rkt")

;; RFC 6455 section 1.3
(define websocket-guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")

;; ---- key derivation ----

(define (hex->bytes h)
  (list->bytes
   (for/list ([i (in-range 0 (string-length h) 2)])
     (string->number (substring h i (+ i 2)) 16))))

;; RFC 6455 section 4.2.1: base64(SHA1(key + GUID))
(define (ws-accept-key key)
  (define digest
    (sha1 (open-input-bytes
           (string->bytes/utf-8 (string-append key websocket-guid)))))
  (string-trim
   (bytes->string/latin-1
    (base64-encode (hex->bytes digest)))))

;; 16 random bytes, base64-encoded — the client's Sec-WebSocket-Key.
(define (ws-new-key)
  (string-trim
   (bytes->string/latin-1
    (base64-encode (crypto-random-bytes 16)))))

;; ---- HTTP line helpers ----

(define (read-line-crlf in)
  (read-line in 'return-linefeed))

(define (read-headers! in)
  (let loop ()
    (define line (read-line-crlf in))
    (cond
      [(eof-object? line)
       (websocket-error "connection ended inside HTTP headers")]
      [(string=? line "") '()]
      [else
       (define i
         (for/first ([j (in-range (string-length line))]
                     #:when (char=? (string-ref line j) #\:))
           j))
       (unless i
         (websocket-error "malformed HTTP header line: ~a" line))
       (cons (cons (string-downcase (string-trim (substring line 0 i)))
                   (string-trim (substring line (+ i 1))))
             (loop))])))

(define (lookup headers name)
  (for/first ([kv (in-list headers)] #:when (string=? (car kv) name))
    (cdr kv)))

;; RFC 6455 section 4.2.1/4.1: comma-separated header field whose token
;; list contains `token` case-insensitively.
(define (header-has-token? value token)
  (for/or ([part (in-list (string-split value ","))])
    (string-ci=? (string-trim part) token)))

;; ---- server side ----

(struct ws-upgrade (method path headers) #:transparent)

(define (ws-upgrade-header req name)
  (lookup (ws-upgrade-headers req) name))

(define (ws-read-upgrade-request! in)
  (define request-line (read-line-crlf in))
  (when (or (eof-object? request-line) (string=? request-line ""))
    (websocket-error "empty HTTP request line"))
  (define parts (string-split request-line " "))
  (unless (= (length parts) 3)
    (websocket-error "malformed HTTP request line: ~a" request-line))
  (define method (car parts))
  (define path (cadr parts))
  (define headers (read-headers! in))
  (unless (string=? method "GET")
    (websocket-error "upgrade request must be GET, got ~a" method))
  (define upgrade (lookup headers "upgrade"))
  (unless (and upgrade (header-has-token? upgrade "websocket"))
    (websocket-error "missing or wrong Upgrade header: ~a" upgrade))
  (define connection (lookup headers "connection"))
  (unless (and connection (header-has-token? connection "upgrade"))
    (websocket-error "missing or wrong Connection header: ~a" connection))
  (define key (lookup headers "sec-websocket-key"))
  (unless key
    (websocket-error "missing Sec-WebSocket-Key header"))
  (define key-bytes
    (and key (base64-decode (string->bytes/latin-1 key))))
  (unless (and key-bytes (= 16 (bytes-length key-bytes)))
    (websocket-error "Sec-WebSocket-Key must be base64 of 16 bytes, got ~a" key))
  (define version (lookup headers "sec-websocket-version"))
  (unless (and version (string=? version "13"))
    (websocket-error "unsupported Sec-WebSocket-Version: ~a (want 13)" version))
  (ws-upgrade method path headers))

(define (ws-write-accept-response! out key)
  (fprintf out "HTTP/1.1 101 Switching Protocols\r\n")
  (fprintf out "Upgrade: websocket\r\n")
  (fprintf out "Connection: Upgrade\r\n")
  (fprintf out "Sec-WebSocket-Accept: ~a\r\n\r\n" (ws-accept-key key))
  (flush-output out))

;; ---- client side ----

(define (ws-write-upgrade-request! out host path key #:headers [extra '()])
  (fprintf out "GET ~a HTTP/1.1\r\n" path)
  (fprintf out "Host: ~a\r\n" host)
  (fprintf out "Upgrade: websocket\r\n")
  (fprintf out "Connection: Upgrade\r\n")
  (fprintf out "Sec-WebSocket-Key: ~a\r\n" key)
  (fprintf out "Sec-WebSocket-Version: 13\r\n")
  (for ([kv (in-list extra)])
    (fprintf out "~a: ~a\r\n" (car kv) (cdr kv)))
  (fprintf out "\r\n")
  (flush-output out))

(define (ws-read-upgrade-response! in key)
  (define status (read-line-crlf in))
  (unless (and (string? status)
               (regexp-match? #rx"^HTTP/1\\.[01] 101" status))
    (websocket-error "handshake rejected or malformed: ~a"
                     (if (eof-object? status) "EOF" status)))
  (define headers (read-headers! in))
  (define accept (lookup headers "sec-websocket-accept"))
  (unless (and accept (string=? accept (ws-accept-key key)))
    (websocket-error "Sec-WebSocket-Accept mismatch: ~a" accept)))

(provide (contract-out
          [websocket-guid string?]
          [ws-new-key (-> string?)]
          [ws-accept-key (-> string? string?)]
          [struct ws-upgrade ((method string?)
                              (path string?)
                              (headers (listof (cons/c string? string?))))]
          [ws-upgrade-header (-> ws-upgrade? string? (or/c string? #f))]
          [ws-read-upgrade-request! (-> input-port? ws-upgrade?)]
          [ws-write-accept-response! (-> output-port? string? void?)]
          [ws-write-upgrade-request!
           (->* (output-port? string? string? string?)
                (#:headers (listof (cons/c string? string?)))
                void?)]
          [ws-read-upgrade-response! (-> input-port? string? void?)]))
