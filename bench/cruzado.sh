#!/usr/bin/env bash
#
# cruzado.sh — harness genérico para comparar DUAS plataformas, alternando.
#
#   bash bench/cruzado.sh <rótulo_a> <dir_a> <cmd_a> <prefixo_a> \
#                         <rótulo_b> <dir_b> <cmd_b> <prefixo_b>
#
# Normalmente invocado pelos dois wrappers:
#
#   bash bench/fila_cruzada.sh      # Clojure agent     × Elixir GenServer
#   bash bench/contador_cruzado.sh  # JVM AtomicLong    × BEAM :counters
#
# Cada programa medido imprime UMA linha: `<prefixo> <ops_s> <ms> <final>`.
#
# ## Por que um harness só
#
# A primeira versão disto era um script duplicado por `sed`, e os comentários
# da cópia descreviam a medição do original — documentação mentindo sobre o que
# o código faz. Um harness parametrizado não tem esse problema.
#
# ## As cinco regras que este harness aplica
#
# Elas existem porque **duas medições já publicadas neste repositório foram
# corrigidas** por não as seguirem:
#
# 1. **Alterna A e B a cada repetição**, e inverte a ordem nas repetições
#    pares. Medir A em bloco e B em bloco atribui a B qualquer deriva que
#    ocorra no meio.
#
# 2. **Aquece fora da medição.** A primeira execução paga JIT da JVM, carga de
#    classes e compilação do `.exs` pelo mix.
#
# 3. **Calibra a máquina antes E depois** (`bench/calibra.sh`). Em WSL2,
#    `/proc/loadavg` não vê carga do lado do Windows; o laço fixo da calibração
#    vê. Calibrar só antes não pega um vídeo aberto no meio da medição.
#
# 4. **Falha alto se o contador final não fechar.** Vazão de resposta errada
#    não é vazão.
#
# 5. **Decide pela SOBREPOSIÇÃO das faixas**, não pela margem dos mínimos.
#
# ## Sobre a regra 5, que foi a mais difícil de acertar
#
# A primeira versão comparava a margem entre os mínimos contra a dispersão, e
# declarava "não determinado" quando a margem perdia. Isso descartou um
# resultado que era claro:
#
#     AtomicLong : 12,4 M a 29,9 M ops/s   (dispersão 141%)
#     :counters   : 48,2 M a 114,6 M ops/s (dispersão 138%)
#
# A dispersão é enorme nos dois, e a margem entre os mínimos não a supera. Mas
# **as faixas não se tocam**: a PIOR amostra do `:counters` ainda é 1,6x melhor
# que a MELHOR do `AtomicLong`. Com sete amostras alternadas, isso é evidência
# forte, não ruído.
#
# Então a regra passou a ser, em ordem:
#
#   * faixas **disjuntas** -> decidido, e o fator reportado é o
#     **conservador** (pior do vencedor ÷ melhor do perdedor);
#   * faixas se sobrepõem, mas a margem supera a dispersão -> decidido;
#   * caso contrário -> **não determinado**.
#
# O par `agent` × `GenServer` cai no terceiro caso (faixas 374–591 mil e
# 212–473 mil **se sobrepõem**), e continua não determinado. A regra nova
# decide um e mantém o outro — que é o comportamento certo.

set -uo pipefail

cd "$(dirname "$0")/.."

