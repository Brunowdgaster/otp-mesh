#!/usr/bin/env bash
#
# fila_cruzada.sh — "fila + guardião" custa o mesmo na JVM e na BEAM?
#
#   bash bench/fila_cruzada.sh
#   REPS=9 bash bench/fila_cruzada.sh
#
# ## Por que existe: uma correção
#
# O README publicou que o `agent` de Clojure **empata** com o `GenServer` de
# Elixir — 534 mil contra 493 mil ops/s, "8% de diferença" — e concluiu que o
# modelo custa o mesmo nas duas plataformas.
#
# O método estava errado: os dois números vieram de processos diferentes, em
# momentos diferentes, **sem alternância**, e havia carga de fundo na máquina.
# 8% está dentro do que essa carga explica.
#
# Refeito por `bench/cruzado.sh`, que aplica as cinco regras de medição deste
# repositório, o resultado é **não determinado**: as faixas das amostras se
# sobrepõem (374–591 mil contra 212–473 mil) e a margem não supera a dispersão.
#
# A substância sobrevive — as duas ficam na mesma ordem de grandeza, longe dos
# 106 M do `:counters` e dos 62 mil do STM. A precisão, não.
#
# ## O que está sendo comparado
#
#   * **Clojure `agent`** — `send` enfileira e volta; `await` espera o
#     esvaziamento. Sem o `await`, mediria enfileiramento, não trabalho.
#   * **Elixir `GenServer.call`** — ida e volta síncrona por incremento.
#
# Não é comparação perfeita: `send` é assíncrono e `call` é síncrono. A versão
# assíncrona da BEAM é o `cast`, e ela **colapsa** por falta de contrapressão
# (17 mil ops/s, 811 mil mensagens na caixa) — medido em `bench/contencao.exs`.
# O `call` é o que alguém usaria de verdade, e por isso é ele que entra aqui.

exec bash "$(dirname "$0")/cruzado.sh" \
  "Clojure agent" "clojure/contencao" "clojure agent_so.clj" "agent" \
  "Elixir GenServer" "elixir/mesh" "mix run bench/genserver_so.exs" "genserver"
