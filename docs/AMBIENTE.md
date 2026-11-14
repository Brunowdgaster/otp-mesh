# Ambiente do P03: zero recursos pagos

Provisionado por `bash setup.sh` e verificado por `bash tests/smoke.sh`.
**Nenhuma ferramenta abaixo exige conta, cartão de crédito ou licença
comercial.**

## O que está instalado, e sob que licença

| Ferramenta | Versão | Licença | Origem |
|---|---|---|---|
| Erlang/OTP | 27 | Apache-2.0 | apt (Ubuntu) |
| Elixir | 1.18.3 | Apache-2.0 | apt |
| rebar3 | 3.26.0 | Apache-2.0 | apt |
| Gleam | 1.19.2 | Apache-2.0 | release oficial |
| Go | 1.26.8 | BSD-3-Clause | apt |
| Rust | 1.93.1 | MIT / Apache-2.0 | apt |
| OpenJDK | 25.0.5 | GPL-2.0 **com Classpath Exception** | apt |
| Scala CLI | 1.19.0 | Apache-2.0 | release oficial |
| Clojure | 1.12.0 | EPL-1.0 | apt |
| Docker Engine | 29.1.3 | Apache-2.0 | apt |
| kind | 0.33.0 | Apache-2.0 | release oficial |
| kubectl | 1.37.2 | Apache-2.0 | dl.k8s.io |
| OpenTofu | 1.13.9 | **MPL-2.0** | release oficial |
| NATS Server | 2.15.3 | Apache-2.0 | release oficial |

Nada vem de PPA de terceiros, nada vem de script `curl | bash`, e os binários
que não estão no apt vêm dos *releases* oficiais dos próprios projetos, pela
API pública do GitHub — **sem token, sem login**.

## Quatro escolhas que existem para evitar armadilha de licença ou de custo

Em cada uma havia a opção "padrão de mercado" com algum porém. A escolha e o
porém estão aqui porque, num projeto que se propõe honesto, a decisão de
engenharia vale mais que a ferramenta.

### 1. Docker **Engine**, não Docker Desktop

O Docker Desktop exige licença paga para empresas acima de um certo porte. O
Docker **Engine** é Apache-2.0 e roda nativamente no WSL2 — `systemd` é PID 1 e
o `cgroup v2` está montado, que são os dois pré-requisitos.

Efeito colateral bom: nada de VM intermediária, então o consumo de RAM cai —
que importa muito numa máquina de 8 GB.

### 2. **OpenTofu**, não Terraform

Em 2023 a HashiCorp trocou a licença do Terraform de MPL-2.0 para a **BUSL**,
que é *source-available* e não software livre: proíbe uso competitivo e tem
cláusula de conversão em quatro anos. Para este projeto o uso seria permitido,
mas a armadilha é de princípio, não de custo.

O **OpenTofu** é o fork sob a Linux Foundation, **MPL-2.0**, que mantém a
linguagem HCL e os mesmos *providers*. O código `.tf` deste projeto roda nos
dois; o CI usa o OpenTofu.

### 3. **NATS**, não Kafka nem Redpanda

| opção | licença | RAM | porém |
|---|---|---|---|
| Apache Kafka | Apache-2.0 | ~1 GB (JVM) | pesado para 8 GB com o resto rodando |
| Redpanda | BUSL | ~250 MB | *source-available*, mesma armadilha do Terraform |
| **NATS** | **Apache-2.0** | **~15 MB** | sem log particionado e persistente como o do Kafka |

NATS é projeto graduado da CNCF, Apache-2.0, e o binário tem 15 MB. O porém é
real e está declarado: o modelo dele é *pub/sub* com JetStream opcional, não o
log particionado do Kafka. Onde o projeto precisar de semântica de log, isso
será dito — e o Kafka pode entrar via Docker se a RAM permitir.

### 4. **Providers locais** no OpenTofu, não nuvem

Provisionar AWS, GCP, Azure ou Oracle **exige cartão de crédito mesmo nas
camadas gratuitas**. Então o HCL deste projeto usa os providers `docker`,
`kubernetes` (contra o cluster `kind`), `local` e `tls`.

