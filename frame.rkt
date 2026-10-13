#lang racket/base

;; RFC 6455 section 5 frame codec. Pure byte-level encode/decode — no
;; I/O policy lives here; conn.rkt drives these against real ports.
;;
;; The frame payload is always the plaintext message bytes. The wire
;; representation (masked? + mask-key) is recorded alongside so tests
;; can re-encode and compare byte-for-byte; write-frame! masks from
;; plaintext and read-frame! unmasks before returning.

(require racket/contract
         racket/random)

(struct exn:fail:websocket exn:fail ())
(define (websocket-error fmt . args)
  (raise (exn:fail:websocket (apply format fmt args) (current-continuation-marks))))

;; ---- opcodes (RFC 6455 section 5.2) ----

(define opcodes
  '((continuation . 0) (text . 1) (binary . 2)
    (close . 8) (ping . 9) (pong . 10)))

(define (opcode->code op)
  (cdr (assq op opcodes)))

(define (code->opcode c)
  (define hit (for/first ([p (in-list opcodes)] #:when (= (cdr p) c)) (car p)))
  (unless hit
    (websocket-error "reserved frame opcode ~a (RFC 6455 section 5.2)" c))
  hit)

;; ---- masking ----

(define (random-mask-key)
  (crypto-random-bytes 4))

;; XOR with the 4-byte key is self-inverse: this both masks and unmasks.
;; A #f key is a no-op so callers can pass wire state through blindly.
(define (mask-payload payload key)
  (cond
    [(not key) payload]
    [(= (bytes-length key) 4)
     (define n (bytes-length payload))
     (define out (make-bytes n))
     (for ([i (in-range n)])
       (bytes-set! out i
                   (bitwise-xor (bytes-ref payload i)
                                (bytes-ref key (modulo i 4)))))
     out]
    [else (websocket-error "mask key must be 4 bytes, got ~a bytes"
                           (bytes-length key))]))

;; ---- construction ----

(struct frame (fin? opcode payload masked? mask-key) #:transparent)

(define (frame* #:opcode opcode
                #:payload payload
                #:fin? [fin? #t]
                #:masked? [masked? #f]
                #:mask-key [mask-key #f])
  (frame fin? opcode payload masked? (and masked? mask-key)))

;; ---- encode ----

(define (write-frame! out f)
  (define n (bytes-length (frame-payload f)))
  (define opcode (frame-opcode f))
  (when (and (control-opcode? opcode)
             (or (not (frame-fin? f)) (> n 125)))
    (websocket-error "control frame ~a must be unfragmented and at most 125 bytes, got fin? ~a / ~a bytes"
                     opcode (frame-fin? f) n))
  (write-byte (bitwise-ior (if (frame-fin? f) #x80 0)
                           (opcode->code opcode))
              out)
  (define mask-bit (if (frame-masked? f) #x80 0))
  (cond
    [(< n 126)
     (write-byte (bitwise-ior mask-bit n) out)]
    [(< n 65536)
     (write-byte (bitwise-ior mask-bit 126) out)
     (write-bytes (integer->integer-bytes n 2 #f #t) out)]
    [else
     (write-byte (bitwise-ior mask-bit 127) out)
     (write-bytes (integer->integer-bytes n 8 #f #t) out)])
  (if (frame-masked? f)
      (let ([key (or (frame-mask-key f) (random-mask-key))])
        (write-bytes key out)
        (write-bytes (mask-payload (frame-payload f) key) out))
      (write-bytes (frame-payload f) out))
  (void))

;; ---- decode ----

(define (read-exact in n what)
  (define bs (read-bytes n in))
  (when (or (eof-object? bs) (< (bytes-length bs) n))
    (websocket-error "connection ended inside ~a (wanted ~a bytes)" what n))
  bs)

(define (read-frame! in #:role [role 'any])
  (define b1 (read-byte in))
  (cond
    [(eof-object? b1) eof]
    [else
     (define fin? (not (zero? (bitwise-and b1 #x80))))
     (unless (zero? (bitwise-and b1 #x70))
       (websocket-error "RSV bits set but no extension was negotiated: header #x~x" b1))
     (define opcode (code->opcode (bitwise-and b1 #x0f)))
     (define b2 (read-exact in 1 "frame header"))
     (define masked? (not (zero? (bitwise-and (bytes-ref b2 0) #x80))))
     (define len7 (bitwise-and (bytes-ref b2 0) #x7f))
     (define n
       (cond
         [(= len7 126)
          (integer-bytes->integer (read-exact in 2 "16-bit frame length") #f #t)]
         [(= len7 127)
          (integer-bytes->integer (read-exact in 8 "64-bit frame length") #f #t)]
         [else len7]))
     (when (and (control-opcode? opcode)
                (or (not fin?) (> n 125)))
       (websocket-error "invalid control frame ~a: fin? ~a / ~a bytes (RFC 6455 section 5.5)"
                        opcode fin? n))
     (when (eq? role 'server)
       (unless masked?
         (websocket-error "client-to-server frame is not masked (RFC 6455 section 5.1)")))
     (when (eq? role 'client)
       (when masked?
         (websocket-error "server-to-client frame is masked (RFC 6455 section 5.1)")))
     (define mask-key
       (and masked? (read-exact in 4 "frame mask key")))
     (define raw (if (zero? n) #"" (read-exact in n "frame payload")))
     (frame fin? opcode (mask-payload raw mask-key) masked? mask-key)]))

;; ---- predicates ----

;; RFC 3629 UTF-8 validation — rejects stray continuation bytes,
;; overlong encodings (C0/C1 and shorter), UTF-16 surrogates (ED A0..),
;; and anything past U+10FFFF (F4 90.. and F5+). RFC 6455 section 5.6
;; makes this a connection-failing requirement for text messages.
(define (utf-8-bytes? b)
  (define n (bytes-length b))
  (define (cont? x) (= (bitwise-and x #xC0) #x80))
  (let loop ([i 0])
    (or (= i n)
        (let ([b0 (bytes-ref b i)])
          (cond
            [(< b0 #x80) (loop (+ i 1))]
            [(< b0 #xC2) #f]
            [(< b0 #xE0)
             (and (>= n (+ i 2))
                  (cont? (bytes-ref b (+ i 1)))
                  (loop (+ i 2)))]
            [(< b0 #xF0)
             (and (>= n (+ i 3))
                  (cont? (bytes-ref b (+ i 1)))
                  (cont? (bytes-ref b (+ i 2)))
                  ;; E0 80.. is overlong; ED A0.. is a UTF-16 surrogate
                  (not (and (= b0 #xE0) (< (bytes-ref b (+ i 1)) #xA0)))
                  (not (and (= b0 #xED) (>= (bytes-ref b (+ i 1)) #xA0)))
                  (loop (+ i 3)))]
            [(< b0 #xF5)
             (and (>= n (+ i 4))
                  (cont? (bytes-ref b (+ i 1)))
                  (cont? (bytes-ref b (+ i 2)))
                  (cont? (bytes-ref b (+ i 3)))
                  ;; F0 80.. is overlong; F4 90.. is past U+10FFFF
                  (not (and (= b0 #xF0) (< (bytes-ref b (+ i 1)) #x90)))
                  (not (and (= b0 #xF4) (>= (bytes-ref b (+ i 1)) #x90)))
                  (loop (+ i 4)))]
            [else #f])))))

(define (opcode? v)
  (and (symbol? v) (assq v opcodes) #t))
(define (data-opcode? v)
  (and (memq v '(text binary)) #t))
(define (control-opcode? v)
  (and (memq v '(close ping pong)) #t))

(provide (contract-out
          [opcode? (-> any/c boolean?)]
          [data-opcode? (-> any/c boolean?)]
          [control-opcode? (-> any/c boolean?)]
          [struct frame ((fin? boolean?)
                         (opcode opcode?)
                         (payload bytes?)
                         (masked? boolean?)
                         (mask-key (or/c bytes? #f)))]
          [frame* (->* (#:opcode opcode? #:payload bytes?)
                       (#:fin? boolean?
                        #:masked? boolean?
                        #:mask-key (or/c bytes? #f))
                       frame?)]
          [write-frame! (-> output-port? frame? void?)]
          [read-frame! (->* (input-port?)
                            (#:role (or/c 'server 'client 'any))
                            (or/c frame? eof-object?))]
          [mask-payload (-> bytes? (or/c bytes? #f) bytes?)]
          [random-mask-key (-> bytes?)]
          [utf-8-bytes? (-> bytes? boolean?)]
          [exn:fail:websocket? (-> any/c boolean?)]
          [websocket-error (-> string? any/c ... any/c)]))
