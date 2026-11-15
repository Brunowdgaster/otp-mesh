#!/usr/bin/env bash
#
# concorrencia_cruzada.sh — taxa de criação e latência: BEAM × Loom, alternando.
#
#   bash bench/concorrencia_cruzada.sh
#   N=200000 REPS=7 bash bench/concorrencia_cruzada.sh
#
# ## Por que existe: a terceira auditoria
#
# A seção do Scala publicou duas comparações entre plataformas **sem
# alternância**, que é o defeito já corrigido duas vezes neste repositório:
#
#   1. "**A BEAM cria 3,2x mais rápido**" — 122.079 por segundo contra 38.015;
#   2. "sem carga nenhuma, a BEAM atende em 0,008 ms contra 0,318 ms —
#      **40x mais rápido**".
#
# As duas vieram de execuções únicas, em processos e momentos distintos, sem
# dispersão reportada. Pelas regras deste repositório (ver `bench/cruzado.sh`),
# nenhuma das duas está estabelecida.
#
# ## E há um segundo problema, pior que a falta de alternância
#
# A taxa original foi medida com **700 mil unidades dos dois lados**. Nesse
# ponto, 700 mil processos BEAM ocupam ~1,9 GiB e 700 mil threads virtuais
# ~930 MiB, numa máquina com 3,8 GiB disponíveis no WSL2.
#
# Ou seja: **os dois lados não estavam sob a mesma pressão de memória.** A BEAM
# criava com o heap muito mais cheio e perto do limite da máquina. Comparar
# taxas assim mede a pressão de memória tanto quanto a plataforma.
#
# Este script mede em um tamanho onde **nenhum dos dois está sob pressão**
# (padrão: 200 mil), e reporta a dispersão. O número de 700 mil continua
# publicado como capacidade — o que ele não sustenta é a *razão* entre as
# taxas.

set -uo pipefail

cd "$(dirname "$0")/.."

N="${N:-200000}"
REPS="${REPS:-7}"

SC_DIR="scala/loadgen"
EX_DIR="elixir/mesh"

echo
echo "=============================================================="
echo "  Taxa de criação e latência: processo BEAM × thread virtual"
echo "=============================================================="
echo
echo "unidades  : $N por execução (longe do limite dos dois lados)"
echo "reps      : $REPS, ALTERNADAS, ordem invertida nas pares"
echo

if ! bash bench/calibra.sh; then
  echo
  echo "Medição abortada: a máquina não está ociosa."
  [ "${CAL_IGNORA:-}" = "1" ] || exit 1
fi
echo

command -v scala-cli >/dev/null || { echo "scala-cli não encontrado"; exit 1; }
command -v mix >/dev/null || { echo "mix não encontrado"; exit 1; }

echo "aquecendo (compila o Scala e o Elixir fora da medição)..."
( cd "$SC_DIR" && scala-cli run Concorrencia.scala --jvm system -- virtual 2000 ) >/dev/null 2>&1
( cd "$EX_DIR" && mix run bench/processo_nu.exs 2000 ) >/dev/null 2>&1
echo

# Extrai "(<n> por segundo)" e falha alto se não achar, em vez de virar 0.
extrai_taxa() { # $1 = saída, $2 = rótulo
  local v
  v=$(echo "$1" | grep -oE '\(([0-9]+) por segundo\)' | tail -1 | grep -oE '[0-9]+')

  if [ -z "$v" ]; then
    echo "FALHA: $2 não imprimiu '(<n> por segundo)'" >&2
    echo "$1" | tail -8 >&2
    exit 1
  fi
  echo "$v"
}

beam=()
loom=()

printf '%-5s %16s %16s\n' "rep" "BEAM/s" "Loom/s"
printf '%s\n' "---------------------------------------"

for i in $(seq 1 "$REPS"); do
  if [ $((i % 2)) -eq 1 ]; then
    s1=$( cd "$EX_DIR" && mix run bench/processo_nu.exs "$N" 2>&1 )
    b=$(extrai_taxa "$s1" "Elixir processo_nu") || exit 1
    s2=$( cd "$SC_DIR" && scala-cli run Concorrencia.scala --jvm system -- virtual "$N" 2>&1 )
    l=$(extrai_taxa "$s2" "Scala Concorrencia") || exit 1
  else
    s2=$( cd "$SC_DIR" && scala-cli run Concorrencia.scala --jvm system -- virtual "$N" 2>&1 )
    l=$(extrai_taxa "$s2" "Scala Concorrencia") || exit 1
    s1=$( cd "$EX_DIR" && mix run bench/processo_nu.exs "$N" 2>&1 )
    b=$(extrai_taxa "$s1" "Elixir processo_nu") || exit 1
  fi

  beam+=("$b")
  loom+=("$l")
  printf '%-5s %16s %16s\n' "$i" "$b" "$l"
