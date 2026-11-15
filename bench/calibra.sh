#!/usr/bin/env bash
#
# calibra.sh — a máquina está ociosa o suficiente para a medição valer?
#
#   bash bench/calibra.sh            # verifica contra a linha de base
#   bash bench/calibra.sh --gravar   # grava a linha de base (máquina OCIOSA)
#
# Usado por: bench/fila_cruzada.sh, e por qualquer medição de tempo deste
# repositório.
#
# ## Por que isto existe
#
# Este projeto roda em WSL2, e durante o desenvolvimento um jogo e um vídeo
# ficaram abertos no Windows. Isso contaminou medições que já tinham sido
# publicadas, e uma delas precisou de correção pública (ver "Correção" na seção
# do Clojure do README).
#
# A pergunta óbvia foi: por que não checar `/proc/loadavg` antes de medir?
#
# **Porque não funciona aqui, e isso foi medido.** O WSL2 é uma VM: processos
# do Windows não aparecem no `/proc` do Linux. Com 4 núcleos do Windows
# ocupados de propósito, 7 repetições dos dois lados:
#
#   | condição            | mínimo do laço fixo | loadavg do WSL2 |
#   |---------------------|---------------------|-----------------|
#   | ociosa              | 183 ms              | 0,24            |
#   | 4 núcleos ocupados  | **319 ms (+74%)**   | 0,82            |
#
# O `loadavg` **move**, mas é média de 1 minuto, decai devagar e inclui a
# própria medição: logo depois de a carga parar ele ainda marcava 0,64, com a
# máquina já livre. Não serve de porteiro.
#
# O laço fixo inflou **74%** e o detector reprovou com código de saída 1 — é o
# teste que validou este script.
#
# ## O método
#
# Um laço de inteiros puro, sem I/O e sem alocação, em `awk` — POSIX, presente
# em qualquer máquina, e sem etapa de build que introduza variação própria.
#
# Mínimo de N. A linha de base fica em `bench/.calibracao`, gravada com a
# máquina ociosa, e o script compara contra ela.
#
# **Importante:** a linha de base é da máquina, não do repositório. Ela está no
# `.gitignore`, porque o número de outra máquina seria pior que número nenhum —
# daria falso alarme ou, pior, falso OK.
#
# ## O que ele NÃO resolve
#
# Carga que aparece **durante** a medição e não antes. Por isso quem chama deve
# calibrar **antes e depois**: se as duas calibrações discordarem, as condições
# mudaram no meio e o resultado não vale.
#
# `fila_cruzada.sh` faz isso.

set -uo pipefail

cd "$(dirname "$0")"

BASE_ARQ=".calibracao"
REPS="${CAL_REPS:-7}"
ITERS="${CAL_ITERS:-3000000}"

# Tolerância: quanto o laço pode estar mais lento que a base antes de a medição
# ser considerada contaminada. 12% é folgado o bastante para variação normal de
# frequência e apertado o bastante para pegar um vídeo tocando -- a carga
# medida no experimento acima inflou 43%.
TOLERANCIA="${CAL_TOLERANCIA:-12}"

# Laço fixo: soma de inteiros, nada mais. Determinístico, sem I/O, sem
# alocação, sem syscall no meio.
mede_uma() {
  local ini fim
  ini=$(date +%s%N)
  awk -v n="$ITERS" 'BEGIN { s = 0; for (i = 0; i < n; i++) s += i; print s }' >/dev/null
  fim=$(date +%s%N)
  echo $(((fim - ini) / 1000000))
}

melhor_de_n() {
  local melhor=999999999 v
  for _ in $(seq 1 "$REPS"); do
    v=$(mede_uma)
    [ "$v" -lt "$melhor" ] && melhor=$v
  done
  echo "$melhor"
}

