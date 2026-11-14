;; contencao.clj — estado compartilhado sob contenção: o que cada coordenação custa.
;;
;;   clojure contencao.clj
;;   clojure contencao.clj 8 200000
;;
;; ## Por que este experimento existe neste projeto
;;
;; O `Mesh.Stats` do núcleo é um GenServer que mantém contadores. Toda
;; atualização passa pela caixa de mensagens dele, o que **serializa** as
;; escritas: é a resposta da BEAM para estado compartilhado — não compartilhe,
;; ponha num processo e mande mensagens.
;;
;; Clojure dá a resposta oposta: compartilhe, mas torne a mutação coordenada.
;; E dá quatro mecanismos diferentes para isso, com custos diferentes:
;;
;;   * **sem coordenação** -- array mutável, leitura-modificação-escrita não
;;     atômica. Está aqui para mostrar o que a coordenação compra;
;;   * **AtomicLong** (do JDK) -- CAS numa única palavra, o piso do custo;
;;   * **atom** -- CAS com laço de retentativa sobre valor imutável;
;;   * **ref** (STM) -- transação, com retentativa coordenada entre vários refs;
;;   * **agent** -- fila assíncrona com um guardião serializando as escritas,
;;     que é **o modelo da BEAM dentro de Clojure**.
;;
;; ## A armadilha que este benchmark tem de evitar
;;
;; `send` para um agent **retorna imediatamente**: ele enfileira e volta. Um
;; benchmark ingênuo mediria "enfileirar 1,6 milhão de funções", que é rápido e
;; não é o trabalho. O número sairia absurdo e a conclusão, invertida.
;;
;; Por isso cada estratégia é medida até o **trabalho estar feito**, e o
;; resultado só vale se o contador final bater com o esperado. Throughput de
;; resposta errada não é throughput.
;;
;; É a mesma classe de erro que a medição de memória deste projeto cometeu
;; antes: medir depois, com milhões de mensagens ainda em trânsito.

