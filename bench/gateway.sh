#!/usr/bin/env bash
# gateway.sh — quanto custa uma conexão WebSocket REAL, contra os 3,8 KB de um
# processo BEAM.
#
#   bash bench/gateway.sh
#
# ## Os limites do sistema fazem parte da medição
#
# Medir sockets em loopback esbarra em três tetos antes de esbarrar em memória,
# e ignorá-los produziria um número que parece capacidade e é limite de kernel:
#
#   1. descritores de arquivo (`ulimit -n`): 10.240 por padrão aqui;
#   2. portas efêmeras: o cliente gasta uma por conexão, e o intervalo padrão
#      32768-60999 dá ~28 mil -- o teto REAL desta medição em loopback;
#   3. backlog de accept (`somaxconn`, `tcp_max_syn_backlog`): uma rampa rápida
#      descarta SYN e o loadgen reporta falha de conexão.
#
# O script ajusta os três, **registra os valores antigos e os restaura**. São
# ajustes de kernel: não é educado deixá-los para trás.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
GO_DIR="$HERE/../go"
PORT=${PORT:-8099}
ADDR="127.0.0.1:$PORT"
DEGRAUS=${DEGRAUS:-"1000 5000 10000 25000"}
HOLD=${HOLD:-12}

# ---------------------------------------------------------------- limites
PORT_RANGE_ANTES=$(cat /proc/sys/net/ipv4/ip_local_port_range)
SOMAXCONN_ANTES=$(cat /proc/sys/net/core/somaxconn)
SYNBACKLOG_ANTES=$(cat /proc/sys/net/ipv4/tcp_max_syn_backlog)

restaura() {
    echo "$PORT_RANGE_ANTES" > /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null || true
    echo "$SOMAXCONN_ANTES" > /proc/sys/net/core/somaxconn 2>/dev/null || true
    echo "$SYNBACKLOG_ANTES" > /proc/sys/net/ipv4/tcp_max_syn_backlog 2>/dev/null || true
    [ -n "${GW_PID:-}" ] && kill "$GW_PID" 2>/dev/null
    wait 2>/dev/null
}
trap restaura EXIT

ulimit -n 200000 2>/dev/null || echo "AVISO: nao consegui elevar ulimit -n (teto: $(ulimit -Hn))"
echo "10000 65535" > /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null || true
echo 65535 > /proc/sys/net/core/somaxconn 2>/dev/null || true
echo 65535 > /proc/sys/net/ipv4/tcp_max_syn_backlog 2>/dev/null || true

TETO_PORTAS=$(awk '{print $2 - $1 + 1}' /proc/sys/net/ipv4/ip_local_port_range)

cat <<EOF

=== Custo de uma conexão WebSocket real ===

descritores (ulimit -n) : $(ulimit -Sn)
portas efêmeras         : $(cat /proc/sys/net/ipv4/ip_local_port_range) -> teto ~$TETO_PORTAS conexões
backlog de accept       : $(cat /proc/sys/net/core/somaxconn)
buffers por conexão     : 1 KiB de leitura + 1 KiB de escrita (ws.DefaultConfig)

Referência do núcleo em Elixir: 3.783 bytes por conexão, sem socket.

EOF

# ----------------------------------------------------------------- build
echo "compilando..."
( cd "$GO_DIR" && go build -o /tmp/gw ./cmd/gateway && go build -o /tmp/lg ./cmd/loadgen ) || exit 1

printf '%-10s %10s %12s %12s %12s %14s\n' \
    "conexões" "goroutines" "heap (MB)" "stack (MB)" "RSS (MB)" "bytes/conn"
printf '%s\n' "--------------------------------------------------------------------------"

falhou=0

