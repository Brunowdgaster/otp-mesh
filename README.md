# otp-mesh — 700 mil processos supervisionados, medidos num notebook

Núcleo de uma plataforma de presença em Elixir/OTP: um processo BEAM por
conexão, registro particionado, contrapressão por descarte e uma árvore de
supervisão que sobrevive a matar 30% das conexões de uma vez.

Mais um gateway WebSocket em Go, sem dependências, que responde a pergunta
seguinte: **um socket de verdade custa 7,1 KB por conexão contra 3,8 KB do
processo BEAM — 1,9x**, e não as ordens de grandeza do folclore.

Projeto 03 de 14 de um portfólio poliglota — índice em
[Brunowdgaster/poliglota](https://github.com/Brunowdgaster/poliglota).

```
=== Capacidade: um processo BEAM por conexão ===

conexões      abrir (ms)   BEAM (MB)  bytes/conn  broadcast (ms)
----------------------------------------------------------------
100000              1792       335.1        3514             228
200000              3896       672.5        3526             930
500000              4343      1711.9        3590            1147
700000              8712      2359.8        3534            2761

=== Caos com 700000 conexões abertas ===
  mortas                : 210000 de 700000
  vivas depois          : 490000  (esperado 490000)
  convergência          : 8914 ms
  supervisor sobreviveu : true
  Stats reiniciou em    : 5.83 ms
  contagem após reinício: 490000 (relida do Registry)
```

> **Status:** o **núcleo em Elixir/OTP e o gateway em Go estão completos e
> medidos**, mas ainda **não se falam** — a ponte entre os dois é a próxima
> etapa, e o README não finge o contrário. As outras sete linguagens previstas
> no plano (Erlang, Gleam, Rust, Scala, Clojure, HCL, YAML) ainda não foram
> integradas; o ambiente delas está instalado e verificado, ver
> [Estado atual](#estado-atual).

## Objetivo

A pergunta é velha e quase sempre respondida com folclore: **quantas conexões
simultâneas um processo por conexão aguenta?** Em runtime de threads do SO a
resposta é "alguns milhares, e o escalonador sofre". Na BEAM dizem "milhões",
normalmente sem número.

Este projeto responde com medição, numa máquina ruim de propósito — um
notebook com WSL2 enxergando 3,8 GB — e separa as três coisas que a pergunta
embute:

| pergunta | como é respondida |
|---|---|
| Quanto custa **um processo por conexão**? | rampa de 1 mil a 700 mil, medindo bytes por conexão |
| A **árvore de supervisão** aguenta falha em massa? | matar 30% das conexões e medir convergência e sobrevivência do supervisor |
| O que acontece quando o consumidor **não dá conta**? | contrapressão por descarte, com a perda contabilizada |

## Resultado

### 700 mil conexões, 3.534 bytes cada

A rampa parou em 700 mil porque o limite de memória do benchmark (2 GB) foi
atingido — não por falha, não por saturação de CPU. Os 8 escalonadores ficaram
longe do limite durante todo o teste: **o gargalo é RAM.**

O custo por conexão ficou estável em torno de **3,5 KB** em toda a faixa, de
mil a 700 mil, o que diz algo importante: não há degradação superlinear. Isso
inclui o processo, o estado do `GenServer` e a entrada no `Registry`.

### A correção honesta do plano original

O plano do portfólio dizia "**milhões** de conexões simuladas". Medido:

| | |
|---|---|
| medido nesta máquina | **700.000** |
| 1 milhão exigiria | ~3,3 GB só de processos BEAM |
| orçamento do WSL2 aqui | 3,8 GB **no total** |

Ou seja: a meta original errou por um fator de ~1,4, não por ordens de
grandeza — e o que falta é **memória**, não arquitetura. Eu havia planejado
reduzir a meta para "~50 mil"; a máquina fez 14 vezes isso. A estimativa da
revisão de viabilidade era pessimista, e a medição corrigiu.

### O caos: a árvore aguenta

Com 700 mil conexões abertas, matando 210 mil de uma vez com
`Process.exit(pid, :kill)`:

- **O supervisor é o mesmo processo depois do massacre.** Não foi derrubado.
- A contagem converge para exatamente 490.000 — o `Registry` limpa cada entrada
  ao receber o `:DOWN` do processo morto, e isso levou 8,9 s para 210 mil.
- O `Mesh.Stats`, que é `:permanent`, foi morto separadamente e **voltou em
  5,83 ms com a contagem correta** — porque a contagem é *relida do Registry*,
  não restaurada de um backup.

### O erro de OTP que este projeto existe para não cometer

Conexões são **`restart: :temporary`**, e essa é a decisão central.

Supervisionar conexão como `:permanent` é o erro clássico: a BEAM permite, o
teste com dez conexões passa, e aí um pico de desconexões estoura
`max_restarts`/`max_seconds` e **o supervisor derruba a árvore inteira**,
levando as conexões que estavam saudáveis. O sintoma em produção é um apagão
total disparado por uma falha parcial.

Conexão caída não deve reiniciar — o cliente reconecta, e o estado antigo não
vale mais. O que reinicia é o processo cujo estado é **reconstruível** de outra
fonte, e é por isso que `Mesh.Stats` é `:permanent` e lê a contagem do
`Registry`.

Os dois casos estão em teste, não em prosa: `test/mesh_test.exs` verifica que
matar 30% não altera o pid do supervisor, e que o `Stats` volta com a contagem
certa.

### A contrapressão descarta, e conta o que descartou

Cada conexão mede a **própria** caixa de mensagens antes de aceitar trabalho.
Passando de 100 mensagens enfileiradas, descarta e contabiliza.

É contrapressão por descarte, não por bloqueio, e a escolha é deliberada:
bloquear o produtor num *fanout* propaga a lentidão de **um** consumidor para
**todos**. O teste despeja 5.000 mensagens de uma vez numa conexão e verifica a
invariante que importa:

```
aceitas + descartadas == enviadas
```

Nenhuma mensagem desaparece em silêncio. Um número de descartes é informação;
uma latência que cresce sem ninguém ver, não é.

### O gargalo da difusão, e a correção medida

Difundir para 700 mil conexões levava **2,7 s**, contra 228 ms para 100 mil:
crescimento pior que linear, porque um único processo emitindo 700 mil `cast` é
serial por definição.

A correção veio da própria biblioteca padrão. `Registry.dispatch/4` com
`parallel: true` invoca o callback **uma vez por partição, em processos
distintos** — ou seja, o fanout particionado já estava pronto, e eu o estava
reimplementando serialmente. O custo é um segundo registro, com chaves
duplicadas, servindo de tópico.

Três implementações, medidas **intercaladas** na mesma sessão, melhor de 5:

| conexões | serial | lotes | partição | ganho lotes | ganho partição | disp. |
|---|---|---|---|---|---|---|
| 10.000 | 16,9 ms | 23,3 ms | **5,1 ms** | 0,73x | 3,31x | 45 % |
| 50.000 | 148,9 ms | 80,3 ms | **51,3 ms** | 1,85x | 2,90x | 78 % |
| 100.000 | 225,4 ms | 80,5 ms | **66,6 ms** | 2,80x | 3,38x | 107 % |
| 200.000 | 530,9 ms | 176,0 ms | **142,5 ms** | 3,02x | 3,73x | 93 % |

- **serial** — um processo percorre tudo e emite cada `cast`.
- **lotes** — `Task.async_stream` sobre o registro **já existente**, sem
  segundo registro.
- **partição** — `Registry.dispatch` com `parallel: true`.

A dispersão é da ordem do ganho, então **o multiplicador exato não está
estabelecido** — lição que o P01 ensinou. O que está: a ordenação é a mesma nos
quatro degraus, e as duas versões paralelas melhoram conforme a escala cresce,
que é o que o mecanismo prevê (o custo fixo de criar processos se amortiza). A
versão em lotes chega a **perder** da serial em 10 mil conexões, onde o
overhead do `Task.async_stream` domina.

### A medição de memória que eu errei primeiro

O segundo registro custa memória, e a primeira medição disse **+72% por
conexão** — o que derrubaria a capacidade de 700 mil para ~400 mil e tornaria a
troca questionável.

O número estava errado. Ele vinha de `:erlang.memory/1` chamado no fim do
benchmark de difusão, **depois de milhões de mensagens em voo**: contava o lixo
do próprio benchmark, não o custo do registro.

A comparação limpa é rodar o mesmo `bench/capacity.exs` nas duas versões, que
não difunde em volume:

| | sem registro de difusão | com |
|---|---|---|
| bytes por conexão a 700 mil | 3.534 | **3.783** |
| BEAM total | 2.359 MB | 2.526 MB |

**+249 bytes por conexão, +7%** — e a capacidade máxima não muda na prática.
Sete por cento de memória compra ~3x de velocidade de difusão, então
`broadcast/1` particionado passou a ser o padrão. A versão em lotes fica como
alternativa sem custo de registro, e como a referência que estabeleceu o
número.

*Lição, de novo:* o instrumento de medição precisa ser verificado como o
sistema. `:erlang.memory/1` é correto; chamá-lo no lugar errado não é.

### O gateway em Go: quanto custa um socket de verdade

O núcleo mediu 3,8 KB por conexão — mas aquelas conexões são processos BEAM
**sem socket**. A pergunta seguinte é quanto uma conexão real custa, e a
resposta exigiu um gateway WebSocket, que é a segunda linguagem do projeto.

Medido no gateway em Go, uma goroutine por conexão, buffers de 1 KiB:

| conexões | goroutines | heap | pilhas | RSS | bytes/conexão |
|---|---|---|---|---|---|
| 1.000 | 1.003 | 4,2 MB | 3,5 MB | 18,6 MB | 12.333 |
| 5.000 | 5.003 | 24,0 MB | 10,4 MB | 44,3 MB | 7.865 |
| 10.000 | 10.003 | 35,5 MB | 21,0 MB | 78,8 MB | 7.542 |
| 25.000 | 25.003 | 129,4 MB | 49,6 MB | 176,8 MB | **7.130** |

**Um socket real custa ~7,1 KB, contra 3,8 KB do processo BEAM: 1,9x.** Menos do
que eu esperava — e o custo *cai* conforme a escala cresce, porque o RSS base do
processo se amortiza.

As pilhas de goroutine dão ~2 KB cada (49,6 MB / 25.000), não os 8 KiB que se
costuma repetir: o Go começa com pilha pequena e cresce sob demanda.

### Por que escrevi o WebSocket à mão

`gorilla/websocket` e `coder/websocket` são boas, livres, e seriam a escolha
óbvia num produto. Aqui atrapalhariam: o custo por conexão é **dominado pelo
tamanho dos buffers**, e numa biblioteca eles são escolha dela.

Com os buffers explícitos em `ws.Config`, a medição existe:

| buffers (leitura/escrita) | RSS | bytes/conexão | vs 1 KiB |
|---|---|---|---|
| 512 B | 76,0 MB | 7.256 | −3 % |
| **1 KiB** (escolhido) | 78,4 MB | 7.507 | — |
| 4 KiB (padrão das bibliotecas) | 103,7 MB | 10.162 | **+35 %** |
| 16 KiB | 99,5 MB | 9.726 | +30 % |

Escolher 1 KiB em vez dos 4 KiB herdados economiza **35 % de memória por
conexão**. Em 25 mil conexões isso é a diferença entre 177 MB e 240 MB; em 500
mil, entre 3,5 GB e 4,8 GB — ou seja, entre caber e não caber.

**A anomalia na última linha é real e vale registrar:** 16 KiB saiu *abaixo* de
4 KiB, o que é fisicamente implausível. A causa não é ruído aleatório — é que
**RSS conta só páginas tocadas**. Um buffer de 16 KiB alocado e nunca
preenchido não aparece no RSS, então a métrica subestima buffers grandes e
ociosos. A medição honesta de buffer grande exigiria forçar tráfego que o
preencha, e está no roadmap.

### Os limites que aparecem antes da memória

Medir sockets em loopback esbarra em três tetos de kernel antes de esbarrar em
RAM, e ignorá-los produziria um número que parece capacidade e é limite de
configuração:

| limite | padrão aqui | efeito |
|---|---|---|
| descritores (`ulimit -n`) | 10.240 | para em 10 mil conexões |
| portas efêmeras | 32768–60999 | **~28 mil** — o cliente gasta uma por conexão |
| backlog de accept | `somaxconn` 4096, `syn_backlog` 256 | rampa rápida descarta SYN |

`bench/gateway.sh` ajusta os três, **registra os valores antigos e os
restaura** — são ajustes de kernel, não é educado deixá-los para trás. O teto de
portas efêmeras é o motivo de a medição parar em 25 mil e não em 700 mil: passar
disso exige mais de uma máquina, ou endereços de origem adicionais.

### O que o número NÃO inclui

Os **buffers de socket do kernel**. Eles não aparecem no heap do Go nem no RSS
do processo — são memória de kernel, contabilizada em slab — e no Linux partem
de ~2–4 KiB por socket, podendo crescer com a janela TCP.

A conta completa de uma conexão real é portanto maior que os 7,1 KB medidos.
Quanto maior depende de `sysctl`, e medir isso exige ler
`/proc/net/sockstat`: está no roadmap. Até lá, o número publicado é "7,1 KB no
espaço do processo", não "7,1 KB no sistema" — e a diferença está declarada
na própria saída de `/stats`.

## Ambiente: zero recursos pagos

Todas as 14 ferramentas são software livre, nenhuma exige conta, cartão ou
licença comercial. `bash setup.sh` provisiona e `bash tests/smoke.sh` prova que
cada toolchain **compila e executa** algo — 11/11, incluindo um cluster
Kubernetes de verdade.

Quatro escolhas foram feitas para evitar armadilha de licença, não só de custo:

| escolha | em vez de | motivo |
|---|---|---|
| **Docker Engine** (Apache-2.0) | Docker Desktop | o Desktop exige licença paga acima de certo porte de empresa |
| **OpenTofu** (MPL-2.0) | Terraform | em 2023 virou **BUSL**: *source-available*, não software livre |
| **NATS** (Apache-2.0, 15 MB) | Kafka (~1 GB de JVM) / Redpanda (BUSL) | cabe na RAM e é licença livre |
| **providers locais** | AWS / GCP / Azure / Oracle | todas pedem cartão **mesmo nas camadas gratuitas** |

Detalhes, versões e licenças em [docs/AMBIENTE.md](docs/AMBIENTE.md).

## Como rodar

```bash
bash setup.sh                  # provisiona (idempotente)
bash tests/smoke.sh all        # prova que o ambiente funciona: 11 verificações

cd elixir/mesh
mix test                       # 8 testes: ciclo de vida, caos, contrapressão
mix run bench/capacity.exs     # a rampa até 700 mil + caos + extrapolação
mix run bench/fanout.exs       # as três difusões, intercaladas

cd ../../go && go test ./...   # 7 testes do WebSocket, zero dependências
cd .. && bash bench/gateway.sh # custo de uma conexão real + efeito dos buffers
```

O benchmark para sozinho ao passar de 2 GB no BEAM. O limite é deliberado:
estourar a memória faria o OOM killer do Linux derrubar a VM do WSL inteira, e
um benchmark que mata o ambiente não é um benchmark.

## Arquitetura

```
  Mesh.Supervisor                     :one_for_one
  ├── Mesh.Registry                   particionado por escalonador, :unique
  ├── Mesh.Stats                      :permanent — estado reconstruível
  └── Mesh.ConnSupervisor             DynamicSupervisor
      ├── Mesh.Connection  :temporary — contrapressão própria
      ├── Mesh.Connection  :temporary
      └── ... 700.000
```

O gateway em Go fica ao lado, e por enquanto **não** está ligado ao núcleo:

```
  cliente WebSocket ──▶ gateway (Go)        │  núcleo (Elixir/OTP)
                        1 goroutine/conn    │  1 processo/conn
                        ~7,1 KB/conn        │  ~3,8 KB/conn
                        ws/ sem dependência │  Registry + supervisão
                                            │
                        a ponte entre os dois é a próxima etapa
```

Três decisões estruturais:

1. **`Registry` particionado**, uma tabela ETS por escalonador. Com uma
   partição só, o registro vira o gargalo de escrita antes de a memória acabar
   — centenas de milhares de processos registrando ao mesmo tempo disputam a
   mesma tabela.
2. **Conexões `:temporary`**, pelo motivo acima.
3. **Contrapressão decidida dentro do processo que sofre a pressão**, não no
   produtor: só a conexão sabe o tamanho real da própria fila.

## Linguagens e ferramentas

| Ferramenta | Onde é usada | Por que ela, e não outra | Alternativa descartada |
|---|---|---|---|
| **Go 1.26** | gateway WebSocket, gerador de carga | Uma goroutine por conexão é o par natural de um processo por conexão, e o `net/http` com `Hijacker` dá o socket cru sem intermediário. É também a comparação que o projeto quer: a plataforma onde "um por conexão" é barato **sem** supervisão nem isolamento de falha | **Node.js**: um laço de eventos, não um por conexão — mediria outra coisa. **Rust**: mais rápido e sem GC, mas `async` exige escolher runtime, e aí a medição seria do Tokio |
| **`ws/` escrito à mão** (zero dependências) | aperto de mão e quadros da RFC 6455 | O custo por conexão é dominado pelos buffers, e em biblioteca eles são escolha dela. Com `ws.Config` explícito, a tabela de efeito dos buffers existe — e ela mostra +35 % para o padrão herdado | **gorilla/websocket**, **coder/websocket**: ambas boas e livres; esconderiam justamente a variável sob medição |
| **Elixir / OTP 27** | o núcleo inteiro | A BEAM é a única plataforma mainstream em que um processo por conexão é a escolha *óbvia* e não um truque: processo de centenas de bytes, escalonador preemptivo por redução, e supervisão como parte da linguagem e não biblioteca. Medir 700 mil processos supervisionados em 2,3 GB não é possível em runtime de threads do SO | **Go**: goroutines são baratas, mas não há supervisão nem isolamento de falha — um `panic` não contido derruba o processo todo. Go entra no gateway HTTP, onde é melhor |
| **`Registry` particionado** | nomeação das conexões | Nomeação distribuída sem processo central: cada partição é uma tabela ETS, e o `Registry` monitora os processos para limpar sozinho quando morrem. É o que faz a convergência pós-caos ser automática | **GenServer com um `Map`**: um processo central vira gargalo e ponto único de falha, e perderia o estado ao reiniciar |
| **`DynamicSupervisor`** | ciclo de vida das conexões | Filhos criados em tempo de execução, sem lista estática. Suporta `:temporary`, que é o que evita a tempestade de reinícios | **`Supervisor` com lista estática**: não serve, as conexões não são conhecidas de antemão |
| **ExUnit** | 8 testes de propriedade do sistema | Cada teste corresponde a uma frase do README. Testar que "o supervisor sobrevive" exige matar processos de verdade e comparar pids — é o que impede o README de virar prosa | — |
| **OpenTofu** (MPL-2.0) | infraestrutura declarativa | Ver a tabela de licenças acima. Mesma HCL e mesmos providers do Terraform, sem a BUSL | **Terraform**: funciona e é gratuito, mas a licença deixou de ser livre em 2023 |
| **NATS** (Apache-2.0) | barramento entre nós (próxima etapa) | 15 MB de binário e licença livre, o que importa num orçamento de 3,8 GB. O porém está declarado: é *pub/sub* com JetStream opcional, não o log particionado do Kafka | **Kafka**: semântica melhor para log, ~1 GB de JVM. **Redpanda**: leve, mas BUSL |
| **kind** | Kubernetes local | Cluster real dentro do Docker, sem nuvem e sem cartão. Verificado no teste de fumaça: 1 nó `Ready` | **minikube**: equivalente; `kind` é mais leve por rodar o nó como contêiner |
| **Bash** | `setup.sh`, `tests/smoke.sh` | O ambiente tem 14 ferramentas de origens diferentes; provisionar e verificar isso é trabalho de shell | — |

## Decisões e trade-offs

### O mesmo erro de harness que o P01 teve

A primeira versão de `Mesh.Chaos.kill_fraction/1` devolvia
`{mortas, antes, depois}` e, quando o `Registry` não convergia no prazo,
entregava **a contagem parcial sem avisar**.

Com 700 mil conexões a convergência passou de 8 s contra um prazo fixo de 5 s,
e o benchmark imprimiu "210.000 mortas de 700.000, **610.523 vivas**" — um
número que não fecha, porque a limpeza ainda estava acontecendo. Eu só percebi
porque 700.000 − 210.000 não dá 610.523.

É exatamente o defeito que o harness de benchmark do
[P01](https://github.com/Brunowdgaster/metal-vm) tinha e que eu já havia
corrigido lá: **degradar em silêncio**. Hoje a função devolve
`{:ok, ...}` ou `{:timeout, ...}`, o prazo acompanha o tamanho do massacre, e o
benchmark imprime em letras garrafais que o número não vale quando não
converge.

*Lição que já estava escrita e eu repeti:* ferramenta de medição que entrega
número errado sem reclamar é pior que ferramenta quebrada, porque o número
**parece** certo.

### O bug de API que a instabilidade do teste revelou

O teste de ciclo de vida falhava em ~2 de 12 execuções, **sem depender de
semente**:

```
assert Mesh.count() == 0
left:  1
right: 0
```

A tentação é marcar como instável e acrescentar um `sleep`. A causa, porém,
estava na API: `DynamicSupervisor.terminate_child/2` devolve `:ok` assim que o
processo morre, mas o `Registry` só remove a entrada quando **ele** recebe o
`:DOWN` do monitor — o que é assíncrono. Então `Mesh.close/1` dizia "fechei"
enquanto `Mesh.count()` ainda incluía a conexão.

Isso é armadilha para quem chama, não peculiaridade aceitável. `close/1` agora
espera o desregistro antes de retornar, há um teste explícito para essa
propriedade, e 15 execuções seguidas passam.

A assimetria é deliberada: `Mesh.Chaos.kill_fraction/1` **não** espera do mesmo
jeito, porque lá o objetivo é justamente medir quanto a convergência leva sob
morte em massa.

*Lição:* teste instável é sintoma, e o primeiro palpite deve ser que o sistema
está errado — não o teste. Dois dos três bugs deste projeto apareceram assim.

### O terceiro caso de falha silenciosa, achado pelo CI

O `setup.sh` rodava `apt-get install -y -qq ... >/dev/null` **sem `apt-get
update` antes e sem checar o código de saída**. Numa máquina com as listas de
pacotes vazias — um runner de CI recém-criado — o install falha com "Unable to
locate package", o script imprime "instalando: ..." e segue como se tivesse
dado certo.

O primeiro CI deste repositório passou no passo de provisionamento e falhou no
teste de fumaça com `elixir: command not found`. O provisionador mentiu; o
verificador pegou.

É o **terceiro** caso do mesmo padrão neste portfólio: o harness de benchmark
do P01, o `kill_fraction` deste projeto e agora o provisionador. A forma é
sempre idêntica — redirecionar a saída e não olhar o código de retorno. Hoje o
script roda `update`, falha com mensagem, e **confere com `dpkg` o que de fato
ficou instalado** em vez de confiar no instalador.

É também a defesa do teste de fumaça existir: um `setup.sh` que se auto-declara
bem-sucedido não é verificação.

E, corrigido o silêncio, apareceu a causa de baixo: o script checava `dpkg -s
docker.io` e `dpkg -s golang-go`, mas o runner do GitHub **já tem** `docker` e
`go` por outros pacotes (`moby-engine` e o tarball oficial do Go), e o apt
recusava instalar os do Debian por cima — `pkgProblemResolver::Resolve
generated breaks`.

A correção é conceitual: **verificar a capacidade, não a identidade do
pacote**. O que importa é `docker` e `go` funcionarem, não qual pacote os
forneceu. Hoje o script checa `command -v` para cada ferramenta e só instala o
que falta — o que conserta o runner e vale para qualquer máquina que já tenha
as ferramentas por outro caminho.

### Por que o benchmark para em 2 GB

Não é timidez: é que o OOM killer do Linux, acionado por um benchmark, não mata
só o benchmark — mata a VM do WSL, levando a sessão de trabalho. O limite fica
no script e o motivo está no comentário dele.

### Descarte, não bloqueio

Bloquear o produtor é a contrapressão "correta" em teoria de filas, e é errada
aqui: num *fanout* para centenas de milhares de consumidores, o mais lento
passa a ditar o ritmo de todos. Descartar mantém o sistema previsível, e o
custo — perda de mensagem — fica **visível** no contador em vez de virar
latência silenciosa.

O que isso não resolve: não há política por cliente, nem prioridade, nem
reenvio. Para isso existiria JetStream (NATS) ou um log particionado, e é outra
etapa.

## Limites conhecidos

- **Só o núcleo em Elixir existe.** Erlang, Gleam, Go, Rust, Scala, Clojure,
  HCL e YAML estão no plano do projeto e **não** foram integrados. O ambiente
  deles está instalado e verificado, o que é diferente de estar em uso.
- **Nó único.** Não há distribuição BEAM, nem particionamento entre nós, nem
  `Horde`/`libcluster`. Toda a medição é de um processo `beam.smp`.
- **A difusão melhorou ~3x mas segue não escalando de graça.** 142 ms para
  200 mil conexões com oito escalonadores; a próxima barreira é a emissão de
  `cast` em si, que é uma mensagem por destino. Reduzir isso exigiria agrupar
  destinatários por nó ou trocar difusão por *pull*, o que muda a semântica.
- **O gateway e o núcleo ainda não se falam.** O gateway em Go aceita
  WebSocket de verdade e está medido, mas não cria `Mesh.Connection` do outro
  lado: a ponte entre os dois é a próxima etapa. Até ela existir, são dois
  resultados independentes, e o README não finge o contrário.
- **As conexões do núcleo são simuladas.** Não há socket nos 700 mil: são
  processos com estado, que é o que aquela medição quer isolar. O custo do
  socket real está medido separadamente, no gateway.
- **O gateway não valida máscara de cliente.** A RFC 6455 §5.3 exige que o
  cliente mascare os quadros; o servidor aceita sem máscara. Há teste
  registrando a lacuna em vez de deixá-la implícita.
- **Sem ping/pong com prazo no gateway.** As conexões ficam ociosas de
  propósito, que é o cenário de presença; um gateway de produção derrubaria
  conexão morta por timeout.
- **Contadores de observação são perdidos no reinício** do `Mesh.Stats`. É
  declarado, não um bug: preservá-los exigiria escrita em disco no caminho
  quente para proteger um número que serve ao operador.
- **O orçamento é 3,8 GB, não 7,9 GB.** O WSL2 vê metade da RAM do host por
  padrão. Um `.wslconfig` com `memory=6GB` levantaria o teto, ao custo de
  deixar ~2 GB para o Windows — e **não** foi feito, porque é decisão de quem
  usa a máquina e exige `wsl --shutdown`.

## Roadmap

1. ~~**Fanout particionado**~~ **Feito.** ~3x medido, três implementações
   comparadas, custo de memória estabelecido em +7% por conexão.
2. ~~**Gateway em Go** com WebSocket real~~ **Feito.** ~7,1 KB por conexão
   contra 3,8 KB do processo BEAM, e o efeito do tamanho dos buffers medido.
3. **A ponte gateway ↔ núcleo**, para que um WebSocket real crie um
   `Mesh.Connection` do outro lado.
4. **Buffers de kernel por socket**, via `/proc/net/sockstat`, para fechar a
   conta de memória de uma conexão real.
3. **Supervisão em Erlang puro** do mesmo núcleo, para a comparação que o
   projeto promete: a mesma árvore em Elixir e em Erlang, lado a lado.
4. **Serviço em Gleam** na mesma BEAM, para mostrar tipagem estática sobre o
   mesmo runtime.
5. **Caminho crítico em Rust** via NIF, medindo o custo da travessia.
6. **Distribuição** com dois nós BEAM e `Registry` global.
7. **NATS** como barramento entre nós.
8. **OpenTofu + kind**: o cluster e os serviços provisionados por HCL, com
   providers locais.
9. **Processamento de stream** em Scala e Clojure sobre o barramento.

## Aprendizados

- **A BEAM entrega o que promete, e dá para medir.** 700 mil processos
  supervisionados em 2,3 GB, com custo por conexão estável em toda a faixa. O
  número que eu mesmo tinha estimado na revisão de viabilidade — "~50 mil" —
  estava 14 vezes abaixo.
- **O gargalo não foi onde eu esperava.** Previ RAM e escalonador; a RAM
  confirmou, o escalonador nunca apareceu, e o gargalo real foi a **difusão de
  um processo só**, que nenhuma das minhas previsões mencionava.
- **Repeti um erro que eu já havia corrigido em outro projeto.** O harness
  devolvia medição não convergida em silêncio, como o do P01. Saber que um
  modo de falha existe não impede de reintroduzi-lo — o que impede é a
  ferramenta reclamar.
- **Um socket real custa menos do que eu esperava: 1,9x um processo BEAM.** O
  folclore diz "milhares contra milhões"; medido, a diferença entre uma
  goroutine com socket e um processo sem socket é 7,1 KB contra 3,8 KB. O que
  separa as duas plataformas em escala não é o custo por conexão — é
  supervisão, isolamento de falha e o que acontece quando um deles morre.
- **Escrever a camada de protocolo pagou pela medição.** Buffer de 1 KiB em vez
  dos 4 KiB herdados economiza 35 % por conexão. Com uma biblioteca, esse
  número não existiria, porque a escolha não teria sido minha.
- **O instrumento tem viés, e o viés aparece como anomalia.** O degrau de
  16 KiB saiu abaixo do de 4 KiB porque RSS conta só páginas tocadas: buffer
  grande e ocioso é invisível. Uma anomalia implausível na tabela é informação
  sobre a métrica, não sujeira para arredondar.
- **A biblioteca padrão já tinha a resposta.** Eu estava reimplementando
  serialmente um fanout que o `Registry.dispatch/4` faz particionado desde
  sempre. Antes de otimizar, vale ler o que a plataforma oferece — e a BEAM
  oferece muito.
- **Errei a medição de memória antes de errar a de tempo.** Reportei +72% de
  custo por conexão porque chamei `:erlang.memory/1` depois de milhões de
  mensagens em voo. O instrumento estava certo; o lugar da chamada, errado. A
  comparação limpa deu +7%, e a decisão de engenharia mudou com ela.
- **Três vezes o mesmo modo de falha, em três projetos.** Harness de benchmark,
  injetor de caos e provisionador: todos redirecionavam a saída e ignoravam o
  código de retorno. Conhecer um modo de falha não imuniza contra ele; o que
  imuniza é a ferramenta reclamar alto.
- **Teste instável é sintoma, não ruído.** A falha intermitente de ~2 em 12
  execuções era um bug de API: `close/1` retornava antes de o `Registry`
  convergir. Acrescentar um `sleep` no teste teria escondido o problema para
  todo mundo que fosse usar a biblioteca.
- **`:temporary` contra `:permanent` é a decisão que separa quem leu OTP de
  quem usou.** Os dois funcionam em teste pequeno; só um sobrevive a um pico de
  desconexões.
- **Licença é restrição de engenharia, não detalhe jurídico.** Terraform e
  Redpanda são gratuitos para este uso e nenhum dos dois é software livre;
  trocar por OpenTofu e NATS custou nada e removeu a ambiguidade.

## Estado atual

| Parte | Estado |
|---|---|
| Ambiente livre, 14 ferramentas | ✅ `setup.sh` + 11/11 no teste de fumaça |
| Árvore de supervisão (Registry + DynamicSupervisor + Stats) | ✅ |
| Conexão como processo, com contrapressão | ✅ |
| Caos: matar fração das conexões | ✅ supervisor sobrevive, convergência medida |
| Caos: matar processo `:permanent` | ✅ reinício em 5,83 ms, estado reconstruído |
| Suíte ExUnit | ✅ 10/10, estável em 15 execuções seguidas |
| Benchmark de capacidade | ✅ 700 mil conexões, 3.783 bytes cada |
| Benchmark de difusão, 3 implementações | ✅ intercalado, com dispersão reportada |
| Fanout particionado | ✅ ~3x medido; +7% de memória por conexão |
| Gateway em Go, WebSocket real | ✅ zero dependências, 7 testes, ~7,1 KB/conn |
| Efeito do tamanho dos buffers | ✅ +35 % com o padrão das bibliotecas |
| Ponte gateway ↔ núcleo | ⬜ |
| Erlang, Gleam, Rust, Scala, Clojure | ⬜ ambiente pronto, não integrados |
| Distribuição entre nós | ⬜ |
| NATS, OpenTofu, kind em uso | ⬜ instalados e verificados, não integrados |
| CI | ⬜ |

## Licença

MIT.
