#!/usr/bin/env bash
#
# verifica.sh — comprova as quatro propriedades que o HCL tem e um script não.
#
#   cd infra && bash verifica.sh
#
# Não é um teste de "o tofu funciona". É a verificação das afirmações que o
# README faz sobre por que valeu a pena declarar esta infraestrutura em vez de
# escrever `docker run`. Cada uma é checada por máquina, e uma que falhe
# derruba o script.
#
# A ferramenta central é `tofu plan -detailed-exitcode`, cujo código de saída é
# a afirmação em forma verificável:
#
#   0 = nenhuma mudança (a realidade bate com a configuração)
#   1 = erro
#   2 = há mudanças pendentes (desvio detectado)
#
# ## Esta é a sexta vez
#
# `set -euo pipefail` e o `test` depois de cada passo estão aqui porque este
# projeto já perdeu tempo cinco vezes com harness que engoliu o próprio erro:
# o harness de benchmark do p01, o `kill_fraction`, o `setup.sh`, o `smoke.sh`
# e o `loadgen`. Script de verificação que não verifica o próprio sucesso é
# pior que nenhum: ele dá confiança falsa.

set -euo pipefail

cd "$(dirname "$0")"

PREFIXO="${PREFIXO:-otpmesh}"
falhas=0

cabecalho() {
  echo
  echo "=============================================================="
  echo "  $1"
  echo "=============================================================="
}

ok() { echo "  [ok]    $1"; }

falha() {
  echo "  [FALHA] $1"
  falhas=$((falhas + 1))
}

# ---------------------------------------------------------------- pré-requisitos
cabecalho "Pré-requisitos"

command -v tofu >/dev/null || {
  echo "tofu não encontrado. Rode ../setup.sh"
  exit 1
}

docker info >/dev/null 2>&1 || {
  echo "daemon do Docker não responde."
  exit 1
}

ok "tofu $(tofu version | head -1 | awk '{print $2}')"
ok "docker $(docker --version | awk '{print $3}' | tr -d ,)"

# `init` é idempotente e barato quando já inicializado.
tofu init -no-color -input=false >/dev/null
ok "tofu init"

tofu validate -no-color >/dev/null || {
  echo "configuração inválida"
  exit 1
}
ok "tofu validate"

# `fmt -check` falha se o HCL não estiver formatado. Mesmo papel do
# `mix format --check-formatted` e do `gleam format --check` no CI.
if tofu fmt -check -recursive >/dev/null; then
  ok "tofu fmt"
else
  falha "HCL não formatado; rode 'tofu fmt -recursive'"
fi

# ------------------------------------------------------- 1. convergência
cabecalho "1. Convergência: apply cria o que foi declarado"

tofu apply -auto-approve -no-color -input=false >/tmp/v_apply1.txt 2>&1 || {
  echo "apply falhou:"
  tail -20 /tmp/v_apply1.txt
  exit 1
}

if grep -qE "Apply complete" /tmp/v_apply1.txt; then
  ok "$(grep -oE 'Resources: .*' /tmp/v_apply1.txt | tail -1)"
else
  falha "apply não reportou conclusão"
  tail -10 /tmp/v_apply1.txt
fi

# Os recursos existem de fato? O estado do tofu dizer que existem não é
# verificação -- é a mesma fonte que acabou de os criar. Pergunta ao Docker.
for nome in "${PREFIXO}-gateway" "${PREFIXO}-nats"; do
  if docker inspect "$nome" >/dev/null 2>&1; then
    estado=$(docker inspect -f '{{.State.Status}}' "$nome")
    if [ "$estado" = "running" ]; then
      ok "contêiner $nome está running (confirmado no Docker, não no estado)"
    else
      falha "contêiner $nome existe mas está '$estado'"
    fi
  else
    falha "contêiner $nome não existe no Docker"
  fi
done

if docker network inspect "${PREFIXO}-rede" >/dev/null 2>&1; then
  ok "rede ${PREFIXO}-rede existe"
else
  falha "rede ${PREFIXO}-rede não existe"
fi

# O gateway responde? Infraestrutura que sobe e não serve não convergiu.
porta=$(tofu output -raw gateway_stats | sed 's#.*:\([0-9]*\)/.*#\1#')
for _ in $(seq 1 20); do
  if curl -sf "http://127.0.0.1:${porta}/stats" >/tmp/v_stats.json 2>/dev/null; then
    break
  fi
  sleep 0.5
done

if [ -s /tmp/v_stats.json ] && grep -q '"conexoes"' /tmp/v_stats.json; then
  ok "gateway responde em /stats (porta $porta)"
  # Confirma que a variável buffer_bytes chegou ao binário: o /stats não
  # reporta o buffer, mas reporta nucleo_ligado, que prova que é o nosso
  # binário e não outra coisa escutando na porta.
  if grep -q '"nucleo_ligado":false' /tmp/v_stats.json; then
    ok "é o gateway deste repositório (nucleo_ligado=false, sem -core)"
  else
    falha "algo responde na porta, mas não parece o nosso gateway"
  fi