for n in $DEGRAUS; do
    if [ "$n" -gt "$TETO_PORTAS" ]; then
        echo "  $n acima do teto de portas efêmeras ($TETO_PORTAS) — degrau ignorado"
        continue
    fi

    # Gateway novo por degrau: o RSS base é lido com zero conexões, e um
    # processo reaproveitado carregaria o pico do degrau anterior (o Go não
    # devolve memória ao SO de imediato).
    /tmp/gw -addr "$ADDR" -quiet >/tmp/gw.log 2>&1 &
    GW_PID=$!
    sleep 0.7

    if ! kill -0 "$GW_PID" 2>/dev/null; then
        echo "  gateway nao subiu: $(tail -2 /tmp/gw.log)"
        falhou=1
        break
    fi

    /tmp/lg -addr "$ADDR" -n "$n" -conc 256 -hold "${HOLD}s" >/tmp/lg.log 2>&1 &
    LG_PID=$!

    # Lê as estatísticas no meio do "hold", com todas as conexões de pé.
    sleep $((HOLD / 2))
    stats=$(curl -fsS "http://$ADDR/stats" 2>/dev/null)

    if [ -z "$stats" ]; then
        echo "  /stats nao respondeu no degrau $n"
        falhou=1
        kill "$LG_PID" 2>/dev/null; kill "$GW_PID" 2>/dev/null; wait 2>/dev/null
        break
    fi

    campo() { printf '%s' "$stats" | grep -o "\"$1\":[0-9]*" | cut -d: -f2; }
    mb() { awk -v b="$1" 'BEGIN{printf "%.1f", b/1048576}'; }

    conns=$(campo conexoes)
    gor=$(campo goroutines)
    heap=$(campo heap_alloc_bytes)
    stack=$(campo stack_inuse_bytes)
    rss=$(campo rss_bytes)
    porconn=$(campo bytes_por_conexao_rss)

    printf '%-10s %10s %12s %12s %12s %14s\n' \
        "$conns" "$gor" "$(mb "$heap")" "$(mb "$stack")" "$(mb "$rss")" "$porconn"

    wait "$LG_PID" 2>/dev/null
    lg_rc=$?
    if [ "$lg_rc" -ne 0 ]; then
        echo "  AVISO: o loadgen saiu com $lg_rc -- abriu menos conexões do que pedi:"
        sed 's/^/           | /' /tmp/lg.log | tail -6
        falhou=1
    fi

    kill "$GW_PID" 2>/dev/null
    wait "$GW_PID" 2>/dev/null
    GW_PID=""
    sleep 0.5
done

# ------------------------------------------- efeito do tamanho dos buffers
# E a medicao que justifica implementar o WebSocket em vez de usar biblioteca:
# com os buffers escondidos dentro dela, esta tabela nao existiria.
N_BUF=${N_BUF:-10000}

cat <<EOF

=== Efeito do tamanho dos buffers, com $N_BUF conexões ===

EOF

printf '%-22s %12s %14s %12s
' "buffers (leitura/escrita)" "RSS (MB)" "bytes/conn" "vs 1 KiB"
printf '%s
' "------------------------------------------------------------------"

base_porconn=""

for buf in 512 1024 4096 16384; do
    /tmp/gw -addr "$ADDR" -quiet -read-buf "$buf" -write-buf "$buf" >/tmp/gw.log 2>&1 &
    GW_PID=$!
    sleep 0.7

    /tmp/lg -addr "$ADDR" -n "$N_BUF" -conc 256 -hold "${HOLD}s"         -read-buf "$buf" -write-buf "$buf" >/tmp/lg.log 2>&1 &
    LG_PID=$!
    sleep $((HOLD / 2))

    stats=$(curl -fsS "http://$ADDR/stats" 2>/dev/null)
    if [ -n "$stats" ]; then
        rss=$(printf '%s' "$stats" | grep -o '"rss_bytes":[0-9]*' | cut -d: -f2)
        porconn=$(printf '%s' "$stats" | grep -o '"bytes_por_conexao_rss":[0-9]*' | cut -d: -f2)
        [ "$buf" = 1024 ] && base_porconn=$porconn
        rel="-"
        if [ -n "$base_porconn" ] && [ "$base_porconn" -gt 0 ]; then
            rel=$(awk -v a="$porconn" -v b="$base_porconn" 'BEGIN{printf "%+.0f%%", (a/b-1)*100}')
        fi
        printf '%-22s %12s %14s %12s
'             "$buf / $buf" "$(awk -v b="$rss" 'BEGIN{printf "%.1f", b/1048576}')" "$porconn" "$rel"
    else
        printf '%-22s %12s
' "$buf / $buf" "sem resposta"
        falhou=1
    fi

    kill "$LG_PID" 2>/dev/null
    kill "$GW_PID" 2>/dev/null
    wait 2>/dev/null
    GW_PID=""
    sleep 0.5
done

cat <<'EOF'

A coluna `vs 1 KiB` compara com o padrão escolhido em ws.DefaultConfig(). O
valor de 4 KiB é o que as bibliotecas populares de WebSocket usam por padrão: a
diferença é o custo de não ter escolhido.

O que `bytes/conn` NÃO inclui: os buffers de socket do kernel. Eles ficam fora
do RSS do processo (são memória de kernel, contabilizada em slab), e no Linux
partem de ~2-4 KiB por socket podendo crescer com a janela TCP. A conta
completa de uma conexão real é maior que a coluna acima -- quanto maior depende
de sysctl, e medir isso exigiria ler /proc/net/sockstat, que está no roadmap.

EOF

[ "$falhou" -eq 0 ]
