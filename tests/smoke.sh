#!/usr/bin/env bash
# smoke.sh — prova que cada toolchain do ambiente COMPILA E EXECUTA algo.
#
# Instalar não é funcionar: `--version` responder não garante que o compilador
# acha a biblioteca padrão, que o Docker tem cgroups, ou que o kind consegue
# subir um nó. Este script é a diferença entre "instalei" e "funciona".
#
#   uso:  bash tests/smoke.sh [langs|infra|jvm|all]
#
# Os estágios são separados porque têm custos muito diferentes: `langs` leva
# segundos, `infra` sobe um cluster Kubernetes de verdade e `jvm` baixa o
# compilador Scala na primeira execução.
set -uo pipefail

STAGE=${1:-all}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { printf '  \033[32mok\033[0m   %-18s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %-18s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

check() { # $1 = nome, $2 = esperado, $3.. = comando
    local name=$1 want=$2; shift 2
    # A saída completa vai para arquivo e a comparação usa a ÚLTIMA linha.
    #
    # A primeira versão fazia `$(... 2>&1 | tail -1)` e, nos comandos em que eu
    # havia posto `2>/dev/null`, a falha aparecia como saída vazia sem motivo
    # nenhum: o CI reportou "gleam: esperava [42], veio []" e eu não tinha como
    # saber por quê. Esconder stderr num harness de verificação é o mesmo erro
    # de redirecionar para /dev/null e não olhar o retorno -- é o quarto caso
    # dele neste portfólio.
    local slug out
    slug=$(printf '%s' "$name" | tr -cd 'A-Za-z0-9_-')
    out="$TMP/$slug.log"
    "$@" >"$out" 2>&1
    local got
    got=$(tail -1 "$out")
    if [ "$got" = "$want" ]; then
        ok "$name" "$got"
    else
        bad "$name" "esperava [$want], veio [$got]"
        # Sem isto, uma falha no CI é indistinguível de outra.
        sed 's/^/           | /' "$out" | tail -8
    fi
}

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# =========================================================== linguagens
if [ "$STAGE" = langs ] || [ "$STAGE" = all ]; then
say "Linguagens: compilar e executar"

# --- Erlang: processo, mensagem e resposta. É o modelo de ator, não um hello.
cat > "$TMP/ator.erl" <<'ERL'
-module(ator).
-export([main/0]).
main() ->
    Pai = self(),
    Pid = spawn(fun() -> receive {From, N} -> From ! {ok, N * 2} end end),
    Pid ! {Pai, 21},
    receive {ok, R} -> io:format("~p~n", [R]) end.
ERL
(cd "$TMP" && erlc ator.erl >"$TMP/erlc.log" 2>&1) \
  && check "erlang" "42" erl -noshell -pa "$TMP" -eval 'ator:main(),halt().' \
  || { bad "erlang" "erlc falhou"; sed 's/^/           | /' "$TMP/erlc.log" | tail -5; }

# --- Elixir: supervisor + GenServer. Se isto roda, o OTP esta inteiro, que e
# a premissa do projeto todo.
cat > "$TMP/otp.exs" <<'EXS'
defmodule Contador do
  use GenServer
  def start_link(n), do: GenServer.start_link(__MODULE__, n, name: __MODULE__)
  def init(n), do: {:ok, n}
  def handle_call(:dobra, _from, n), do: {:reply, n * 2, n}
end

{:ok, _sup} =
  Supervisor.start_link([{Contador, 21}], strategy: :one_for_one)

IO.puts(GenServer.call(Contador, :dobra))
EXS
check "elixir (OTP)" "42" elixir "$TMP/otp.exs"

# --- Gleam: tipagem estatica sobre a BEAM. Compila via rebar3.
if command -v gleam >/dev/null; then
  (cd "$TMP" && gleam new g --name g >"$TMP/gleam-new.log" 2>&1) && {
    cat > "$TMP/g/src/g.gleam" <<'GLE'
import gleam/io
import gleam/int

pub fn main() {
  io.println(int.to_string(21 * 2))
}
GLE
    check "gleam" "42" sh -c "cd '$TMP/g' && gleam run"
  } || { bad "gleam" "gleam new falhou"; sed 's/^/           | /' "$TMP/gleam-new.log" | tail -5; }
fi

# --- Go: goroutine e canal, que e o motivo de o Go estar no projeto.
mkdir -p "$TMP/go"
cat > "$TMP/go/main.go" <<'GO'
package main

import "fmt"

func main() {
	ch := make(chan int)
	go func() { ch <- 21 * 2 }()
	fmt.Println(<-ch)
}
GO
check "go (goroutine)" "42" sh -c "cd '$TMP/go' && go mod init m >/dev/null 2>&1; go run main.go"

# --- Rust
mkdir -p "$TMP/rs"
echo 'fn main(){ println!("{}", 21*2); }' > "$TMP/rs/m.rs"
(cd "$TMP/rs" && rustc -O m.rs -o m 2>"$TMP/rustc.log") \
  && check "rust" "42" "$TMP/rs/m" \
  || { bad "rust" "rustc falhou"; sed 's/^/           | /' "$TMP/rustc.log" | tail -5; }

# --- Clojure
check "clojure" "42" clojure -e '(println (* 21 2))'
fi

# =========================================================== JVM pesada
if [ "$STAGE" = jvm ] || [ "$STAGE" = all ]; then
say "Scala (baixa o compilador na primeira execução)"
mkdir -p "$TMP/sc"
cat > "$TMP/sc/M.scala" <<'SCALA'
@main def run(): Unit = println(21 * 2)
SCALA
check "scala 3" "42" sh -c "cd '$TMP/sc' && scala-cli run ."
fi

# =========================================================== infraestrutura
if [ "$STAGE" = infra ] || [ "$STAGE" = all ]; then
say "Infraestrutura: container, cluster, fila e IaC"

# --- Docker: cgroups e rede funcionando dentro do WSL2
check "docker run" "42" docker run --rm alpine:3.22 sh -c 'echo $((21*2))'

# --- NATS: servidor sobe, aceita publicacao e entrega
if command -v nats-server >/dev/null; then
  nats-server -p 4222 -a 127.0.0.1 >"$TMP/nats.log" 2>&1 &
  NATS_PID=$!
  sleep 1
  if kill -0 "$NATS_PID" 2>/dev/null; then
    # sem cliente nats instalado, testa o monitor HTTP do proprio servidor
    nats-server -p 4223 -a 127.0.0.1 -m 8222 >"$TMP/nats2.log" 2>&1 &
    NATS2=$!
    sleep 1
    if curl -fsS http://127.0.0.1:8222/varz 2>/dev/null | grep -q '"server_id"'; then
      ok "nats-server" "subiu e responde no /varz"
    else
      bad "nats-server" "subiu mas o monitor nao respondeu"
    fi
    kill "$NATS2" 2>/dev/null
  else
    bad "nats-server" "nao subiu: $(tail -1 "$TMP/nats.log")"
  fi
  kill "$NATS_PID" 2>/dev/null
fi

# --- OpenTofu com provider LOCAL: HCL de verdade, sem nuvem e sem cartao
mkdir -p "$TMP/tf"
cat > "$TMP/tf/main.tf" <<'TF'
terraform {
  required_providers {
    local = { source = "opentofu/local", version = "~> 2.5" }
  }
}

variable "resposta" {
  type    = number
  default = 42
}

resource "local_file" "saida" {
  filename = "${path.module}/saida.txt"
  content  = tostring(var.resposta)
}

output "conteudo" {
  value = local_file.saida.content
}
TF
if (cd "$TMP/tf" && tofu init -no-color >/dev/null 2>&1 && tofu apply -auto-approve -no-color >/dev/null 2>&1); then
  check "opentofu (HCL)" "42" cat "$TMP/tf/saida.txt"
else
  bad "opentofu (HCL)" "init/apply falhou (ver rede)"
fi

# --- kind: um cluster Kubernetes de verdade, dentro do Docker. E o teste mais
# caro e o mais informativo: exige cgroup v2, inotify e ~1 GB.
if command -v kind >/dev/null; then
  printf '  %-18s ' "kind (k8s)"
  if kind create cluster --name p03smoke --wait 90s >"$TMP/kind.log" 2>&1; then
    nodes=$(kubectl --context kind-p03smoke get nodes --no-headers 2>/dev/null | wc -l)
    ready=$(kubectl --context kind-p03smoke get nodes --no-headers 2>/dev/null | grep -c " Ready ")
    if [ "$ready" -ge 1 ]; then
      printf '\033[32mok\033[0m   %s no(s), %s Ready\n' "$nodes" "$ready"; pass=$((pass+1))
    else
      printf '\033[31mFAIL\033[0m cluster subiu mas nenhum no ficou Ready\n'; fail=$((fail+1))
    fi
    kind delete cluster --name p03smoke >/dev/null 2>&1
  else
    printf '\033[31mFAIL\033[0m %s\n' "$(tail -2 "$TMP/kind.log" | tr '\n' ' ')"; fail=$((fail+1))
  fi
fi
fi

echo
echo "$pass passaram, $fail falharam"
[ "$fail" -eq 0 ]