if [ $# -ne 8 ]; then
  echo "uso: $0 <rot_a> <dir_a> <cmd_a> <pref_a> <rot_b> <dir_b> <cmd_b> <pref_b>" >&2
  exit 64
fi

ROT_A="$1"; DIR_A="$2"; CMD_A="$3"; PREF_A="$4"
ROT_B="$5"; DIR_B="$6"; CMD_B="$7"; PREF_B="$8"

REPS="${REPS:-7}"
WORKERS="${WORKERS:-8}"
POR_WORKER="${POR_WORKER:-200000}"
ESPERADO=$((WORKERS * POR_WORKER))

echo
echo "=============================================================="
printf '  %s × %s\n' "$ROT_A" "$ROT_B"
echo "=============================================================="
echo
echo "workers    : $WORKERS, cada um com $POR_WORKER incrementos"
echo "esperado   : $ESPERADO"
echo "reps       : $REPS, ALTERNADAS, com ordem invertida nas pares"
echo "estatística: melhor e pior de cada lado, com teste de sobreposição"
echo

# ------------------------------------------------------ regra 3: calibração
if ! bash bench/calibra.sh; then
  echo
  echo "Medição abortada: a máquina não está ociosa."
  echo "Para ignorar (NÃO publique o resultado): CAL_IGNORA=1 bash $0 ..."
  [ "${CAL_IGNORA:-}" = "1" ] || exit 1
  echo "CAL_IGNORA=1: seguindo com a máquina ocupada."
fi
echo

# -------------------------------------------------------- regra 2: aquecimento
echo "aquecendo as duas plataformas..."
( cd "$DIR_A" && eval "$CMD_A 2 10000" ) >/dev/null 2>&1
( cd "$DIR_B" && eval "$CMD_B 2 10000" ) >/dev/null 2>&1
echo

# ---------------------------------------------------- regra 4: falha alto
extrai() { # $1 = saída, $2 = prefixo, $3 = rótulo
  local linha ops final
  linha=$(echo "$1" | grep -E "^$2 " | tail -1)

  if [ -z "$linha" ]; then
    echo "FALHA: $3 não imprimiu a linha '$2 <ops_s> <ms> <final>'" >&2
    echo "$1" | tail -5 >&2
    exit 1
  fi

  ops=$(echo "$linha" | awk '{print $2}')
  final=$(echo "$linha" | awk '{print $4}')

  if [ "$final" != "$ESPERADO" ]; then
    echo "FALHA: $3 contou $final, esperado $ESPERADO" >&2
    exit 1
  fi

  echo "$ops"
}

roda_a() {
  local saida
  saida=$( cd "$DIR_A" && eval "$CMD_A $WORKERS $POR_WORKER" 2>&1 )
  extrai "$saida" "$PREF_A" "$ROT_A"
}

roda_b() {
  local saida
  saida=$( cd "$DIR_B" && eval "$CMD_B $WORKERS $POR_WORKER" 2>&1 )
  extrai "$saida" "$PREF_B" "$ROT_B"
}

# ------------------------------------------------------- regra 1: alternância
amostras_a=()
amostras_b=()

printf '%-5s %16s %16s\n' "rep" "$PREF_A" "$PREF_B"
printf '%s\n' "---------------------------------------"

for i in $(seq 1 "$REPS"); do
  if [ $((i % 2)) -eq 1 ]; then
    a=$(roda_a) || exit 1
    b=$(roda_b) || exit 1
  else
    b=$(roda_b) || exit 1
    a=$(roda_a) || exit 1
  fi

  amostras_a+=("$a")
  amostras_b+=("$b")
  printf '%-5s %16s %16s\n' "$i" "$a" "$b"
done

# --------------------------------------- regra 3 (de novo): calibração final
echo
CONTAMINADO=0
if ! bash bench/calibra.sh; then
  echo
  echo "AS CONDIÇÕES MUDARAM DURANTE A MEDIÇÃO."
  echo "A calibração passou antes e reprovou depois: algo começou a rodar no"
  echo "meio, e os números acima não são comparáveis entre si."
  CONTAMINADO=1
fi

# ------------------------------------------------------------------ análise
faixa() { # $@ = amostras -> "melhor pior disp"
  local melhor=0 pior=999999999999
  for v in "$@"; do
    [ "$v" -gt "$melhor" ] && melhor=$v
    [ "$v" -lt "$pior" ] && pior=$v
  done
  echo "$melhor $pior $(awk -v m="$melhor" -v p="$pior" \
    'BEGIN { printf "%.1f", (m - p) / p * 100 }')"
}

read -r a_melhor a_pior a_disp <<<"$(faixa "${amostras_a[@]}")"
read -r b_melhor b_pior b_disp <<<"$(faixa "${amostras_b[@]}")"

razao=$(awk -v a="$a_melhor" -v b="$b_melhor" 'BEGIN { printf "%.3f", a / b }')
margem=$(awk -v r="$razao" 'BEGIN { printf "%.1f", (r > 1 ? r - 1 : 1 - r) * 100 }')
pior_disp=$(awk -v x="$a_disp" -v y="$b_disp" 'BEGIN { print (x > y ? x : y) }')

echo
echo "=== Resultado ==="
echo
printf '  %-22s %14s ops/s   (faixa %s–%s, disp %s%%)\n' \
  "$ROT_A" "$a_melhor" "$a_pior" "$a_melhor" "$a_disp"
printf '  %-22s %14s ops/s   (faixa %s–%s, disp %s%%)\n' \
  "$ROT_B" "$b_melhor" "$b_pior" "$b_melhor" "$b_disp"
echo
printf '  razão dos melhores   : %sx   (margem %s%%)\n' "$razao" "$margem"
printf '  pior dispersão       : %s%%\n' "$pior_disp"

# ----------------------------------------------- regra 5: sobreposição
# Faixas disjuntas: o pior de um lado ainda supera o melhor do outro.
a_ganha_sempre=$(awk -v ap="$a_pior" -v bm="$b_melhor" 'BEGIN { print (ap > bm ? 1 : 0) }')
b_ganha_sempre=$(awk -v bp="$b_pior" -v am="$a_melhor" 'BEGIN { print (bp > am ? 1 : 0) }')

echo

if [ "$CONTAMINADO" = "1" ]; then
  echo "  **Não determinado** — as condições mudaram durante a medição."
  echo "  Qualquer veredito aqui seria sobre a carga da máquina, não sobre as"
  echo "  plataformas."
  exit 0
fi

if [ "$a_ganha_sempre" = "1" ]; then
  fator=$(awk -v ap="$a_pior" -v bm="$b_melhor" 'BEGIN { printf "%.2f", ap / bm }')
  cat <<TXT
  **$ROT_A é mais rápido, e as faixas não se tocam.**

  A PIOR amostra dele ($a_pior) supera a MELHOR do outro ($b_melhor), em
  $REPS repetições alternadas. A dispersão é alta nos dois lados, mas isso
  não importa quando as faixas são disjuntas.

  Fator conservador (pior do vencedor ÷ melhor do perdedor): **${fator}x**
  Fator pelos melhores: ${razao}x
TXT
elif [ "$b_ganha_sempre" = "1" ]; then
  fator=$(awk -v bp="$b_pior" -v am="$a_melhor" 'BEGIN { printf "%.2f", bp / am }')
  cat <<TXT
  **$ROT_B é mais rápido, e as faixas não se tocam.**

  A PIOR amostra dele ($b_pior) supera a MELHOR do outro ($a_melhor), em
  $REPS repetições alternadas. A dispersão é alta nos dois lados, mas isso
  não importa quando as faixas são disjuntas.

  Fator conservador (pior do vencedor ÷ melhor do perdedor): **${fator}x**
  Fator pelos melhores: $(awk -v r="$razao" 'BEGIN { printf "%.2f", 1 / r }')x
TXT
else
  decide=$(awk -v m="$margem" -v d="$pior_disp" 'BEGIN { print (m > d ? 1 : 0) }')
  if [ "$decide" = "1" ]; then
    venc=$(awk -v r="$razao" -v a="$ROT_A" -v b="$ROT_B" \
      'BEGIN { print (r > 1 ? a : b) }')
    cat <<TXT
  **$venc é mais rápido**, por ${margem}%, acima da dispersão de ${pior_disp}%.

  As faixas se sobrepõem, então este veredito é mais fraco que o de faixas
  disjuntas — vale como "provavelmente", não como "certamente".
TXT
  else
    cat <<TXT
  **Não determinado.**

  As faixas se sobrepõem E a margem de ${margem}% não supera a dispersão de
  ${pior_disp}%. A diferença não é distinguível do ruído desta máquina.

  Isto é uma resposta, não uma falha. Este portfólio já a deu antes: no
  p01-metal-vm, a comparação entre switch e computed goto foi publicada três
  vezes e corrigida duas antes de terminar em "não determinado".
TXT
  fi
fi