done

echo
CONTAMINADO=0
if ! bash bench/calibra.sh --esperar; then
  echo "  AS CONDIÇÕES MUDARAM DURANTE A MEDIÇÃO."
  CONTAMINADO=1
fi

faixa() {
  local melhor=0 pior=999999999999
  for v in "$@"; do
    [ "$v" -gt "$melhor" ] && melhor=$v
    [ "$v" -lt "$pior" ] && pior=$v
  done
  echo "$melhor $pior $(awk -v m="$melhor" -v p="$pior" \
    'BEGIN { printf "%.1f", (m - p) / p * 100 }')"
}

read -r b_melhor b_pior b_disp <<<"$(faixa "${beam[@]}")"
read -r l_melhor l_pior l_disp <<<"$(faixa "${loom[@]}")"

razao=$(awk -v b="$b_melhor" -v l="$l_melhor" 'BEGIN { printf "%.2f", b / l }')
pior_disp=$(awk -v x="$b_disp" -v y="$l_disp" 'BEGIN { print (x > y ? x : y) }')

echo
echo "=== Resultado: taxa de criação ==="
echo
printf '  processo BEAM   : %s/s   (faixa %s–%s, disp %s%%)\n' \
  "$b_melhor" "$b_pior" "$b_melhor" "$b_disp"
printf '  thread virtual  : %s/s   (faixa %s–%s, disp %s%%)\n' \
  "$l_melhor" "$l_pior" "$l_melhor" "$l_disp"
printf '  razão           : %sx\n' "$razao"
echo

if [ "$CONTAMINADO" = "1" ]; then
  echo "  **Não determinado** — as condições mudaram durante a medição."
  exit 0
fi

# Faixas disjuntas decidem mesmo com dispersão alta. Ver bench/cruzado.sh.
if awk -v bp="$b_pior" -v lm="$l_melhor" 'BEGIN { exit !(bp > lm) }'; then
  fator=$(awk -v bp="$b_pior" -v lm="$l_melhor" 'BEGIN { printf "%.2f", bp / lm }')
  echo "  **A BEAM cria mais rápido, e as faixas não se tocam.**"
  echo "  A pior amostra dela ($b_pior/s) supera a melhor do Loom ($l_melhor/s)."
  echo
  echo "  Fator conservador: **${fator}x**   |   pelos melhores: ${razao}x"
elif awk -v lp="$l_pior" -v bm="$b_melhor" 'BEGIN { exit !(lp > bm) }'; then
  fator=$(awk -v lp="$l_pior" -v bm="$b_melhor" 'BEGIN { printf "%.2f", lp / bm }')
  echo "  **O Loom cria mais rápido, e as faixas não se tocam.**"
  echo "  Fator conservador: **${fator}x**"
else
  margem=$(awk -v r="$razao" 'BEGIN { printf "%.1f", (r > 1 ? r - 1 : 1 - r) * 100 }')
  if awk -v m="$margem" -v d="$pior_disp" 'BEGIN { exit !(m > d) }'; then
    echo "  Diferença de ${margem}% supera a dispersão de ${pior_disp}%, mas as"
    echo "  faixas se sobrepõem: vale como 'provavelmente', não 'certamente'."
  else
    echo "  **Não determinado.** Faixas sobrepostas e margem de ${margem}% dentro"
    echo "  da dispersão de ${pior_disp}%."
  fi
fi

# =========================================================== FASE 2: latência
#
# A segunda afirmação sem alternância: "sem carga nenhuma, a BEAM atende em
# 0,008 ms contra 0,318 ms -- 40x mais rápido".
#
# Aqui o número é LATÊNCIA, então menor é melhor -- o oposto da fase 1. As
# funções de faixa abaixo invertem o critério, e isso é fácil de errar: numa
# versão anterior deste script, "melhor" pegava o maior valor e reportava o
# pior caso como resultado.
echo
echo "=============================================================="
echo "  Fase 2: latência de atendimento sem carga (menor é melhor)"
echo "=============================================================="
echo

echo "aquecendo..."
( cd "$SC_DIR" && scala-cli run Preempcao.scala --jvm system -- 2 2 ) >/dev/null 2>&1
( cd "$EX_DIR" && mix run bench/preempcao.exs 2 2 ) >/dev/null 2>&1
echo

