#!/usr/bin/env bash
#
# contador_cruzado.sh — contador sem bloqueio: BEAM contra JVM, alternando.
#
#   bash bench/contador_cruzado.sh
#   REPS=9 bash bench/contador_cruzado.sh
#
# ## Por que existe: a segunda correção
#
# O README publicou que o `:counters` da BEAM bate o `AtomicLong` da JVM por
# **3,4x** (106,4 M contra 31,1 M ops/s). A **explicação** continua de pé:
# `:counters` com `write_concurrency` é fragmentado por escalonador e não paga
# disputa de linha de cache. O **número** tinha o mesmo defeito de método que a
# comparação `agent` × `GenServer` — processos e momentos distintos, sem
# alternância, com carga de fundo na máquina.
#
# ## O que está sendo comparado, e por que não é a mesma coisa
#
#   * **JVM `AtomicLong`** — CAS numa única palavra de 64 bits. Simples, e
#     paga disputa de linha de cache entre núcleos.
#   * **BEAM `:counters` com `write_concurrency`** — fragmentado por
#     escalonador, somado na leitura. Troca leitura mais cara por escrita sem
#     disputa.
#
# São estratégias diferentes para o mesmo problema, e é aí que está a pergunta:
# fragmentar vale a disputa que ela evita?
#
# Com 8 trabalhadores numa máquina de 4 núcleos físicos, a fragmentação tem
# onde render. Com 1 trabalhador a comparação provavelmente inverte, e isso
# **não foi medido aqui**.

exec bash "$(dirname "$0")/cruzado.sh" \
  "JVM AtomicLong" "clojure/contencao" "clojure atomic_so.clj" "atomiclong" \
  "BEAM :counters" "elixir/mesh" "mix run bench/counters_so.exs" "counters"
