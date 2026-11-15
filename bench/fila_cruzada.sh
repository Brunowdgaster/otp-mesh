#!/usr/bin/env bash
#
# fila_cruzada.sh — "fila + guardião" custa o mesmo na JVM e na BEAM?
#
#   bash bench/fila_cruzada.sh
#   REPS=9 bash bench/fila_cruzada.sh
#
# ## Por que este script existe: uma correção
#
# O README deste projeto publicou que o `agent` de Clojure **empata** com o
# `GenServer` de Elixir — 534 mil contra 493 mil ops/s, 8% de diferença — e
# concluiu que "o modelo custa o mesmo nas duas plataformas".
#
# A medição estava errada no método:
#
#   * os dois números vieram de **processos diferentes, em momentos
#     diferentes**, sem alternância;
#   * havia **carga de fundo** na máquina (um jogo aberto) em parte da sessão;
#   * 8% está dentro do que essa carga explica.
#
# Pela própria disciplina deste portfólio — documentada em `docs/BENCH.md` do
# p01 e na seção do NIF deste README — comparar A em bloco com B em bloco
# atribui a B qualquer deriva que ocorra no meio. Já produziu conclusões
# opostas em execuções seguidas aqui.
#
# Este script mede o mesmo par **alternando as plataformas a cada repetição**,
# reporta dispersão, e **recusa-se a concluir** se a margem não superar o
# ruído.
#
# ## O que está sendo comparado
#
# Os dois são "uma fila, um guardião, escritas serializadas":
#
#   * **Clojure `agent`** — `send` enfileira e volta; `await` espera o
#     esvaziamento (sem o `await`, mediria enfileiramento, não trabalho);
#   * **Elixir `GenServer.call`** — ida e volta síncrona por incremento.
#
# Não é comparação perfeita: `send` é assíncrono e `call` é síncrono. A versão
# assíncrona equivalente na BEAM é o `cast`, e ela **colapsa** por falta de
# contrapressão (17 mil ops/s, caixa com 811 mil mensagens) — o que já está
# medido em `bench/contencao.exs`. O `call` é o que alguém usaria de verdade, e
# por isso é ele que entra aqui. Esta ressalva vale para qualquer leitura do
# resultado.

set -uo pipefail

cd "$(dirname "$0")/.."

REPS="${REPS:-7}"
WORKERS="${WORKERS:-8}"
POR_WORKER="${POR_WORKER:-200000}"
ESPERADO=$((WORKERS * POR_WORKER))

CLJ_DIR="clojure/contencao"
EX_DIR="elixir/mesh"

echo
echo "=============================================================="
echo "  Fila + guardião: Clojure agent × Elixir GenServer"
echo "=============================================================="
echo
echo "workers    : $WORKERS, cada um com $POR_WORKER incrementos"
echo "esperado   : $ESPERADO"
echo "reps       : $REPS, ALTERNADAS entre as plataformas"
echo "estatística: mínimo (o máximo varia com qualquer coisa que a máquina faça)"
echo

command -v clojure >/dev/null || { echo "clojure não encontrado"; exit 1; }
command -v mix >/dev/null || { echo "mix não encontrado"; exit 1; }

# Aquecimento de cada lado, fora da medição: a primeira execução paga JIT da
# JVM, carga de classes, e compilação do .exs pelo mix.
echo "aquecendo as duas plataformas..."
( cd "$CLJ_DIR" && clojure agent_so.clj 2 10000 ) >/dev/null 2>&1
( cd "$EX_DIR" && mix run bench/genserver_so.exs 2 10000 ) >/dev/null 2>&1
echo

agent_amostras=()
gs_amostras=()

# Extrai o ops/s da linha única que cada programa imprime, e FALHA ALTO se a
# linha não vier no formato esperado -- em vez de virar 0 e inventar um
# resultado. Sétima encarnação da mesma lição deste portfólio.
extrai() { # $1 = saída, $2 = prefixo esperado, $3 = rótulo
  local linha
  linha=$(echo "$1" | grep -E "^$2 " | tail -1)

  if [ -z "$linha" ]; then
    echo "FALHA: $3 não imprimiu a linha '$2 <ops_s> <ms> <final>'" >&2
    echo "saída recebida:" >&2
    echo "$1" | tail -5 >&2
    exit 1
  fi

  local ops final
  ops=$(echo "$linha" | awk '{print $2}')
  final=$(echo "$linha" | awk '{print $4}')

  # O número só vale se o contador fechou. Vazão de resposta errada não é
  # vazão.
  if [ "$final" != "$ESPERADO" ]; then
    echo "FALHA: $3 contou $final, esperado $ESPERADO" >&2
    exit 1
  fi

  echo "$ops"
}