else
  falha "gateway não respondeu em /stats"
fi

# ------------------------------------------------------- 2. idempotência
cabecalho "2. Idempotência: aplicar de novo não muda nada"

set +e
tofu plan -no-color -input=false -detailed-exitcode >/tmp/v_plan_idem.txt 2>&1
codigo=$?
set -e

case $codigo in
  0) ok "plan: 0 (nenhuma mudança) -- a realidade bate com a configuração" ;;
  2)
    falha "plan: 2 (há mudanças pendentes logo depois de um apply)"
    grep -E "will be|must be" /tmp/v_plan_idem.txt | head -5
    ;;
  *)
    falha "plan: $codigo (erro)"
    tail -10 /tmp/v_plan_idem.txt
    ;;
esac

# E o apply de verdade, para confirmar que não é só o plan que acha isso.
tofu apply -auto-approve -no-color -input=false >/tmp/v_apply2.txt 2>&1
if grep -qE "Resources: 0 added, 0 changed, 0 destroyed" /tmp/v_apply2.txt; then
  ok "segundo apply: 0 added, 0 changed, 0 destroyed"
else
  falha "segundo apply mudou algo: $(grep -oE 'Resources: .*' /tmp/v_apply2.txt | tail -1)"
fi

# --------------------------------------------- 3. detecção de desvio
cabecalho "3. Detecção de desvio: o que um script não tem"

# AUTOTESTE DO INSTRUMENTO, antes de confiar nele.
#
# Toda esta secao depende de `plan -detailed-exitcode` devolver 2 quando ha
# desvio. Se esse mecanismo nao funcionar, as asseroes abaixo passariam a
# reportar "nenhum desvio" para qualquer coisa -- um falso OK, que e pior que
# uma falha.
#
# O teste: com a infraestrutura convergida, o codigo TEM de ser 0. Combinado
# com a verificacao de que o texto e o codigo concordam (avalia_desvio
# abaixo), isso pega o wrapper que engole exit code.
set +e
tofu plan -no-color -input=false -detailed-exitcode >/dev/null 2>&1
codigo_base=$?
set -e

if [ "$codigo_base" -eq 0 ]; then
  ok "instrumento: plan -detailed-exitcode devolve 0 com tudo convergido"
else
  falha "instrumento: esperava 0 com tudo convergido, recebi $codigo_base"
fi


echo "  Quebrando a infraestrutura à mão, de dois jeitos."
echo

# 3a. Contêiner parado. `restart = unless-stopped` faz o Docker NÃO religar
# depois de um stop explícito, então o desvio persiste.
docker stop "${PREFIXO}-gateway" >/dev/null

set +e
tofu plan -no-color -input=false -detailed-exitcode >/tmp/v_plan_stop.txt 2>&1
codigo=$?
set -e

avalia_desvio() {
  local arquivo="$1" codigo="$2" rotulo="$3"

  # O texto do plan e o codigo de saida sao DUAS evidencias. Se elas
  # discordarem, o problema nao e a infraestrutura: e o instrumento.
  local texto_diz_mudanca=0
  grep -qE "will be created|must be replaced|will be updated" "$arquivo" && texto_diz_mudanca=1

  if [ "$codigo" -eq 2 ] && [ "$texto_diz_mudanca" -eq 1 ]; then
    ok "$rotulo: plan devolveu 2 e o texto confirma"
    echo "          $(grep -E 'must be replaced|will be created|will be updated' "$arquivo" | head -1 | sed 's/^ *//')"
  elif [ "$codigo" -eq 0 ] && [ "$texto_diz_mudanca" -eq 1 ]; then
    # Este e o caso que o CI expos: o wrapper da action
    # opentofu/setup-opentofu engolia o codigo de saida.
    falha "$rotulo: INSTRUMENTO QUEBRADO -- o texto do plan diz que ha mudanca, mas o codigo de saida foi 0"
    echo "          Causa provavel: wrapper em volta do tofu engolindo o exit code."
    echo "          Em GitHub Actions: 'tofu_wrapper: false' no setup-opentofu."
  elif [ "$codigo" -eq 0 ]; then
    falha "$rotulo: NAO foi detectado (plan devolveu 0 e o texto nao aponta mudanca)"
  else
    falha "$rotulo: plan devolveu $codigo"
    tail -5 "$arquivo"
  fi
}

avalia_desvio /tmp/v_plan_stop.txt "$codigo" "contêiner parado"

