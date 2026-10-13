#lang racket/base

;; Frame codec golden vectors and roundtrips (RFC 6455 section 5).

(require rackunit
         racket/port
         websocket)

;; ---- golden vectors ----

;; RFC 6455 section 5.7: unmasked text "Hello"
(check-equal?
 (let ([out (open-output-bytes)])
   (write-frame! out (frame* #:opcode 'text #:payload #"Hello"))
   (get-output-bytes out))
 (bytes #x81 #x05 72 101 108 108 111))

;; Same frame masked with key 01 02 03 04 (hand-computed XOR)
(check-equal?
 (let ([out (open-output-bytes)])
   (write-frame! out (frame* #:opcode 'text #:payload #"Hello"
                             #:masked? #t #:mask-key #"\1\2\3\4"))
   (get-output-bytes out))
 (bytes #x81 #x85 1 2 3 4 #x49 #x67 #x6F #x68 #x6E))

;; ---- decode roundtrips ----

(define (decode-frame bs #:role [role 'any])
  (read-frame! (open-input-bytes bs) #:role role))

(check-equal? (frame-payload (decode-frame (bytes #x81 #x05 72 101 108 108 111))) #"Hello")
(check-equal? (frame-opcode (decode-frame (bytes #x81 #x05 72 101 108 108 111))) 'text)
(check-true (frame-fin? (decode-frame (bytes #x81 #x05 72 101 108 108 111))))

;; masked client frame, decoded from the server's chair: payload comes
;; back unmasked, wire state preserved
(define wire (bytes #x81 #x85 1 2 3 4 #x49 #x67 #x6F #x68 #x6E))
(define masked (decode-frame wire #:role 'server))
(check-true (frame-masked? masked))
(check-equal? (frame-mask-key masked) #"\1\2\3\4")
(check-equal? (frame-payload masked) #"Hello")

;; 16-bit length path (payload of 300 bytes)
(define mid (make-bytes 300 #x7f))
(define mid-frame
  (decode-frame
   (bytes-append
    (let ([out (open-output-bytes)])
      (write-frame! out (frame* #:opcode 'binary #:payload mid))
      (get-output-bytes out)))))
(check-equal? (frame-payload mid-frame) mid)

;; 64-bit length path (payload of 70000 bytes)
(define big (make-bytes 70000 #x2a))
(define big-frame
  (decode-frame
   (bytes-append
    (let ([out (open-output-bytes)])
      (write-frame! out (frame* #:opcode 'binary #:payload big))
      (get-output-bytes out)))))
(check-equal? (frame-payload big-frame) big)

;; fragmentation: text start + continuation, both unfragmented payload-wise
(check-equal? (frame-payload (decode-frame (bytes #x01 #x02 #x61 #x62))) #"ab")
(check-equal? (frame-opcode (decode-frame (bytes #x01 #x02 #x61 #x62))) 'text)
(check-false (frame-fin? (decode-frame (bytes #x01 #x02 #x61 #x62))))
(check-equal? (frame-opcode (decode-frame (bytes #x80 #x01 #x63))) 'continuation)

;; ---- errors ----

(check-exn exn:fail:websocket?
           (λ () (read-frame! (open-input-bytes (bytes #xC1 #x02 #x61 #x62)))))
;; control frame with payload > 125
(check-exn exn:fail:websocket?
           (λ () (read-frame! (open-input-bytes (bytes #x8A #x7E #x00 #x7E)))))
;; unfragmented-violation: fragmented ping
(check-exn exn:fail:websocket?
           (λ () (read-frame! (open-input-bytes (bytes #x09 #x00)))))
;; server must reject unmasked client frames
(check-exn exn:fail:websocket?
           (λ () (decode-frame (bytes #x81 #x05 72 101 108 108 111) #:role 'server)))
;; client must reject masked server frames
(check-exn exn:fail:websocket?
           (λ () (decode-frame wire #:role 'client)))
;; reserved opcode 3
(check-exn exn:fail:websocket?
           (λ () (read-frame! (open-input-bytes (bytes #x83 #x00)))))
;; oversized control frame on write
(check-exn exn:fail:websocket?
           (λ () (write-frame! (open-output-bytes)
                               (frame* #:opcode 'ping #:payload (make-bytes 126)))))
;; fragmented control frame on write
(check-exn exn:fail:websocket?
           (λ () (write-frame! (open-output-bytes)
                               (frame* #:opcode 'ping #:payload #"" #:fin? #f))))
;; bad mask key length
(check-exn exn:fail:websocket?
           (λ () (mask-payload #"abc" #"too-long")))

;; ---- misc ----

(check-equal? (read-frame! (open-input-bytes #"")) eof)
(check-equal? (mask-payload #"Hello" #f) #"Hello")
(check-equal? (mask-payload (mask-payload #"Hello" #"\1\2\3\4") #"\1\2\3\4") #"Hello")
(check-true (opcode? 'text))
(check-false (opcode? 'nope))
(check-true (control-opcode? 'ping))
(check-true (data-opcode? 'binary))
(check-false (control-opcode? 'text))
(check-equal? (bytes-length (random-mask-key)) 4)

;; ---- UTF-8 validation (RFC 3629) ----

(check-true (utf-8-bytes? #""))
(check-true (utf-8-bytes? #"Hello"))
(check-true (utf-8-bytes? (string->bytes/utf-8 "你好，世界 — 🚀")))
(check-true (utf-8-bytes? #"\xE4\xB8\xAD"))    ; 中, clean 3-byte
(check-false (utf-8-bytes? #"\x80"))           ; stray continuation byte
(check-false (utf-8-bytes? #"\xC0\x80"))       ; overlong NUL
(check-false (utf-8-bytes? #"\xC1\xBF"))       ; overlong 2-byte
(check-false (utf-8-bytes? #"\xE0\x80\x80"))   ; overlong 3-byte
(check-false (utf-8-bytes? #"\xED\xA0\x80"))   ; UTF-16 surrogate D800
(check-false (utf-8-bytes? #"\xF4\x90\x80\x80")) ; past U+10FFFF
(check-false (utf-8-bytes? #"\xF5\x80\x80\x80")) ; beyond the 4-byte range
(check-false (utf-8-bytes? #"\xE4\xB8"))       ; truncated sequence
