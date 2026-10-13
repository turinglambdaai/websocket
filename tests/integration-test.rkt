#lang racket/base

;; Loopback integration: a real server on 127.0.0.1 exercised with the
;; public client API — echo of text and large binary (64-bit length
;; path), inline ping/pong, ws-serve wiring, handshake rejection, and
;; the close handshake in both directions.

(require rackunit
         racket/tcp
         websocket)

;; pick an ephemeral-ish port ourselves and retry on collision, since
;; tcp-listen cannot tell us what it bound
(define (make-listener)
  (let loop ([tries 10])
    (define port (+ 20000 (random 25000)))
    (with-handlers
        ([exn:fail:network? (λ (_)
                              (if (zero? tries)
                                  (error 'make-listener "no free port")
                                  (loop (sub1 tries))))])
      (values (tcp-listen port 16 #t "127.0.0.1") port))))

;; echo each message back until the peer closes
(define (echo-handler conn)
  (let loop ()
    (define m (ws-recv conn))
    (unless (eof-object? m)
      (if (eq? (ws-message-type m) 'text)
          (ws-send-text! conn (bytes->string/utf-8 (ws-message-payload m)))
          (ws-send-binary! conn (ws-message-payload m)))
      (loop))))

(module+ test
  ;; ---- echo: text, big binary, inline ping; client-initiated close ----
  (define-values (l1 p1) (make-listener))
  (define handler-thread
    (thread
     (λ ()
       (define-values (in out) (tcp-accept l1))
       (echo-handler (ws-accept in out)))))
  (define conn (ws-connect (format "ws://127.0.0.1:~a/echo?room=1" p1)))

  (ws-send-text! conn "Hello, WebSocket!")
  (define echoed (ws-recv conn))
  (check-equal? (ws-message-type echoed) 'text)
  (check-equal? (ws-message-payload echoed) #"Hello, WebSocket!")

  (define big (make-bytes 200000 #x2a))
  (ws-send-binary! conn big)
  (define echoed-big (ws-recv conn))
  (check-equal? (ws-message-type echoed-big) 'binary)
  (check-equal? (ws-message-payload echoed-big) big)

  ;; ping is answered with pong inside ws-recv; the next message must
  ;; still flow through untouched
  (ws-ping! conn #"heartbeat")
  (ws-send-text! conn "after-ping")
  (check-equal? (ws-message-payload (ws-recv conn)) #"after-ping")

  (ws-close! conn 1000 "bye")
  ;; sync/timeout yields the thread itself when it exits in time
  (check-true (and (sync/timeout 5 handler-thread) #t)
              "echo handler should exit after peer close")
  (tcp-close l1)

  ;; ---- server-initiated close observed as eof on the client ----
  (define-values (l2 p2) (make-listener))
  (define closer-thread
    (thread
     (λ ()
       (define-values (in out) (tcp-accept l2))
       (define server-conn (ws-accept in out))
       (ws-send-text! server-conn "welcome")
       (check-equal? (ws-message-payload (ws-recv server-conn)) #"again")
       (ws-close! server-conn 1000 "done"))))
  (define conn2 (ws-connect (format "ws://127.0.0.1:~a/done" p2)))
  (check-equal? (ws-message-payload (ws-recv conn2)) #"welcome")
  (ws-send-text! conn2 "again")
  (check-equal? (ws-recv conn2) eof "client should observe the server's close as eof")
  (ws-close! conn2)
  (tcp-close l2)

  ;; ---- ws-serve wiring ----
  (define-values (l3 p3) (make-listener))
  (ws-serve l3 echo-handler)
  (define conn3 (ws-connect (format "ws://127.0.0.1:~a/served" p3)))
  (ws-send-text! conn3 "via-serve")
  (check-equal? (ws-message-payload (ws-recv conn3)) #"via-serve")
  (ws-close! conn3)
  (tcp-close l3)

  ;; ---- handshake rejection surfaces as exn:fail:websocket ----
  (define-values (l4 p4) (make-listener))
  (thread
   (λ ()
     (define-values (in out) (tcp-accept l4))
     (display "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n" out)
     (close-input-port in)
     (close-output-port out)))
  (check-exn exn:fail:websocket?
             (λ () (ws-connect (format "ws://127.0.0.1:~a/x" p4))))
  (tcp-close l4)

  ;; ---- ws-adopt: caller parses the request, lib adopts the connection ----
  (define-values (l5 p5) (make-listener))
  (define adopt-thread
    (thread
     (λ ()
       (define-values (in out) (tcp-accept l5))
       ;; the caller-level multiplexer reads the raw request itself
       (define req (ws-read-upgrade-request! in))
       (check-equal? (ws-upgrade-path req) "/adopt")
       (define conn
         (ws-adopt in out (ws-upgrade-header req "sec-websocket-key")))
       (ws-send-text! conn "adopted")
       (check-equal? (ws-message-payload (ws-recv conn)) #"back at you")
       (ws-close! conn))))
  (define conn5 (ws-connect (format "ws://127.0.0.1:~a/adopt" p5)))
  (check-equal? (ws-message-payload (ws-recv conn5)) #"adopted")
  (ws-send-text! conn5 "back at you")
  (check-equal? (ws-recv conn5) eof)
  (ws-close! conn5)
  (check-true (and (sync/timeout 5 adopt-thread) #t) "adopt handler should exit")
  (tcp-close l5))
