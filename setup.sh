#!/usr/bin/env bash
# setup.sh — provisiona o ambiente do P03 inteiro, sem nenhum recurso pago.
#
# Princípio: nada aqui exige conta, cartão de crédito ou licença comercial.
# Cada escolha em que havia um equivalente proprietário ou apenas
# "source-available" está justificada no README, seção Ambiente.
#
#   uso:  bash setup.sh            # instala o que falta e verifica
#         bash setup.sh --check    # só verifica, não instala
#
# Testado em Ubuntu 26.04 sob WSL2 (systemd como PID 1, cgroup v2).
set -uo pipefail

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

BIN=/usr/local/bin
ARCH=$(uname -m)
[ "$ARCH" = "x86_64" ] || { echo "este script assume x86_64, veio $ARCH"; exit 2; }

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
item() { printf '  %-14s ' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

# Resolve a tag do release mais recente pela API pública do GitHub — sem token,
# sem conta.
#
# O JSON é capturado inteiro antes de filtrar. Com `grep -m1` direto no pipe, o
# grep fecha a saída do curl no meio e o curl reclama com
# "(23) Failure writing output" — inofensivo, mas polui o log.
gh_latest() {
    local json
    json=$(curl -fsSL "https://api.github.com/repos/$1/releases/latest") || return 1
    printf '%s' "$json" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"//; s/".*//'
}

fetch_bin() {  # $1 = url, $2 = nome do binário no destino
    local url=$1 name=$2 tmp found
    tmp=$(mktemp -d)
    if curl -fsSL "$url" -o "$tmp/dl"; then
        case "$url" in
            *.tar.gz|*.tgz) tar -xzf "$tmp/dl" -C "$tmp" ;;
            *.zip)          unzip -q "$tmp/dl" -d "$tmp" ;;
            # .gz SEM tar é um binário único comprimido (caso do scala-cli).
            # Sem este caso, o arquivo comprimido era instalado como se fosse
            # executável e falhava com "Exec format error".
            *.gz)           gunzip -c "$tmp/dl" > "$tmp/$name" ;;
            *)              mv "$tmp/dl" "$tmp/$name" ;;
        esac
        found=$(find "$tmp" -type f -name "$name" | head -1)
        [ -n "$found" ] || found=$(find "$tmp" -type f -perm -u+x ! -name dl | head -1)
        if [ -n "$found" ]; then
            install -m 0755 "$found" "$BIN/$name"
            rm -rf "$tmp"
            return 0
        fi
    fi
    rm -rf "$tmp"
    return 1
}

# ---------------------------------------------------------------- pacotes apt
say "1. Pacotes do apt (livres, nos repositórios do Ubuntu)"

