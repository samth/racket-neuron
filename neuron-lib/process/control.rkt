#lang racket/base

(require
 neuron/evaluation
 neuron/event
 neuron/process
 neuron/process/messaging
 neuron/syntax
 racket/contract/base
 racket/dict
 racket/function
 (only-in racket/list flatten make-list last)
 racket/match)

(provide
 (contract-out
  [server (-> (-> any/c any/c) process?)]
  [proxy
   (->* (process?)
        (#:filter-to (or/c (-> any/c any/c) #f)
         #:filter-from (or/c (-> any/c any/c) #f))
        process?)]
  [proxy-to
   (->* (process?)
        (#:with (or/c (-> any/c any/c) #f))
        process?)]
  [proxy-from
   (->* (process?)
        (#:with (or/c (-> any/c any/c) #f))
        process?)]
  [sink (-> (-> any/c any) process?)]
  [source (-> (-> any/c) process?)]
  [stream (-> process? process? process?)]
  [service
   (->* ((-> process? any/c))
        (#:on-drop (-> any/c process? any))
        process?)]
  [simulator (->* ((-> real? any)) (#:rate real?) process?)]
  [pipe (-> process? process? ... process?)]
  [bridge (-> process? process? process?)]
  [managed
   (->* (process?)
        (#:pre-take-eof (-> process? any)
         #:post-take-eof (-> process? any)
         #:pre-emit-eof (-> process? any)
         #:post-emit-eof (-> process? any))
        process?)]
  [shutdown (-> process? void?)]
  [shutdown-evt (-> process? evt?)]))

;; Processes

(define (server proc)
  (process (λ () (forever (emit (proc (take)))))))

(define (proxy π #:filter-to [to-proc #f] #:filter-from [from-proc #f])
  (start
   (process
    (λ ()
      (define to-evt
        (if to-proc (filter-to-evt π #:with to-proc) (forward-to-evt π)))
      (define from-evt
        (if from-proc (filter-from-evt π #:with from-proc) (forward-from-evt π)))
      (sync
       (choice-evt
        (evt-loop (λ _ to-evt))
        (evt-loop (λ _ from-evt))
        (handle-evt π die)))))
   #:on-stop (λ () (stop π))))

(define (proxy-to π #:with [proc #f])
  (start
   (process
    (λ ()
      (define evt (if proc (filter-to-evt π #:with proc) (forward-to-evt π)))
      (sync (choice-evt
             (evt-loop (λ _ evt))
             (handle-evt π die)))))
   #:on-stop (λ () (stop π))))

(define (proxy-from π #:with [proc #f])
  (start
   (process
    (λ ()
      (define evt
        (if proc (filter-from-evt π #:with proc) (forward-from-evt π)))
      (sync (choice-evt
             (evt-loop (λ _ evt))
             (handle-evt π die)))))
   #:on-stop (λ () (stop π))))

(define (sink proc)
  (process (λ () (forever (proc (take))))))

(define (source proc)
  (process (λ () (forever (emit (proc))))))

(define (stream snk src)
  (start
   (process
    (λ ()
      (sync
       (choice-evt
        (evt-loop (λ _ (forward-to-evt snk)))
        (evt-loop (λ _ (forward-from-evt src)))
        (handle-evt (evt-set snk src) die)))))
   #:on-stop (λ () (stop snk) (stop src))
   #:command (bind
              ([sink snk]
               [source src])
              #:else unhandled)))

(define (service key-proc #:on-drop [on-drop void])
  (define peers (make-hash))
  (define latch (make-semaphore))
  (define (add-peer π)
    (define key (key-proc π))
    (hash-set! peers key π)
    (semaphore-post latch)
    key)
  (define (get-peer key)
    (hash-ref peers key #f))
  (define (drop-peer key)
    (if (hash-has-key? peers key)
        (let ([π (hash-ref peers key)])
          (hash-remove! peers key)
          (on-drop key π)
          (semaphore-post latch)
          #t)
        #f))
  (start
   (process
    (λ ()
      (define (peer-take-evt)
        (evt-series
         (λ _ (take-evt))
         (match-lambda
           [(list key v)
            (if (hash-has-key? peers key)
                (handle-evt (give-evt (hash-ref peers key) v) (λ _ #t))
                (handle-evt always-evt (λ _ #f)))]
           [_ (handle-evt always-evt (λ _ #f))])))
      (define (peer-emit-evt key π)
        (replace-evt (recv-evt π) (λ (v) (emit-evt (list key v)))))
      (define (peer-emit-evts)
        (choice-evt
         latch
         (apply choice-evt
                (dict-map (hash->list peers) peer-emit-evt))))
      (sync
       (evt-loop (λ _ (peer-take-evt)))
       (evt-loop (λ _ (peer-emit-evts))))))
   #:on-stop (λ () (for-each drop-peer (dict-keys (hash->list peers))))
   #:command (bind ([peers (hash->list peers)]
                    [(add ,π) (add-peer π)]
                    [(get ,key) (get-peer key)]
                    [(drop ,key) (drop-peer key)])
                   #:else unhandled)))

(define (simulator proc #:rate [rate 10])
  (process
   (λ ()
     (define period (/ 1000.0 rate))
     (define timestamp (current-inexact-milliseconds))
     (forever
       (set! timestamp (+ timestamp period))
       (sync (alarm-evt timestamp))
       (proc period)))))

(define (pipe . πs)
  (start
   (process
    (λ ()
      (sync
       (thread (λ () (forever (emit (foldl call (take) πs)))))
       (handle-evt (apply choice-evt πs) die))))
   #:on-stop (λ () (for-each stop πs))))

(define (bridge π1 π2)
  (define (cmd π vs)
    (with-handlers ([unhandled-command? (λ _ unhandled)])
      (apply π vs)))
  (start
   (process
    (λ ()
      (sync
       (evt-loop (λ _ (couple-evt π1 π2)))
       (evt-loop (λ _ (couple-evt π2 π1)))
       (handle-evt (choice-evt π1 π2) die))))
   #:on-stop (λ () (stop π1) (stop π2))
   #:command (bind ([1 π1]
                    [2 π2])
                   #:match
                   ([v (let ([result (command π1 (list v))])
                         (if (eq? result unhandled)
                             (command π2 (list v))
                             result))]))))

(define (managed π
                 #:pre-take-eof [pre-take-eof stop]
                 #:post-take-eof [post-take-eof void]
                 #:pre-emit-eof [pre-emit-eof void]
                 #:post-emit-eof [post-emit-eof stop])
  (start
   (process
    (λ ()
      (sync
       (evt-loop
        (λ _
          (evt-series
           (λ _ (take-evt))
           (λ (v)
             (when (eof-object? v) (pre-take-eof π))
             (handle-evt
              (give-evt π v)
              (λ _ (when (eof-object? v) (post-take-eof π))))))))
       (evt-loop
        (λ _
          (evt-series
           (λ _ (recv-evt π))
           (λ (v)
             (when (eof-object? v) (pre-emit-eof π))
             (handle-evt
              (emit-evt v)
              (λ _ (when (eof-object? v) (post-emit-eof π))))))))
       (handle-evt π die))))
   #:on-stop (λ () (stop π))
   #:command π))

(define (shutdown π)
  (give π eof)
  (wait π))

(define (shutdown-evt π)
  (evt-sequence
   (λ () (give-evt π eof))
   (λ () π)))

(module+ test
  (require rackunit
           racket/async-channel)

  ;; Syntax

  (test-case
    "forever evaluates its body repeatedly."
    (define N 0)
    (define π
      (process (λ () (forever (set! N (+ N 1)) (when (> N 100) (die))))))
    (wait π)
    (check > N 100))

  (test-case
    "while evaluates its body for as long as expr evaluates to #t."
    (define count 0)
    (define π (process (λ () (while (<= count 100) (set! count (add1 count))))))
    (wait π)
    (check > count 100))

  (test-case
    "until evaluates its body for as long as expr evaluates to #f."
    (define count 0)
    (define π (process (λ () (until (> count 100) (set! count (add1 count))))))
    (wait π)
    (check > count 100))

  ;; Events

  (test-case
    "An evt-set is ready when every evt is ready."
    (define πs (for/list ([_ 10]) (process (λ () (take)))))
    (define evt (apply evt-set πs))
    (for-each give πs)
    (check-false (not (sync evt))))

  (test-case
    "An evt-set is not ready until every evt is ready."
    (define πs (for/list ([_ 10]) (process (λ () (take)))))
    (define evt (apply evt-set πs))
    (for ([π πs])
      (check-false (ormap (λ (π) (sync/timeout 0 π)) πs))
      (check-false (sync/timeout 0 evt)))
    (for-each give πs)
    (for ([π πs])
      (check-false (not (sync π))))
    (check-false (not (sync evt))))

  (test-case
    "An evt-set syncs to the list of results of evts."
    (define πs (for/list ([i 10]) (process (λ () (emit i)))))
    (define evt (apply evt-set (map recv-evt πs)))
    (check equal? (sync evt) '(0 1 2 3 4 5 6 7 8 9)))

  (test-case
    "An evt-sequence is ready when all generated events are ready."
    (check-false
     (not (sync (apply evt-sequence (make-list 10 (λ () (process void))))))))

  (test-case
    "An evt-sequence is not ready until all generated events are ready."
    (define πs (for/list ([_ 10]) (process emit)))
    (define evt (apply evt-sequence (map (λ (π) (λ () π)) πs)))
    (for ([π πs])
      (check-false (sync/timeout 0 π))
      (check-false (sync/timeout 0 evt))
      (recv π))
    (check-false (not (sync evt))))

  (test-case
    "An evt-sequence syncs on the results of make-evts in order."
    (define result null)
    (define (make-π i)
      (λ () (process (λ () (set! result (cons i result))))))
    (sync (apply evt-sequence (for/list ([i 10]) (make-π i))))
    (check equal? result '(9 8 7 6 5 4 3 2 1 0)))

  (test-case
    "An evt-sequence syncs to the same result as the last event generated."
    (define πs (for/list ([_ 10]) (process void)))
    (check eq? (sync (apply evt-sequence (map (λ (π) (λ () π)) πs))) (last πs)))

  (test-case
    "An evt-series is ready when all generated events are ready."
    (check-false
     (not (sync (apply evt-series (make-list 10 (λ _ (process void))))))))

  (test-case
    "An evt-series is not ready until all generated events are ready."
    (define πs (for/list ([_ 10]) (process emit)))
    (define evt (apply evt-series (map (λ (π) (λ _ π)) πs)))
    (for ([π πs])
      (check-false (sync/timeout 0 π))
      (check-false (sync/timeout 0 evt))
      (recv π))
    (check-false (not (sync evt))))

  (test-case
    "An evt-series syncs on the results of make-evts in order."
    (define result null)
    (define (make-π i)
      (λ _ (process (λ () (set! result (cons i result))))))
    (sync (apply evt-series (for/list ([i 10]) (make-π i))))
    (check equal? result '(9 8 7 6 5 4 3 2 1 0)))

  (test-case
    "An evt-series syncs to the same result as the last event generated."
    (define πs (for/list ([_ 10]) (process void)))
    (check eq? (sync (apply evt-series (map (λ (π) (λ _ π)) πs))) (last πs)))

  (test-case
    "An evt-series calls make-evt on the result of the previous event."
    (define (make-evt)
      (λ (i) (handle-evt always-evt (λ _ (+ i 1)))))
    (check = (sync (apply evt-series #:init 0 (for/list ([i 10]) (make-evt))))
           10))

  (test-case
    "An evt-loop repeatedly syncs on the result of next-evt."
    (define (next-evt i)
      (handle-evt always-evt (λ _ (if (<= i 100) (+ i 1) (raise 19)))))
    (check = (with-handlers ([number? (λ (v) v)])
               (sync (evt-loop #:init 0 next-evt)))
           19))

  ;; Processes

  (test-case
    "A server applies proc and emits the result."
    (define π (server add1))
    (give π 23)
    (check = (recv π) 24))

  (test-case
    "A proxy forwards to π."
    (define π (proxy (server (λ (x) (* x 2)))))
    (give π 37)
    (check = (recv π) 74))

  (test-case
    "A proxy forwards from π."
    (define π (proxy (server (λ (x) (* x 2)))))
    (give π 43)
    (check = (recv π) 86))

  (test-case
    "A proxy stops π when it stops."
    (define π (process deadlock))
    (stop (proxy π))
    (check-true (dead? π)))

  (test-case
    "A proxy dies when π dies."
    (define π (process deadlock))
    (define π* (proxy π))
    (kill π)
    (wait π*)
    (check-true (dead? π*)))

  (test-case
    "proxy with #:filter-to and #:filter-from"
    (define π (process (λ () (emit 4) (check = (take) 9))))
    (define π* (proxy π #:filter-to sub1 #:filter-from (curry * 3)))
    (check = (recv π*) 12)
    (check-true (give π* 10)))

  (test-case
    "A proxy-to forwards to π."
    (define π (server add1))
    (define to-π (proxy-to π))
    (for ([i 10])
      (check-true (give to-π i))
      (check = (recv π) (add1 i))))

  (test-case
    "A proxy-to does not forward from π."
    (define π (server add1))
    (define to-π (proxy-to π))
    (for ([i 10])
      (give to-π i)
      (check-false (sync/timeout 0 (recv-evt to-π)))
      (check = (recv π) (add1 i))))

  (test-case
    "A proxy-to stops π when it stops."
    (define π (server add1))
    (define to-π (proxy-to π))
    (check-pred alive? π)
    (check-pred alive? to-π)
    (stop to-π)
    (check-pred dead? to-π)
    (check-pred dead? π))

  (test-case
    "A proxy-to dies when π dies."
    (define π (server add1))
    (define to-π (proxy-to π))
    (check-pred alive? π)
    (check-pred alive? to-π)
    (kill π)
    (check-pred dead? π)
    (wait to-π)
    (check-pred dead? to-π))

  (test-case
    "proxy-to #:with filter"
    (define π (process (λ () (check = (take) 6))))
    (check-true (give (proxy-to π #:with (curry * 3)) 2)))

  (test-case
    "A proxy-from does not forward to π."
    (define π (server add1))
    (define from-π (proxy-from π))
    (for ([i 10])
      (check-false (sync/timeout 0 (give-evt from-π i)))))

  (test-case
    "A proxy-from forwards from π."
    (define π (server add1))
    (define from-π (proxy-from π))
    (for ([i 10])
      (check-true (give π i))
      (check = (recv from-π) (add1 i))))

  (test-case
    "A proxy-from stops π when it stops."
    (define π (server add1))
    (define from-π (proxy-from π))
    (check-pred alive? π)
    (check-pred alive? from-π)
    (stop from-π)
    (check-pred dead? from-π)
    (check-pred dead? π))

  (test-case
    "A proxy-from dies when π dies."
    (define π (server add1))
    (define from-π (proxy-from π))
    (check-pred alive? π)
    (check-pred alive? from-π)
    (kill π)
    (check-pred dead? π)
    (wait from-π)
    (check-pred dead? from-π))

  (test-case
    "proxy-from #:with filter"
    (define π (process (λ () (emit 3))))
    (check = (recv (proxy-from π #:with (curry * 4))) 12))

  (test-case
    "A sink applies proc to each value taken."
    (define last -1)
    (define π (sink (λ (n) (check = n (+ last 1)) (set! last n))))
    (for ([i 10]) (give π i)))

  (test-case
    "A sink ignores the result of proc."
    (define π (sink add1))
    (give π 31)
    (check-false (sync/timeout 0 (recv-evt π))))

  (test-case
    "A source applies proc repeatedly and emits each result."
    (define N -1)
    (define π (source (λ () (set! N (+ N 1)) N)))
    (for ([i 10]) (check = (recv π) i)))

  (test-case
    "A stream forwards to snk."
    (define result-ch (make-channel))
    (define π (stream (sink (curry channel-put result-ch)) (source void)))
    (for ([i 10])
      (give π i)
      (check = (channel-get result-ch) i)))

  (test-case
    "A stream forwards from src."
    (define π (stream (sink void) (source random)))
    (for ([_ 10])
      (define v (recv π))
      (check >= v 0)
      (check <= v 1)))

  (test-case
    "A stream stops snk and src when it stops."
    (define ch (make-async-channel))
    (define π
      (stream
       (start (sink deadlock) #:on-stop (λ () (async-channel-put ch #t)))
       (start (source deadlock) #:on-stop (λ () (async-channel-put ch #t)))))
    (stop π)
    (check-true (async-channel-get ch))
    (check-true (async-channel-get ch)))

  (test-case
    "A stream dies when snk and src die."
    (define snk (sink deadlock))
    (define src (source deadlock))
    (define sock (stream snk src))
    (kill snk)
    (kill src)
    (wait sock)
    (check-true (dead? sock)))

  (test-case
    "A stream does not die when snk dies if src is alive."
    (define snk (sink deadlock))
    (define src (source deadlock))
    (define sock (stream snk src))
    (kill snk)
    (check-true (alive? src))
    (check-false (dead? sock)))

  (test-case
    "A stream does not die when src dies if snk is alive."
    (define snk (sink deadlock))
    (define src (source deadlock))
    (define sock (stream snk src))
    (kill src)
    (check-true (alive? snk))
    (check-false (dead? sock)))

  (test-case
    "The stream command 'sink returns snk."
    (define snk (sink deadlock))
    (define sock (stream snk (source deadlock)))
    (check eq? (sock 'sink) snk))

  (test-case
    "The stream command 'source returns src."
    (define src (source deadlock))
    (define sock (stream (sink deadlock) src))
    (check eq? (sock 'source) src))

  (test-case
    "A simulator calls proc at a frequency of rate."
    (define N 0)
    (define t0 (current-inexact-milliseconds))
    (wait (simulator (λ _ (set! N (+ N 1)) (when (= N 10) (die))) #:rate 100))
    (define t10 (current-inexact-milliseconds))
    (check = N 10)
    (check >= (- t10 t0) 100))

  (test-case
    "A pipe calls πs in series."
    (define π (apply pipe (for/list ([_ 10]) (server add1))))
    (give π 49)
    (check = (recv π) 59))

  (test-case
    "A pipe stops all πs when it stops."
    (define πs (for/list ([_ 10]) (process deadlock)))
    (stop (apply pipe πs))
    (for ([π πs]) (check-true (dead? π))))

  (test-case
    "A pipe dies when any π dies."
    (for ([i 3])
      (define πs (for/list ([_ 3]) (process deadlock)))
      (define p (apply pipe πs))
      (kill (list-ref πs i))
      (wait p)
      (check-true (dead? p))))

  (test-case
    "A bridge forwards from π1 to π2, and vice versa."
    (wait
     (bridge
      (process (λ () (emit 51) (check = (take) 53)))
      (process (λ () (check = (take) 51) (emit 53))))))

  (test-case
    "A bridge stops π1 and π2 when it stops."
    (define π1 (process deadlock))
    (define π2 (process deadlock))
    (stop (bridge π1 π2))
    (check-true (dead? π1))
    (check-true (dead? π2)))

  (test-case
    "A bridge dies when π1 dies."
    (define π1 (process deadlock))
    (define π (bridge π1 (process deadlock)))
    (kill π1)
    (wait π)
    (check-true (dead? π)))

  (test-case
    "A bridge dies when π2 dies."
    (define π2 (process deadlock))
    (define π (bridge (process deadlock) π2))
    (kill π2)
    (wait π)
    (check-true (dead? π)))

  (test-case
    "bridge command 1 returns π1."
    (define π1 (process deadlock))
    (define π2 (process deadlock))
    (check equal? π1 ((bridge π1 π2) 1)))

  (test-case
    "bridge command 2 return π2."
    (define π1 (process deadlock))
    (define π2 (process deadlock))
    (check equal? π2 ((bridge π1 π2) 2)))

  (test-case
    "A bridge forwards unhandled commands to π1 first."
    (define π
      (bridge (start (process deadlock) #:command add1)
              (process deadlock)))
    (check-pred process? (π 1))
    (check = 4 (π 3)))

  (test-case
    "A bridge forwards unhandled commands to π2 when π1 fails."
    (define π
      (bridge (process deadlock)
              (start (process deadlock) #:command sub1)))
    (check-pred process? (π 2))
    (check = 2 (π 3)))

  (test-case
    "A bridge raises unhandled-command when π1 and π2 both fail."
    (define π
      (bridge (process deadlock)
              (process deadlock)))
    (check-exn unhandled-command? (λ () (π 3))))

  (test-case
    "A managed process forwards non-eof values to and from π."
    (check = (call (managed (server add1)) 57) 58))

  (test-case
    "A managed process calls pre-take-eof before eof is given."
    (define π (managed (server add1)))
    (give π eof)
    (wait π)
    (check-true (dead? π)))

  (test-case
    "A managed process calls post-emit-eof after π emits eof."
    (define π (managed (process (λ () (emit eof) (deadlock)))))
    (recv π)
    (wait π)
    (check-true (dead? π)))

  (test-case
    "A managed process stops π when it stops."
    (define stopped #f)
    (stop (managed (start (process deadlock)
                          #:on-stop (λ () (set! stopped #t)))))
    (check-true stopped))

  (test-case
    "A managed process dies when π dies."
    (define π (process deadlock))
    (define π* (managed π))
    (kill π)
    (wait π*)
    (check-pred dead? π*))

  (test-case
    "A managed process forwards commands to π."
    (define π (start (process deadlock) #:command add1))
    (check = ((managed π) 59) 60))

  (test-case
    "shutdown gives eof to π and blocks until it dies."
    (define π (process (λ () (check-true (eof-object? (take))))))
    (shutdown π)
    (check-true (dead? π)))

  (test-case
    "shutdown-evt returns a synchronizable event."
    (check-pred evt? (shutdown-evt (process deadlock))))

  (test-case
    "shutdown-evt gives eof to π and syncs when π dies."
    (define π (process (λ () (check-pred eof-object? (take)))))
    (sync (shutdown-evt π))
    (check-pred dead? π))

  (test-case
    "shutdown-evt syncs to π."
    (define π (managed (process deadlock)))
    (check eq? (sync (shutdown-evt π)) π)))