# 3b. Contêiner removido. Caso mais grave, e o mais claro.
docker rm -f "${PREFIXO}-gateway" >/dev/null

set +e
tofu plan -no-color -input=false -detailed-exitcode >/tmp/v_plan_rm.txt 2>&1
codigo=$?
set -e

avalia_desvio /tmp/v_plan_rm.txt "$codigo" "contêiner removido"

# 3c. E converge de volta.
tofu apply -auto-approve -no-color -input=false >/tmp/v_apply3.txt 2>&1
if grep -qE "Apply complete" /tmp/v_apply3.txt; then
  ok "apply reconvergiu: $(grep -oE 'Resources: .*' /tmp/v_apply3.txt | tail -1)"
else
  falha "apply não reconvergiu"
fi

set +e
tofu plan -no-color -input=false -detailed-exitcode >/dev/null 2>&1
codigo=$?
set -e
[ $codigo -eq 0 ] && ok "e voltou a 0 mudanças" || falha "ainda há desvio depois do apply"

# ------------------------------------------ 4. grafo de dependências
cabecalho "4. Grafo: a ordem vem das referências, não do arquivo"

grafo=$(tofu graph)

verifica_aresta() {
  local de="$1" para="$2"
  if echo "$grafo" | grep -q "\"\[root\] $de (expand)\" -> \"\[root\] $para (expand)\""; then
    ok "$de depende de $para"
  else
    falha "aresta ausente: $de -> $para"
  fi
}

verifica_aresta "docker_container.gateway" "docker_network.mesh"
verifica_aresta "docker_container.gateway" "docker_image.gateway"
verifica_aresta "docker_container.nats" "docker_network.mesh"

# A dependência que NÃO deve existir: o gateway não depende do NATS, porque
# nada no código dele referencia o NATS. Declarar um depends_on aqui seria
# inventar acoplamento e deixar o apply mais lento sem motivo.
if echo "$grafo" | grep -q "\"\[root\] docker_container.gateway (expand)\" -> \"\[root\] docker_container.nats (expand)\""; then
  falha "gateway depende do NATS, e não deveria (acoplamento inventado)"
else
  ok "gateway NÃO depende do NATS -- dependência não inventada"
fi

# ------------------------------------------------- 5. destruição completa
cabecalho "5. Destruição: remove o que criou, e só isso"

antes_redes=$(docker network ls --format '{{.Name}}' | wc -l)

tofu destroy -auto-approve -no-color -input=false >/tmp/v_destroy.txt 2>&1 || {
  echo "destroy falhou:"
  tail -20 /tmp/v_destroy.txt
  exit 1
}

if grep -qE "Destroy complete" /tmp/v_destroy.txt; then
  ok "$(grep -oE 'Resources: [0-9]+ destroyed' /tmp/v_destroy.txt | tail -1)"
else
  falha "destroy não reportou conclusão"
fi

for nome in "${PREFIXO}-gateway" "${PREFIXO}-nats"; do
  if docker inspect "$nome" >/dev/null 2>&1; then
    falha "contêiner $nome sobreviveu ao destroy"
  else
    ok "contêiner $nome removido"
  fi
done

if docker network inspect "${PREFIXO}-rede" >/dev/null 2>&1; then
  falha "rede ${PREFIXO}-rede sobreviveu ao destroy -- é o recurso que todo script de limpeza esquece"
else
  ok "rede removida (o recurso que script de limpeza esquece)"
fi

# `keep_locally = true` na imagem do NATS: ela DEVE sobreviver, de propósito.
if docker image inspect "nats:2.10-alpine" >/dev/null 2>&1; then
  ok "imagem do NATS preservada (keep_locally = true, deliberado)"
else
  echo "  [nota]  imagem do NATS não está local; keep_locally não a recria, só evita apagá-la"
fi

depois_redes=$(docker network ls --format '{{.Name}}' | wc -l)
if [ "$depois_redes" -lt "$antes_redes" ]; then
  ok "contagem de redes caiu de $antes_redes para $depois_redes"
else
  falha "contagem de redes não caiu ($antes_redes -> $depois_redes)"
fi

# -------------------------------------------------------------- resultado
cabecalho "Resultado"

if [ "$falhas" -eq 0 ]; then
  echo "  Todas as verificações passaram."
  echo
  echo "  As quatro propriedades do README estão comprovadas:"
  echo "    1. convergência  -- apply cria e o serviço responde"
  echo "    2. idempotência  -- segundo apply: 0 added, 0 changed, 0 destroyed"
  echo "    3. desvio        -- contêiner parado E removido são detectados"
  echo "    4. grafo         -- a ordem vem das referências, e só delas"
  echo "    5. destruição    -- inclusive a rede, que script esquece"
  exit 0
else
  echo "  $falhas verificação(ões) falharam."
  exit 1
fi
