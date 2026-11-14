# Gateway WebSocket em Go, em dois estágios.
#
# O estágio final é `scratch`: nenhum sistema operacional, nenhum shell,
# nenhuma biblioteca compartilhada. Isso é possível porque o projeto não tem
# dependência externa alguma e o binário é estático.
#
# Por que isso importa para a medição: a imagem contém o binário e nada mais,
# então o RSS do contêiner é o do gateway. Numa imagem com distro por baixo, o
# número de "memória por conexão" viria contaminado pelo que mais estiver
# rodando ali.

FROM golang:1.26-alpine AS build

WORKDIR /src
COPY go.mod ./
COPY ws/ ws/
COPY bridge/ bridge/
COPY cmd/ cmd/

# CGO_ENABLED=0 garante binário estático: sem ele o Go liga contra a libc do
# Alpine e o `scratch` abaixo não teria o loader para executá-lo.
# -trimpath remove caminhos da máquina de build, tornando a imagem reproduzível.
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" \
      -o /gateway ./cmd/gateway

FROM scratch

COPY --from=build /gateway /gateway

# 8080: WebSocket e /stats. Documentado na imagem para quem inspecionar.
EXPOSE 8080

# Escuta em 0.0.0.0 e não em 127.0.0.1: dentro do contêiner, o padrão do
# binário só aceitaria conexões de dentro dele mesmo.
ENTRYPOINT ["/gateway"]
CMD ["-addr", "0.0.0.0:8080", "-quiet"]
