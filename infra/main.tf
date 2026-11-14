# main.tf — a infraestrutura dos testes, declarada.
#
#   cd infra && tofu init && tofu apply
#
# ## Por que isto não é um script shell com docker run
#
# Os testes de fumaça deste projeto sobem contêineres com `docker run`, e
# funciona. A pergunta honesta é o que o HCL acrescenta, e a resposta não é
# "elegância": são quatro propriedades que um script não tem, e que
# `verifica.sh` comprova uma por uma.
#
#   1. **Idempotência.** `apply` duas vezes seguidas não muda nada. Um script
#      com `docker run` falha na segunda vez por nome já em uso, ou precisa de
#      um `docker rm -f` defensivo que apaga antes de saber se precisava.
#
#   2. **Detecção de desvio.** Se alguém parar um contêiner à mão, `tofu plan`
#      **vê** e diz o que fará. O script não tem com o que comparar: ele não
#      sabe qual era o estado desejado, só sabe executar comandos.
#
#   3. **Grafo de dependências.** A ordem aqui não vem da ordem no arquivo: vem
#      de quem referencia quem. O gateway depende da rede porque **usa** o id
#      dela. Trocar a ordem dos blocos neste arquivo não muda nada.
#
#   4. **Destruição completa.** `destroy` remove o que criou, e só isso. Um
#      script de limpeza esquece recursos conforme a configuração cresce —
#      especialmente redes e volumes, que ninguém lembra de apagar.
#
# ## Por que OpenTofu e não Terraform
#
# O Terraform passou para a licença BUSL em agosto de 2023, que proíbe uso em
# produto concorrente e **não é open source** pela definição da OSI. O OpenTofu
# é o fork da comunidade sob **MPL-2.0**, mantido pela Linux Foundation.
#
# Para este projeto a diferença é concreta: o requisito era "nenhum recurso
# pago e nenhuma licença restritiva", e BUSL não passa. A decisão está em
# `docs/AMBIENTE.md` junto com a mesma escolha para NATS contra Redpanda.
#
# Os dois ainda leem HCL idêntico, então a linguagem demonstrada é a mesma.

terraform {
  required_version = ">= 1.6"

  required_providers {
    docker = {
      source = "kreuzwerker/docker"
      # Fixado em versão exata: provider de infraestrutura que flutua é a
      # diferença entre "funciona na minha máquina" e "funciona".
      #
      # A série 3.x NÃO instala pelo registro do OpenTofu -- `tofu init` recusa
      # com "the provider is not signed with a valid signing key". É um
      # problema de assinatura do registro, não do código, e a 4.x resolve.
      # Registrado aqui para quem tentar fixar numa 3.x e perder tempo.
      version = "4.7.0"
    }
  }
}

provider "docker" {
  host = var.docker_host
}

# ---------------------------------------------------------------- rede
#
# Uma rede própria, e não a bridge padrão, por um motivo prático: na rede
# padrão os contêineres não se resolvem por nome. Aqui o gateway alcança o NATS
# em `nats:4222` sem precisar descobrir IP nenhum.
resource "docker_network" "mesh" {
  name   = "${var.prefixo}-rede"
  driver = "bridge"

  labels {
    label = "projeto"
    value = "otp-mesh"
  }
}

# ---------------------------------------------------------------- NATS
#
# Imagem pública, versão fixada. `nats` é Apache-2.0; o Redpanda, que resolveria
# o mesmo problema, é BUSL -- mesma armadilha do Terraform.
resource "docker_image" "nats" {
  name = "nats:${var.nats_version}-alpine"

  # Mantem a imagem ao destruir: baixar de novo a cada ciclo de teste e
  # desperdicio de rede, e a imagem nao e um recurso que este modulo "criou".
  keep_locally = true
}

resource "docker_container" "nats" {
  name  = "${var.prefixo}-nats"
  image = docker_image.nats.image_id

  # `-m 8222` liga o endpoint de monitoramento, que o tests/smoke.sh consulta
  # em /varz para confirmar que o NATS esta de pe.
  command = ["-m", "8222", "-js"]

  networks_advanced {
    name = docker_network.mesh.name
    # Apelido explicito: e por este nome que o gateway o encontra.
    aliases = ["nats"]
  }

  ports {
    internal = 4222
    external = var.porta_nats
  }

  ports {
    internal = 8222
    external = var.porta_nats_monitor
  }

  restart = "unless-stopped"

  healthcheck {
    # O NATS alpine nao tem curl nem wget; o proprio binario responde.
    test     = ["CMD-SHELL", "wget -q -O- http://127.0.0.1:8222/healthz || exit 1"]
    interval = "5s"
    timeout  = "3s"
    retries  = 5
  }
}

# ---------------------------------------------------------------- gateway
#
# Construido do codigo deste repositorio, nao de uma imagem publicada. O
# contexto de build e ../go, que contem o Dockerfile de dois estagios.
resource "docker_image" "gateway" {
  name = "${var.prefixo}-gateway:${var.tag_gateway}"

  build {
    context = "${path.module}/../go"
    label = {
      projeto = "otp-mesh"
    }
  }

  # `triggers` forca reconstrucao quando o codigo muda. Sem isto, o tofu
  # consideraria a imagem inalterada e aplicaria uma versao velha do gateway --
  # o tipo de erro que custa uma hora de depuracao do bug errado.
  triggers = {
    fonte = sha1(join("", [
      for f in fileset("${path.module}/../go", "**/*.{go,mod}") :
      filesha1("${path.module}/../go/${f}")
    ]))
  }
}

resource "docker_container" "gateway" {
  name  = "${var.prefixo}-gateway"
  image = docker_image.gateway.image_id

  # Sem `-core`: o gateway roda sem o nucleo em Elixir e reporta
  # `nucleo_ligado: false` em /stats. A degradacao e visivel de proposito --
  # mesmo padrao do NIF opcional e do codec em Elixir.
  command = [
    "-addr", "0.0.0.0:8080",
    "-quiet",
    "-read-buf", tostring(var.buffer_bytes),
    "-write-buf", tostring(var.buffer_bytes),
  ]

  networks_advanced {
    name    = docker_network.mesh.name
    aliases = ["gateway"]
  }

  ports {
    internal = 8080
    external = var.porta_gateway
  }

  restart = "unless-stopped"

  # A dependencia da rede e implicita (o bloco acima usa o nome dela). A do
  # NATS nao existe hoje: o gateway sobe sem nucleo e sem fila. Declarar
  # `depends_on` aqui seria mentir sobre o acoplamento -- e e justamente o tipo
  # de dependencia inventada que deixa um apply mais lento sem motivo.
}
