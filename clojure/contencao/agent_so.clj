;; agent_so.clj — SÓ a medição do agent, para comparação alternada entre plataformas.
;;
;;   clojure agent_so.clj 8 200000
;;
;; Existe porque a comparação publicada entre `agent` de Clojure e `GenServer`
;; de Elixir (534 mil contra 493 mil ops/s, 8% de diferença) foi feita do jeito
;; errado: dois processos de linguagens diferentes, medidos em momentos
;; distintos, sem alternância.
;;
;; Oito por cento está dentro do que carga de fundo explica. Para a afirmação
;; "os dois modelos custam o mesmo" valer, a medição tem de alternar entre as
;; plataformas — e é isso que `bench/fila_cruzada.sh` faz com este arquivo e
;; com `elixir/mesh/bench/genserver_so.exs`.
;;
;; Imprime UMA linha: `agent <ops_s> <ms> <final>`.

(import '[java.util.concurrent CountDownLatch])

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

(let [a (agent 0)
      t0 (System/nanoTime)
      _ (em-paralelo n-workers
          (fn [_] (dotimes [_ por-worker] (send a inc))))
      ;; `await` é o benchmark: `send` volta na hora, e medir sem esperar
      ;; mediria enfileiramento.
      _ (await a)
      ms (/ (- (System/nanoTime) t0) 1e6)]
  (printf "agent %d %.1f %d%n" (long (/ esperado (/ ms 1000.0))) ms @a)
  (flush))

(shutdown-agents)
