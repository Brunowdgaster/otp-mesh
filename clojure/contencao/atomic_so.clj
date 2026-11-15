;; atomic_so.clj — SÓ a medição do AtomicLong, para comparação alternada.
;;
;;   clojure atomic_so.clj 8 200000
;;
;; Par de `elixir/mesh/bench/counters_so.exs`. Ver `bench/fila_cruzada.sh` e
;; `bench/contador_cruzado.sh`: a comparação publicada entre `:counters` da
;; BEAM e `AtomicLong` da JVM (3,4x) tinha o mesmo defeito de método que a do
;; agent — processos distintos, momentos distintos, sem alternância.
;;
;; Imprime UMA linha: `atomiclong <ops_s> <ms> <final>`.

(import '[java.util.concurrent.atomic AtomicLong]
        '[java.util.concurrent CountDownLatch])

(def args *command-line-args*)
(def n-workers (if (first args) (parse-long (first args)) 8))
(def por-worker (if (second args) (parse-long (second args)) 200000))
(def esperado (* n-workers por-worker))

(defn em-paralelo [n f]
  (let [partida (CountDownLatch. 1)
        fim (CountDownLatch. n)]
    (doseq [i (range n)]
      (.start (Thread/ofPlatform)
              (reify Runnable
                (run [_]
                  (.await partida)
                  (f i)
                  (.countDown fim)))))
    (.countDown partida)
    (.await fim)))

(let [a (AtomicLong. 0)
      t0 (System/nanoTime)
      _ (em-paralelo n-workers
          (fn [_] (dotimes [_ por-worker] (.incrementAndGet a))))
      ms (/ (- (System/nanoTime) t0) 1e6)]
  (printf "atomiclong %d %.1f %d%n" (long (/ esperado (/ ms 1000.0))) ms (.get a))
  (flush))
