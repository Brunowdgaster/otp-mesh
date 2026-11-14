# Variáveis da infraestrutura.
#
# Cada uma tem `description` e `type`, e as de porta têm validação. Isso não é
# cerimônia: `tofu plan` recusa um valor inválido ANTES de criar recurso
# nenhum, e a mensagem diz qual variável e por quê. Um script shell com
# `${PORTA:-8080}` descobre o problema quando o bind falha, já no meio.

variable "docker_host" {
  description = "Socket do daemon Docker."
  type        = string
  default     = "unix:///var/run/docker.sock"
}

variable "prefixo" {
  description = "Prefixo dos nomes dos recursos, para não colidir com outros projetos na mesma máquina."
  type        = string
  default     = "otpmesh"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.prefixo))
    error_message = "O prefixo deve ser minúsculo, começar com letra e ter até 21 caracteres."
  }
}

variable "nats_version" {
  description = "Versão do NATS. Fixada de propósito: `latest` torna o ambiente irreprodutível."
  type        = string
  default     = "2.10"
}

variable "tag_gateway" {
  description = "Tag da imagem do gateway construída deste repositório."
  type        = string
  default     = "local"
}

variable "porta_gateway" {
  description = "Porta do host para o gateway (WebSocket e /stats)."
  type        = number
  default     = 8080

  validation {
    condition     = var.porta_gateway > 1024 && var.porta_gateway < 65536
    error_message = "A porta deve estar entre 1025 e 65535; abaixo de 1024 exigiria root."
  }
}

variable "porta_nats" {
  description = "Porta do host para o NATS."
  type        = number
  default     = 4222

  validation {
    condition     = var.porta_nats > 1024 && var.porta_nats < 65536
    error_message = "A porta deve estar entre 1025 e 65535."
  }
}

variable "porta_nats_monitor" {
  description = "Porta do host para o endpoint de monitoramento do NATS (/varz, /healthz)."
  type        = number
  default     = 8222

  validation {
    condition     = var.porta_nats_monitor > 1024 && var.porta_nats_monitor < 65536
    error_message = "A porta deve estar entre 1025 e 65535."
  }
}

variable "buffer_bytes" {
  description = <<-TXT
    Buffers de leitura e escrita por conexão, em bytes.

    É a variável medida do projeto: o gateway usa 1 KiB por padrão, contra os
    4 KiB típicos das bibliotecas de WebSocket, e é daí que vêm os 7,1 KiB por
    conexão medidos no README. Expor isso aqui permite reproduzir a medição com
    outros valores sem recompilar.
  TXT
  type        = number
  default     = 1024

  validation {
    condition     = var.buffer_bytes >= 128 && var.buffer_bytes <= 65536
    error_message = "Buffer entre 128 B e 64 KiB; abaixo disso o handshake não cabe."
  }
}