# ------------------------------------------------- modo --esperar
#
# A calibração DEPOIS da medição tem um problema que a de antes não tem: ela
# mede, em parte, o calor que o próprio benchmark gerou. Num laptop, 14
# execuções pesadas seguidas reduzem a frequência, e a calibração final reprova
# por causa da medição, não por causa de carga externa.
#
# `--esperar` resolve distinguindo os dois casos: espera a máquina voltar à
# faixa, com um teto de tentativas. Se voltar, era o próprio benchmark
# aquecendo e o resultado vale. Se não voltar, há carga externa de verdade.
if [ "${1:-}" = "--esperar" ]; then
  max="${CAL_TENTATIVAS:-6}"

  if [ ! -f "$BASE_ARQ" ]; then
    echo "sem linha de base; rode: bash bench/calibra.sh --gravar" >&2
    exit 2
  fi

  base=$(cat "$BASE_ARQ")

  for tentativa in $(seq 1 "$max"); do
    agora=$(melhor_de_n)
    excesso=$(awk -v a="$agora" -v b="$base" 'BEGIN { printf "%.1f", (a - b) / b * 100 }')

    if awk -v e="$excesso" -v t="$TOLERANCIA" 'BEGIN { exit !(e <= t) }'; then
      printf 'calibração final: %s ms (base %s ms, %+.1f%%) — ok na tentativa %s
'         "$agora" "$base" "$excesso" "$tentativa"
      exit 0
    fi

    printf 'calibração final: %s ms (%+.1f%%) — fora da faixa, esfriando (%s/%s)
'       "$agora" "$excesso" "$tentativa" "$max"
    sleep 10
  done

  cat <<TXT
  A máquina NÃO voltou à faixa em $max tentativas (~$((max * 10))s de espera).

  Isso distingue dois casos, e aqui é o segundo:
    * voltou  -> era o próprio benchmark aquecendo a CPU; o resultado vale;
    * não voltou -> há carga externa de verdade.
TXT
  exit 1
fi

if [ "${1:-}" = "--gravar" ]; then
  echo "Gravando a linha de base. A máquina deve estar OCIOSA:"
  echo "  sem navegador tocando vídeo, sem jogo, sem build em outra janela."
  echo
  echo -n "medindo ($REPS repetições)... "
  base=$(melhor_de_n)
  echo "$base ms"
  echo "$base" >"$BASE_ARQ"
  echo
  echo "linha de base gravada em bench/$BASE_ARQ: $base ms"
  echo "(fora do git: o número é desta máquina)"
  exit 0
fi

if [ ! -f "$BASE_ARQ" ]; then
  cat <<TXT

  Não há linha de base de calibração.

  Com a máquina ociosa, rode:

      bash bench/calibra.sh --gravar

  Sem ela, qualquer medição de tempo deste repositório é um número sem
  contexto: não há como saber se a máquina estava livre.

TXT
  exit 2
fi

base=$(cat "$BASE_ARQ")
agora=$(melhor_de_n)

excesso=$(awk -v a="$agora" -v b="$base" 'BEGIN { printf "%.1f", (a - b) / b * 100 }')

printf 'calibração: %s ms (base %s ms, %+.1f%%)\n' "$agora" "$base" "$excesso"

# Mais RÁPIDO que a base também é informação: pode ser que a base tenha sido
# gravada com a máquina suja. Avisa, mas não reprova.
mais_rapido=$(awk -v e="$excesso" 'BEGIN { print (e < -12 ? 1 : 0) }')
if [ "$mais_rapido" = "1" ]; then
  echo "  AVISO: ${excesso}% MAIS RÁPIDO que a base. A base pode ter sido"
  echo "         gravada com a máquina ocupada; considere regravá-la."
  exit 0
fi

contaminada=$(awk -v e="$excesso" -v t="$TOLERANCIA" 'BEGIN { print (e > t ? 1 : 0) }')

if [ "$contaminada" = "1" ]; then
  cat <<TXT
  MÁQUINA OCUPADA: ${excesso}% acima da base (tolerância ${TOLERANCIA}%).

  Em WSL2 a causa costuma estar do lado do Windows, onde o /proc do Linux não
  vê: vídeo tocando, jogo, build, indexação. Feche e rode de novo.

  Medir assim produz número publicável e errado -- que é o pior tipo.
TXT
  exit 1
fi

echo "  máquina ociosa o suficiente (tolerância ${TOLERANCIA}%)"
exit 0