(import '[java.util.concurrent.atomic AtomicLong]
        '[java.util.concurrent CountDownLatch])

(def argumentos *command-line-args*)

(def n-workers (if (first argumentos) (parse-long (first argumentos)) 8))
(def por-worker (if (second argumentos) (parse-long (second argumentos)) 200000))
(def esperado (* n-workers por-worker))

(defn em-paralelo
  "Roda `f` em `n` threads de plataforma e espera todas terminarem.

  Threads de plataforma, não virtuais: queremos contenção real entre núcleos.
  Threads virtuais sobre poucos carregadores reduziriam o paralelismo e
  mediriam menos contenção do que existe."
  [n f]
  (let [partida (CountDownLatch. 1)
        fim (CountDownLatch. n)
        ts (doall
             (for [i (range n)]
               (.start
                 (Thread/ofPlatform)
                 (reify Runnable
                   (run [_]
                     ;; Partida sincronizada: sem isto a primeira thread
                     ;; terminaria antes de a ultima comecar, e a contencao
                     ;; medida seria menor que a real.
                     (.await partida)
                     (f i)
                     (.countDown fim))))))]
    (.countDown partida)
    (.await fim)
    ts))

(defn medir
  "Mede `corpo` e devolve {:ms, :ops-s, :final, :correto?}.

  `ler` e chamada DEPOIS de o corpo terminar: e o valor final que decide se o
  numero significa algo."
  [corpo ler]
  (let [t0 (System/nanoTime)
        _ (corpo)
        ms (/ (- (System/nanoTime) t0) 1e6)
        final (ler)]
    {:ms ms
     :ops-s (long (/ esperado (/ ms 1000.0)))
     :final final
     :correto? (= final esperado)}))

;; ---------------------------------------------------------------- estrategias

(defn sem-coordenacao []
  (let [arr (long-array 1)]
    (medir
      #(em-paralelo n-workers
         (fn [_]
           (dotimes [_ por-worker]
             ;; Leitura-modificacao-escrita NAO atomica: duas threads leem o
             ;; mesmo valor e escrevem o mesmo incremento. Atualizacoes se
             ;; perdem, silenciosamente.
             (aset arr 0 (unchecked-inc (aget arr 0))))))
      #(aget arr 0))))

(defn atomic-long []
  (let [a (AtomicLong. 0)]
    (medir
      #(em-paralelo n-workers
         (fn [_] (dotimes [_ por-worker] (.incrementAndGet a))))
      #(.get a))))

(defn clojure-atom []
  (let [a (atom 0)]
    (medir
      #(em-paralelo n-workers
         (fn [_] (dotimes [_ por-worker] (swap! a inc))))
      #(deref a))))

(defn clojure-ref []
  (let [r (ref 0)]
    (medir
      #(em-paralelo n-workers
         (fn [_] (dotimes [_ por-worker] (dosync (alter r inc)))))
      #(deref r))))

(defn clojure-agent []
  (let [a (agent 0)]
    (medir
      #(do
         (em-paralelo n-workers
           (fn [_] (dotimes [_ por-worker] (send a inc))))
         ;; ESTA LINHA e o benchmark. Sem ela mediriamos enfileiramento, nao
         ;; trabalho: `send` volta na hora. O agent e o unico mecanismo aqui em
         ;; que esquecer de esperar produz um numero bonito e falso.
         (await a))
      #(deref a))))

;; --------------------------------------------- experimento 2: dois contadores

(defn transfere-atoms
  "Transfere entre DOIS atoms. A soma deveria se conservar -- e nao se conserva.

  Nao e bug de implementacao: dois `swap!` sao duas operacoes atomicas
  separadas, e nada impede outra thread de observar o meio. Um atom coordena
  UMA referencia."
  [n]
  (let [a (atom 1000000) b (atom 0) violacoes (AtomicLong. 0)]
    (em-paralelo n-workers
      (fn [_]
        (dotimes [_ n]
          (swap! a dec)
          ;; Uma thread observando aqui ve a soma errada.
          (swap! b inc)
          (when (not= 1000000 (+ @a @b))
            (.incrementAndGet violacoes)))))
    {:soma (+ @a @b) :violacoes (.get violacoes)}))

(defn transfere-refs
  "O mesmo com refs, dentro de uma transacao. A soma se conserva, e a leitura
  de dentro da transacao nunca ve o meio."
  [n]
  (let [a (ref 1000000) b (ref 0) violacoes (AtomicLong. 0)]
    (em-paralelo n-workers
      (fn [_]
        (dotimes [_ n]
          (dosync
            (alter a dec)
            (alter b inc)
            (when (not= 1000000 (+ @a @b))
              (.incrementAndGet violacoes))))))
    {:soma (+ @a @b) :violacoes (.get violacoes)}))

;; ------------------------------------------------------------------- relatorio

(defn -main []
  (println)
  (println "=== Estado compartilhado sob contencao (Clojure) ===")
  (println)
  (printf "clojure      : %s%n" (clojure-version))
  (printf "jvm          : %s%n" (System/getProperty "java.version"))
  (printf "nucleos      : %d%n" (.availableProcessors (Runtime/getRuntime)))
  (printf "workers      : %d, cada um com %d incrementos%n" n-workers por-worker)
  (printf "esperado     : %d%n" esperado)
  (println)

  (printf "%-18s %10s %14s %14s %9s%n"
          "estrategia" "ms" "ops/s" "final" "correto?")
  (println (apply str (repeat 70 "-")))

  (doseq [[nome f] [["sem coordenacao" sem-coordenacao]
                    ["AtomicLong (JDK)" atomic-long]
                    ["atom (CAS)" clojure-atom]
                    ["ref (STM)" clojure-ref]
                    ["agent (fila)" clojure-agent]]]
    (let [r (f)]
      (printf "%-18s %10.1f %14d %14d %9s%n"
              nome (:ms r) (:ops-s r) (:final r)
              (if (:correto? r) "sim" "NAO"))
      (flush)))

  (println)
  (println "=== Dois contadores: o que o atom NAO faz ===")
  (println)
  (println "  Transferir entre dois contadores conservando a soma. Cada thread")
  (println "  verifica a soma logo depois de mexer nos dois.")
  (println)

  (let [n 20000
        ra (transfere-atoms n)
        rr (transfere-refs n)]
    (printf "%-18s %12s %14s%n" "mecanismo" "soma final" "violacoes")
    (println (apply str (repeat 48 "-")))
    (printf "%-18s %12d %14d%n" "dois atoms" (:soma ra) (:violacoes ra))
    (printf "%-18s %12d %14d%n" "dois refs (STM)" (:soma rr) (:violacoes rr))
    (println)
    (println "  A soma FINAL fecha nos dois: cada swap! e atomico e nenhum")
    (println "  incremento se perde. O que difere e o MEIO: com dois atoms as")
    (println "  threads observam estados em que a soma esta errada, porque")
    (println "  swap! a e swap! b sao duas operacoes. Dentro de dosync, nao.")
    (println)
    (println "  E por isso que STM custa mais caro que CAS na tabela acima:")
    (println "  ela coordena VARIAS referencias, nao uma. Pagar por STM para")
    (println "  incrementar um contador e pagar por algo que nao se usa."))

  (println)
  (println "=== Leitura ===")
  (println)
  (println "  A linha 'sem coordenacao' e a mais importante: ela e a mais")
  (println "  rapida e esta ERRADA. Atualizacoes se perdem em silencio -- sem")
  (println "  excecao, sem aviso, so um numero menor que o esperado.")
  (println)
  (println "  O agent e o mecanismo mais parecido com o Mesh.Stats do nucleo:")
  (println "  uma fila, um guardiao, escritas serializadas. A comparacao")
  (println "  direta com o GenServer esta em elixir/mesh/bench/contencao.exs.")
  (flush)
  (shutdown-agents))

(-main)
