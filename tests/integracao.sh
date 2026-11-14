#!/usr/bin/env bash
# integracao.sh — o teste que atravessa as duas linguagens.
#
#   bash tests/integracao.sh
#
# Sobe o núcleo em Elixir, sobe o gateway em Go ligado à ponte, abre conexões
# WebSocket de verdade com o gerador de carga e verifica que **o núcleo as vê**.
#
# É o teste que faltava: até ele existir, o gateway e o núcleo eram dois
# resultados independentes, e o README dizia isso. Testes de unidade dos dois
# lados passariam mesmo com o protocolo divergindo — o enquadramento só é
# exercitado de verdade quando os bytes atravessam.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
RAIZ="$HERE/.."
PORTA_WS=${PORTA_WS:-8111}
PORTA_PONTE=${PORTA_PONTE:-4141}
N=${N:-500}

pass=0
fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

limpa() {
    [ -n "${GW_PID:-}" ] && kill "$GW_PID" 2>/dev/null
    [ -n "${CORE_PID:-}" ] && kill "$CORE_PID" 2>/dev/null
    wait 2>/dev/null
    rm -f /tmp/core.log /tmp/gw-int.log /tmp/lg-int.log
}
trap limpa EXIT

echo
echo "=== Integração: gateway em Go <-> núcleo em Elixir ==="
echo

# ------------------------------------------------------------------ build
( cd "$RAIZ/go" && go build -o /tmp/gw-int ./cmd/gateway && go build -o /tmp/lg-int ./cmd/loadgen ) \
    || { bad "build do Go"; exit 1; }
ok "build do Go"

# ------------------------------------------------------------------ núcleo
# A porta da ponte entra por variável de ambiente, lida pelo config em runtime.
( cd "$RAIZ/elixir/mesh" && MESH_BRIDGE_PORT=$PORTA_PONTE MESH_REPORT_MS=500 mix run --no-halt ) \
    >/tmp/core.log 2>&1 &
CORE_PID=$!

for _ in $(seq 1 60); do
    grep -q "escutando na porta $PORTA_PONTE" /tmp/core.log 2>/dev/null && break
    sleep 0.5
done

if grep -q "escutando na porta $PORTA_PONTE" /tmp/core.log 2>/dev/null; then
    ok "núcleo em Elixir escutando a ponte em $PORTA_PONTE"
else
    bad "o núcleo não subiu a ponte"
    sed 's/^/        | /' /tmp/core.log | tail -10
    exit 1
fi

# ----------------------------------------------------------------- gateway
/tmp/gw-int -addr "127.0.0.1:$PORTA_WS" -core "127.0.0.1:$PORTA_PONTE" -quiet \
    >/tmp/gw-int.log 2>&1 &
GW_PID=$!
sleep 1.2

if ! kill -0 "$GW_PID" 2>/dev/null; then
    bad "o gateway não subiu"
    sed 's/^/        | /' /tmp/gw-int.log | tail -10
    exit 1
fi

if grep -q "ponte com o nucleo" /tmp/gw-int.log; then
    ok "gateway conectado à ponte"
else
    bad "o gateway subiu mas não reportou a ponte"
fi

nucleo_ligado=$(curl -fsS "http://127.0.0.1:$PORTA_WS/stats" | grep -o '"nucleo_ligado":[a-z]*' | cut -d: -f2)
if [ "$nucleo_ligado" = "true" ]; then
    ok "/stats confirma nucleo_ligado=true"
else
    bad "/stats diz nucleo_ligado=$nucleo_ligado"
fi

# -------------------------------------------------------------------- carga
/tmp/lg-int -addr "127.0.0.1:$PORTA_WS" -n "$N" -conc 64 -hold 8s >/tmp/lg-int.log 2>&1 &
LG_PID=$!
sleep 4

no_gateway=$(curl -fsS "http://127.0.0.1:$PORTA_WS/stats" | grep -o '"conexoes":[0-9]*' | cut -d: -f2)

# O núcleo é consultado pelo próprio nó em execução, via RPC de um nó efêmero?
# Não: mais simples e menos frágil é o núcleo imprimir a contagem num laço, e o
# teste ler do log. Evita exigir nó distribuído e cookie só para um assert.
no_nucleo=$(grep -o 'conexoes_nucleo=[0-9]*' /tmp/core.log | tail -1 | cut -d= -f2)

printf '  conexões no gateway : %s\n' "${no_gateway:-?}"
printf '  conexões no núcleo  : %s\n' "${no_nucleo:-?}"

if [ "${no_gateway:-0}" -ge $((N - 5)) ]; then
    ok "o gateway aceitou $no_gateway de $N WebSockets reais"
else
    bad "o gateway aceitou só ${no_gateway:-0} de $N"
fi

if [ -n "${no_nucleo:-}" ] && [ "$no_nucleo" -ge $((N - 5)) ]; then
    ok "o NÚCLEO vê $no_nucleo conexões: a ponte funciona de ponta a ponta"
else
    bad "o núcleo vê ${no_nucleo:-nada}, esperado ~$N"
    sed 's/^/        | /' /tmp/core.log | tail -8
fi

# ------------------------------------------------- desconexão propaga de volta
kill "$LG_PID" 2>/dev/null
wait "$LG_PID" 2>/dev/null
sleep 3

depois=$(grep -o 'conexoes_nucleo=[0-9]*' /tmp/core.log | tail -1 | cut -d= -f2)
printf '  após fechar a carga : %s no núcleo\n' "${depois:-?}"

if [ "${depois:-999}" -le 5 ]; then
    ok "fechar os WebSockets limpou as conexões no núcleo"
else
    bad "sobraram ${depois} conexões órfãs no núcleo"
fi

echo
echo "$pass passaram, $fail falharam"
[ "$fail" -eq 0 ]