printf '%-5s %14s %14s\n' "rep" "agent" "genserver"
printf '%s\n' "----------------------------------"

for i in $(seq 1 "$REPS"); do
  # A ORDEM ALTERNA entre as repetições: nas pares começa pelo GenServer. Sem
  # isso, o primeiro a rodar em cada volta pegaria sempre o mesmo estado
  # térmico e de cache.
  if [ $((i % 2)) -eq 1 ]; then
    saida_a=$( cd "$CLJ_DIR" && clojure agent_so.clj "$WORKERS" "$POR_WORKER" 2>&1 )
    a=$(extrai "$saida_a" agent "Clojure agent")
    saida_g=$( cd "$EX_DIR" && mix run bench/genserver_so.exs "$WORKERS" "$POR_WORKER" 2>&1 )
    g=$(extrai "$saida_g" genserver "Elixir GenServer")
  else
    saida_g=$( cd "$EX_DIR" && mix run bench/genserver_so.exs "$WORKERS" "$POR_WORKER" 2>&1 )
    g=$(extrai "$saida_g" genserver "Elixir GenServer")
    saida_a=$( cd "$CLJ_DIR" && clojure agent_so.clj "$WORKERS" "$POR_WORKER" 2>&1 )
    a=$(extrai "$saida_a" agent "Clojure agent")
  fi

  agent_amostras+=("$a")
  gs_amostras+=("$g")

  printf '%-5s %14s %14s\n' "$i" "$a" "$g"
done

# ------------------------------------------------------------------ análise
estatistica() { # $@ = amostras -> "melhor pior disp"
  local melhor=0 pior=999999999999
  for v in "$@"; do
    # melhor = MAIOR ops/s; pior = menor.
    [ "$v" -gt "$melhor" ] && melhor=$v
    [ "$v" -lt "$pior" ] && pior=$v
  done
  local disp
  disp=$(awk -v m="$melhor" -v p="$pior" 'BEGIN { printf "%.1f", (m - p) / p * 100 }')
  echo "$melhor $pior $disp"
}

read -r a_melhor a_pior a_disp <<<"$(estatistica "${agent_amostras[@]}")"
read -r g_melhor g_pior g_disp <<<"$(estatistica "${gs_amostras[@]}")"

razao=$(awk -v a="$a_melhor" -v g="$g_melhor" 'BEGIN { printf "%.3f", a / g }')
margem=$(awk -v r="$razao" 'BEGIN { printf "%.1f", (r > 1 ? r - 1 : 1 - r) * 100 }')
pior_disp=$(awk -v x="$a_disp" -v y="$g_disp" 'BEGIN { print (x > y ? x : y) }')

echo
echo "=== Resultado ==="
echo
printf '  Clojure agent      : %s ops/s  (dispersão %s%%)\n' "$a_melhor" "$a_disp"
printf '  Elixir GenServer   : %s ops/s  (dispersão %s%%)\n' "$g_melhor" "$g_disp"
printf '  razão agent/gs     : %sx  (margem %s%%)\n' "$razao" "$margem"
printf '  pior dispersão     : %s%%\n' "$pior_disp"
echo

# A regra: a margem tem de superar a dispersão para a diferença significar
# algo. Caso contrário o resultado é "não determinado", que é uma resposta.
veredito=$(awk -v m="$margem" -v d="$pior_disp" 'BEGIN { print (m > d ? "decide" : "ruido") }')

if [ "$veredito" = "ruido" ]; then
  cat <<TXT
  **Não determinado.** A margem de ${margem}% não supera a dispersão de
  ${pior_disp}%, então a diferença entre as duas plataformas não é
  distinguível do ruído desta máquina.

  Isto CONFIRMA a afirmação original em substância -- "o modelo custa
  aproximadamente o mesmo" -- mas pelo motivo certo: não porque 8% seja
  pequeno, e sim porque a diferença não é mensurável aqui. A conclusão correta
  é "indistinguível", não "empata em 8%".
TXT
else
  vencedor=$(awk -v r="$razao" 'BEGIN { print (r > 1 ? "Clojure agent" : "Elixir GenServer") }')
  cat <<TXT
  **$vencedor é mais rápido**, por ${margem}%, acima da dispersão de
  ${pior_disp}%.

  A afirmação original do README -- "os dois modelos custam o mesmo" -- precisa
  ser corrigida com este número.
TXT
fi

cat <<'TXT'

  Ressalva que vale em qualquer leitura: `send`+`await` do agent é assíncrono
  com barreira, e `GenServer.call` é síncrono por operação. A versão
  assíncrona da BEAM é o `cast`, e ela COLAPSA por falta de contrapressão --
  17 mil ops/s, com 811 mil mensagens na caixa. Está medido em
  bench/contencao.exs.
TXT