É HCL real: estado, plano, módulos, `for_each`, variáveis, outputs e grafo de
dependências. O que não há é VM em datacenter — e o README dirá exatamente
isso, em vez de deixar implícito que houve provisionamento de nuvem.

## Verificação: instalar não é funcionar

`--version` responder não prova que o compilador acha a biblioteca padrão, que
o Docker tem cgroups ou que o `kind` consegue subir um nó. O
`tests/smoke.sh` **compila e executa** algo em cada toolchain:

```
$ bash tests/smoke.sh all

Linguagens: compilar e executar
  ok   erlang             42        <- spawn, send, receive: modelo de ator
  ok   elixir (OTP)       42        <- Supervisor + GenServer de verdade
  ok   gleam              42        <- compila na BEAM via rebar3
  ok   go (goroutine)     42        <- goroutine + canal
  ok   rust               42
  ok   clojure            42

Scala (baixa o compilador na primeira execução)
  ok   scala 3            42

Infraestrutura: container, cluster, fila e IaC
  ok   docker run         42        <- cgroups e rede dentro do WSL2
  ok   nats-server        subiu e responde no /varz
  ok   opentofu (HCL)     42        <- init + apply com provider local
  ok   kind (k8s)         1 no(s), 1 Ready   <- cluster Kubernetes real

11 passaram, 0 falharam
```

Os testes não são "hello world": o de Erlang faz `spawn`/`send`/`receive`, o de
Elixir sobe um `Supervisor` com um `GenServer` — se isso roda, o OTP está
inteiro, que é a premissa do projeto — e o de Go usa goroutine com canal.

Os estágios são separados (`langs`, `jvm`, `infra`) porque os custos são muito
diferentes: `langs` leva segundos, `jvm` baixa o compilador Scala na primeira
execução e `infra` sobe um cluster Kubernetes.

## Custo em RAM: a restrição real é menor do que parece

A máquina tem 7,9 GB. **O WSL2 vê 3,8 GB** — metade do host, que é o padrão
quando não existe `.wslconfig`. Medido:

```
$ free -h            # dentro do WSL
               total        used        free   available
Mem:           3.8Gi       631Mi       2.0Gi       3.2Gi
Swap:          1.0Gi
```

Isso não é detalhe: tudo do P03 roda no Linux, então o orçamento é **3,8 GB e
não 7,9 GB**. Com o `kind` consumindo ~1 GB e uma JVM ~300 MB, sobra pouco para
o nó BEAM e as conexões que ele deve sustentar.

| componente | RAM aproximada |
|---|---|
| `kind` com 1 nó | ~1 GB |
| JVM para Scala ou Clojure | ~300 MB por processo |
| Nó BEAM (Elixir) | ~50 MB + o que as conexões ocuparem |
| NATS | ~15 MB |

### Como aumentar, se você quiser

Criar o arquivo `.wslconfig` na pasta do seu usuário no Windows:

```ini
[wsl2]
memory=6GB
processors=8
swap=4GB
```

e então `wsl --shutdown` para aplicar. Isso deixa ~2 GB para o Windows, o que
pede fechar o navegador antes de rodar o `kind`.

**O `setup.sh` não cria esse arquivo**: mexer nisso derruba a sessão WSL e tira
RAM do Windows, então é decisão de quem usa a máquina, não do script.

Com os 3,8 GB atuais, as consequências para o projeto são duas, ambas
declaradas no README:

1. **um stack pesado por vez** — `kind` e JVM não convivem com folga;
2. a meta de escala do plano original ("milhões de conexões") foi substituída
   por um número que esta máquina consegue **medir**, com a aritmética de
   quanto faltaria para escalar.

## Reproduzir em outra máquina

```bash
bash setup.sh            # instala o que falta
bash setup.sh --check    # só verifica, não instala
bash tests/smoke.sh all  # prova que funciona
```

O script é idempotente e assume Ubuntu/Debian x86_64 com `systemd`. Em distro
diferente, os pacotes do passo 1 mudam de nome; os binários dos *releases*
oficiais funcionam em qualquer Linux glibc/musl x86_64.