# O mapa é `comando:pacote`, e a verificação é pelo COMANDO, não pelo nome do
# pacote.
#
# A primeira versão checava `dpkg -s docker.io` e `dpkg -s golang-go`. Num
# runner do GitHub, `docker` e `go` já existem — instalados por `moby-engine` e
# pelo tarball oficial do Go — então o script tentava instalar os pacotes do
# Debian por cima e o apt recusava com
# "pkgProblemResolver::Resolve generated breaks".
#
# O que importa é a ferramenta funcionar, não qual pacote a forneceu. Checar
# capacidade em vez de identidade de pacote conserta o runner e é mais correto
# em qualquer máquina que já tenha as ferramentas por outro caminho.
APT_MAP="erl:erlang elixir:elixir go:golang-go java:openjdk-21-jdk docker:docker.io clojure:clojure rebar3:rebar3 curl:curl unzip:unzip"
MISSING=""
for entry in $APT_MAP; do
    cmd=${entry%%:*}
    pkg=${entry##*:}
    have "$cmd" || MISSING="$MISSING $pkg"
done
if [ -n "$MISSING" ]; then
    if [ "$CHECK_ONLY" = 1 ]; then
        echo "  faltando:$MISSING"
    else
        echo "  instalando:$MISSING"

        # `apt-get update` antes, e o erro NÃO é engolido.
        #
        # A primeira versão rodava `apt-get install -y -qq ... >/dev/null` sem
        # update e sem checar o código de saída. Numa máquina com as listas de
        # pacotes vazias — um runner de CI recém-criado, por exemplo — o
        # install falha com "Unable to locate package", o script imprime
        # "instalando: ..." e segue como se tivesse dado certo. Foi assim que o
        # primeiro CI deste projeto passou no provisionamento e falhou no teste
        # de fumaça com `elixir: command not found`.
        #
        # É o terceiro caso de falha silenciosa que este portfólio corrige: o
        # harness do P01, o do P03 e agora o provisionador. O padrão é sempre o
        # mesmo — redirecionar a saída e não olhar o código de retorno.
        if ! apt-get update -qq; then
            echo "  ERRO: apt-get update falhou" >&2
            exit 1
        fi

        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $MISSING; then
            echo "  ERRO: apt-get install falhou para:$MISSING" >&2
            exit 1
        fi

        # Confere o que de fato ficou utilizável, em vez de confiar no
        # instalador -- e pelo comando, pelo mesmo motivo da checagem acima.
        ainda_falta=""
        for entry in $APT_MAP; do
            cmd=${entry%%:*}
            have "$cmd" || ainda_falta="$ainda_falta $cmd"
        done
        if [ -n "$ainda_falta" ]; then
            echo "  ERRO: apt disse que instalou, mas estes comandos nao existem:$ainda_falta" >&2
            exit 1
        fi
        echo "  instalados e conferidos"
    fi
else
    echo "  todos presentes"
fi

# ------------------------------------------------------- binários de releases
say "2. Binários de releases oficiais (GitHub, sem autenticação)"

install_gleam() {
    local tag; tag=$(gh_latest gleam-lang/gleam) || return 1
    fetch_bin "https://github.com/gleam-lang/gleam/releases/download/${tag}/gleam-${tag}-x86_64-unknown-linux-musl.tar.gz" gleam
}
install_kind() {
    local tag; tag=$(gh_latest kubernetes-sigs/kind) || return 1
    fetch_bin "https://github.com/kubernetes-sigs/kind/releases/download/${tag}/kind-linux-amd64" kind
}
install_kubectl() {
    local v; v=$(curl -fsSL https://dl.k8s.io/release/stable.txt) || return 1
    fetch_bin "https://dl.k8s.io/release/${v}/bin/linux/amd64/kubectl" kubectl
}
install_tofu() {
    local tag ver; tag=$(gh_latest opentofu/opentofu) || return 1; ver=${tag#v}
    fetch_bin "https://github.com/opentofu/opentofu/releases/download/${tag}/tofu_${ver}_linux_amd64.zip" tofu
}
install_nats() {
    local tag; tag=$(gh_latest nats-io/nats-server) || return 1
    fetch_bin "https://github.com/nats-io/nats-server/releases/download/${tag}/nats-server-${tag}-linux-amd64.tar.gz" nats-server
}
install_scala_cli() {
    local tag; tag=$(gh_latest VirtusLab/scala-cli) || return 1
    fetch_bin "https://github.com/VirtusLab/scala-cli/releases/download/${tag}/scala-cli-x86_64-pc-linux.gz" scala-cli
}

for pair in "gleam:install_gleam" "kind:install_kind" "kubectl:install_kubectl" \
            "tofu:install_tofu" "nats-server:install_nats" "scala-cli:install_scala_cli"; do
    name=${pair%%:*}; fn=${pair##*:}
    item "$name"
    if have "$name"; then
        echo "já instalado"
    elif [ "$CHECK_ONLY" = 1 ]; then
        echo "FALTANDO"
    elif $fn; then
        echo "instalado"
    else
        echo "FALHOU — ver README, seção Ambiente"
    fi
done

# -------------------------------------------------------------------- docker
say "3. Docker Engine (não Docker Desktop: sem licença comercial)"
if [ "$CHECK_ONLY" = 0 ]; then
    systemctl is-active --quiet docker || systemctl start docker 2>/dev/null
    systemctl is-enabled --quiet docker || systemctl enable docker >/dev/null 2>&1
fi
item "dockerd"
if docker info >/dev/null 2>&1; then
    echo "ativo"
else
    echo "INATIVO — tente: sudo systemctl start docker"
fi

# ---------------------------------------------------------------- verificação
say "4. Versões instaladas"
report() { item "$1"; shift; "$@" 2>&1 | head -1 || echo "-"; }

report erlang     erl -noshell -eval 'io:fwrite(erlang:system_info(otp_release)),io:nl(),halt().'
report elixir     elixir -e 'IO.puts("Elixir " <> System.version())'
report rebar3     rebar3 --version
report gleam      gleam --version
report go         go version
report java       java -version
report scala-cli  scala-cli version --cli-version
report clojure    clojure -e '(println (str "Clojure " (clojure-version)))'
report rust       rustc --version
report docker     docker --version
report kind       kind --version
report kubectl    sh -c 'kubectl version --client=true -o yaml | grep gitVersion'
report tofu       tofu --version
report nats       nats-server --version

say "Pronto. Nenhuma ferramenta acima exige conta, cartão ou licença paga."
