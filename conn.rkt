#lang racket/base

;; WebSocket connections: the opening handshake turned into a
;; connection object with port-shaped operations. Client frames are
;; always masked, server frames never are; one semaphore serializes
;; writers so a thread can sit in ws-recv while another sends.
;;
;; ws-recv returns eof once the peer closes. Closing is idempotent and
;; completes the RFC 6455 section 7 close handshake best-effort: the
;; protocol state (close frame sent) and the port lifecycle are tracked
;; separately, so observing a peer close in ws-recv does not close the
;; local ports out from under the caller — ws-close! does that.

(require racket/contract
         racket/string
         racket/tcp
         net/url
         openssl
         "frame.rkt"
         "handshake.rkt")

(struct ws-message (type payload) #:transparent)

(struct ws (in out send-masked? lock sent-close-box ports-closed-box))

;; ---- plumbing ----

(define (with-lock sem thunk)
  (dynamic-wind (λ () (semaphore-wait sem)) thunk (λ () (semaphore-post sem))))

(define (send-frame! conn f)
  ;; flush after every frame: stream ports are block-buffered and the
  ;; peer only sees bytes once we push them out
  (with-lock (ws-lock conn)
    (λ ()
      (write-frame! (ws-out conn) f)
      (flush-output (ws-out conn)))))

(define (data-frame conn opcode payload)
  (frame* #:opcode opcode #:payload payload #:masked? (ws-send-masked? conn)))

(define (sent-close? conn) (unbox (ws-sent-close-box conn)))
(define (ports-closed? conn) (unbox (ws-ports-closed-box conn)))
(define (peer-role conn) (if (ws-send-masked? conn) 'client 'server))

(define (mark-sent-close! conn)
  (set-box! (ws-sent-close-box conn) #t))

;; ---- connect / accept ----

;; net/url gives us path/param lists and query bindings; flatten both
;; into the single request-target string the GET line wants.
(define (url->request-path u)
  (define base
    (let ([segs (url-path u)])
      (if (null? segs)
          "/"
          (string-append
           "/"
           ;; url-path segments are already plain strings
           (string-join (for/list ([seg (in-list segs)])
                          (path/param-path seg))
                        "/")))))
  (define query (url-query u))
  (if (null? query)
      base
      (string-append
       base "?"
       (string-join
        ;; url-query is (listof (cons/c symbol? (or/c string? #f)))
        (for/list ([b (in-list query)])
          (if (cdr b)
              (format "~a=~a" (car b) (cdr b))
              (format "~a" (car b))))
        "&"))))

(define (ws-connect url-string #:headers [extra '()])
  (define u (string->url url-string))
  ;; url-scheme yields a string (or #f), not a symbol
  (define scheme-name
    (and (url-scheme u) (string-downcase (url-scheme u))))
  (define secure? (string=? scheme-name "wss"))
  (unless (and scheme-name (or (string=? scheme-name "ws") secure?))
    (websocket-error "unsupported scheme ~a in ~a (want ws:// or wss://)"
                     scheme-name url-string))
  (define host (url-host u))
  (unless (and (string? host) (non-empty-string? host))
    (websocket-error "missing host in ~a" url-string))
  (define port (or (url-port u) (if secure? 443 80)))
  (define host-header
    (if (or (and (not secure?) (= port 80)) (and secure? (= port 443)))
        host
        (format "~a:~a" host port)))
  (define path (url->request-path u))
  (define-values (in out)
    (if secure? (ssl-connect host port) (tcp-connect host port)))
  (with-handlers
      ([exn:fail? (λ (e)
                    (unless (port-closed? in) (close-input-port in))
                    (unless (port-closed? out) (close-output-port out))
                    (raise e))])
    (define key (ws-new-key))
    (ws-write-upgrade-request! out host-header path key #:headers extra)
    (ws-read-upgrade-response! in key)
    (ws in out #t (make-semaphore 1) (box #f) (box #f))))

(define (ws-accept in out)
  (define req (ws-read-upgrade-request! in))
  (ws-write-accept-response! out (ws-upgrade-header req "sec-websocket-key"))
  (ws in out #f (make-semaphore 1) (box #f) (box #f)))

;; One thread accepts forever; each connection gets its own handler
;; thread. The loop dies when the listener is closed.
(define (ws-serve listener handler)
  (thread
   (λ ()
     (let loop ()
       (with-handlers ([exn:fail? (λ (_) (void))])
         (define-values (in out) (tcp-accept listener))
         (thread
          (λ ()
            (with-handlers
                ([exn:fail? (λ (e)
                              (log-error "websocket: connection handler failed: ~a" e)
                              (unless (port-closed? in) (close-input-port in))
                              (unless (port-closed? out) (close-output-port out)))])
              (define conn (ws-accept in out))
              (handler conn))))
         (loop))))))

;; ---- sending ----

(define (ws-send-text! conn s)
  (send-frame! conn (data-frame conn 'text (string->bytes/utf-8 s))))

(define (ws-send-binary! conn payload)
  (send-frame! conn (data-frame conn 'binary payload)))

(define (ws-ping! conn [payload #""])
  (send-frame! conn (data-frame conn 'ping payload)))

;; ---- closing ----

(define (reply-close! conn code)
  (unless (sent-close? conn)
    (mark-sent-close! conn)
    (with-handlers ([exn:fail? void])   ; peer may already be gone
      (send-frame! conn
                   (data-frame conn 'close
                               (integer->integer-bytes code 2 #f #t))))))

(define (ws-close! conn [code 1000] [reason ""])
  (unless (<= 1000 code 4999)
    (websocket-error "close code must be in [1000, 4999], got ~a" code))
  (reply-close! conn code)
  (unless (ports-closed? conn)
    (set-box! (ws-ports-closed-box conn) #t)
    (with-handlers ([exn:fail? void])
      (close-input-port (ws-in conn))
      (close-output-port (ws-out conn)))))

;; ---- receiving ----

(define (protocol-violation! conn fmt . args)
  (reply-close! conn 1002)
  (apply websocket-error fmt args))

(define (finish-message! conn opcode chunks)
  (define payload (apply bytes-append (reverse chunks)))
  (cond
    [(eq? opcode 'text)
     (unless (utf-8-bytes? payload)
       (reply-close! conn 1007)
       (websocket-error "text message is not valid UTF-8 (closing 1007)"))
     (ws-message 'text payload)]
    [else (ws-message 'binary payload)]))

(define (ws-recv conn)
  (let loop ([chunks '()] [message-opcode #f])
    (define f (read-frame! (ws-in conn) #:role (peer-role conn)))
    (cond
      [(eof-object? f) eof]
      [else
       (define opcode (frame-opcode f))
       (define payload (frame-payload f))
       (cond
         ;; Control frames are answered inline; pongs are bookkeeping.
         [(eq? opcode 'ping)
          (with-handlers ([exn:fail? void])
            (send-frame! conn (data-frame conn 'pong payload)))
          (loop chunks message-opcode)]
         [(eq? opcode 'pong)
          (loop chunks message-opcode)]
         [(eq? opcode 'close)
          (reply-close! conn
                        (if (>= (bytes-length payload) 2)
                            (integer-bytes->integer (subbytes payload 0 2) #f #t)
                            1000))
          eof]
         [(eq? opcode 'continuation)
          (unless message-opcode
            (protocol-violation! conn "continuation frame with no message in progress"))
          (if (frame-fin? f)
              (finish-message! conn message-opcode (cons payload chunks))
              (loop (cons payload chunks) message-opcode))]
         [else
          (when message-opcode
            (protocol-violation! conn "~a frame interleaved inside a fragmented message" opcode))
          (if (frame-fin? f)
              (finish-message! conn opcode (list payload))
              (loop (list payload) opcode))])])))

(provide (contract-out
          [struct ws-message ((type (or/c 'text 'binary)) (payload bytes?))]
          [ws? (-> any/c boolean?)]
          [ws-connect (->* (string?)
                           (#:headers (listof (cons/c string? string?)))
                           ws?)]
          [ws-accept (-> input-port? output-port? ws?)]
          [ws-serve (-> tcp-listener? (-> ws? any/c) thread?)]
          [ws-recv (-> ws? (or/c ws-message? eof-object?))]
          [ws-send-text! (-> ws? string? void?)]
          [ws-send-binary! (-> ws? bytes? void?)]
          [ws-ping! (->* (ws?) (bytes?) void?)]
          [ws-close! (->* (ws?) (exact-nonnegative-integer? string?) void?)]))
