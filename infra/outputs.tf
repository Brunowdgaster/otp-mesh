# Saídas: os endereços que os benchmarks e os testes consomem.
#
# Por que isso vale: quem roda o benchmark não precisa saber como a
# infraestrutura foi montada, só onde ela responde. `tofu output -json`
# alimenta um script sem que o script tenha de adivinhar portas.

output "gateway_ws" {
  description = "Endereço WebSocket do gateway."
  value       = "ws://127.0.0.1:${var.porta_gateway}/ws"
}

output "gateway_stats" {
  description = "Endpoint de métricas do gateway, consumido por bench/gateway.sh."
  value       = "http://127.0.0.1:${var.porta_gateway}/stats"
}

output "nats_url" {
  description = "URL do NATS."
  value       = "nats://127.0.0.1:${var.porta_nats}"
}

output "nats_monitor" {
  description = "Monitoramento do NATS, consumido por tests/smoke.sh."
  value       = "http://127.0.0.1:${var.porta_nats_monitor}/varz"
}

output "buffer_bytes" {
  description = "Buffer por conexão de fato aplicado, para o relatório do benchmark registrar."
  value       = var.buffer_bytes
}

output "rede" {
  description = "Nome da rede Docker, para anexar contêineres de carga."
  value       = docker_network.mesh.name
}