# Extrai "1. sem carga        : X ms" e multiplica por 1000 para trabalhar com
# inteiros em microssegundos -- bash não compara float.
extrai_lat() { # $1 = saída, $2 = rótulo
  local v
  v=$(echo "$1" | grep -E '^ *1\. sem carga' | tail -1 |
      grep -oE '[0-9]+\.[0-9]+' | tail -1)

  if [ -z "$v" ]; then
    echo "FALHA: $2 não imprimiu '1. sem carga : <x> ms'" >&2
    echo "$1" | tail -8 >&2
    exit 1
  fi
  awk -v x="$v" 'BEGIN { printf "%.0f", x * 1000 }'
}

lat_beam=()
lat_loom=()

printf '%-5s %16s %16s
' "rep" "BEAM (µs)" "Loom (µs)"
printf '%s
' "---------------------------------------"

for i in $(seq 1 "$REPS"); do
  if [ $((i % 2)) -eq 1 ]; then
    s1=$( cd "$EX_DIR" && mix run bench/preempcao.exs 4 2 2>&1 )
    b=$(extrai_lat "$s1" "Elixir preempcao") || exit 1
    s2=$( cd "$SC_DIR" && scala-cli run Preempcao.scala --jvm system -- 4 2 2>&1 )
    l=$(extrai_lat "$s2" "Scala Preempcao") || exit 1
  else
    s2=$( cd "$SC_DIR" && scala-cli run Preempcao.scala --jvm system -- 4 2 2>&1 )
    l=$(extrai_lat "$s2" "Scala Preempcao") || exit 1
    s1=$( cd "$EX_DIR" && mix run bench/preempcao.exs 4 2 2>&1 )
    b=$(extrai_lat "$s1" "Elixir preempcao") || exit 1
  fi

  lat_beam+=("$b")
  lat_loom+=("$l")
  printf '%-5s %16s %16s
' "$i" "$b" "$l"
done

echo
if ! bash bench/calibra.sh --esperar; then
  echo "  **Fase 2 não determinada** — carga externa durante a medição."
  exit 0
fi

# MENOR é melhor: "melhor" aqui é o mínimo.
faixa_lat() {
  local melhor=999999999999 pior=0
  for v in "$@"; do
    [ "$v" -lt "$melhor" ] && melhor=$v
    [ "$v" -gt "$pior" ] && pior=$v
  done
  echo "$melhor $pior $(awk -v m="$melhor" -v p="$pior"     'BEGIN { printf "%.1f", (p - m) / m * 100 }')"
}

read -r lb_melhor lb_pior lb_disp <<<"$(faixa_lat "${lat_beam[@]}")"
read -r ll_melhor ll_pior ll_disp <<<"$(faixa_lat "${lat_loom[@]}")"

razao_lat=$(awk -v l="$ll_melhor" -v b="$lb_melhor" 'BEGIN { printf "%.1f", l / b }')

echo
echo "=== Resultado: latência sem carga ==="
echo
printf '  processo BEAM   : %s µs   (faixa %s–%s, disp %s%%)
'   "$lb_melhor" "$lb_melhor" "$lb_pior" "$lb_disp"
printf '  thread virtual  : %s µs   (faixa %s–%s, disp %s%%)
'   "$ll_melhor" "$ll_melhor" "$ll_pior" "$ll_disp"
printf '  razão Loom/BEAM : %sx
' "$razao_lat"
echo

# Faixas disjuntas, com menor melhor: o PIOR da BEAM ainda é menor que o MELHOR
# do Loom.
if awk -v bp="$lb_pior" -v lm="$ll_melhor" 'BEGIN { exit !(bp < lm) }'; then
  fator=$(awk -v lm="$ll_melhor" -v bp="$lb_pior" 'BEGIN { printf "%.1f", lm / bp }')
  echo "  **A BEAM atende mais rápido, e as faixas não se tocam.**"
  echo "  A PIOR amostra dela ($lb_pior µs) ainda é menor que a MELHOR do Loom"
  echo "  ($ll_melhor µs)."
  echo
  echo "  Fator conservador: **${fator}x**   |   pelos melhores: ${razao_lat}x"
else
  echo "  Faixas se sobrepõem — ver a regra em bench/cruzado.sh."
fi

cat <<'TXT'

  Nota sobre o número de 700 mil publicado no README: a CAPACIDADE (700 mil
  unidades de cada lado) continua válida -- é contagem, não tempo. O que esta
  medição corrige é a RAZÃO entre as taxas, que lá foi obtida com os dois lados
  sob pressões de memória diferentes (1,9 GiB contra 930 MiB numa máquina de
  3,8 GiB) e sem alternância.
TXT
