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

> **Status:** o **núcleo em Elixir/OTP, o gateway em Go e a ponte entre os
> dois** estão completos e medidos — 500 WebSockets reais viram 500 processos
> supervisionados, verificado por teste de integração no CI. As outras quatro
> linguagens previstas no plano (Clojure) e o HCL ainda não foram integradas;
> o ambiente delas está instalado e verificado, ver
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

### Erlang: a mesma conexão, no mesmo nó, com um byte de diferença

`mix` compila `src/*.erl` no mesmo app. Isso não é conveniência — é a
demonstração: `mesh_conn.erl` é uma implementação alternativa de conexão que
vive na **mesma árvore de supervisão**, usa o **mesmo `Registry`** e recebe a
**mesma difusão** que as conexões em Elixir.

Não há adaptador, porta nem camada de tradução. `Mesh.broadcast/1` faz `cast`
de `{:deliver, payload}` para o que estiver no tópico, e o módulo Erlang trata
`{deliver, Payload}` — o mesmo átomo, o mesmo bytecode.

Medido no mesmo nó, alternando as duas, melhor de 5:

| conexões | abrir ex | abrir erl | **bytes ex** | **bytes erl** | difusão ex | difusão erl |
|---|---|---|---|---|---|---|
| 10.000 | 206,9 ms | 236,8 ms | **3.304** | **3.305** | 27,8 ms | 15,2 ms |
| 50.000 | 975,9 ms | 938,2 ms | 3.499 | 3.305 | 49,0 ms | 52,5 ms |
| 100.000 | 2.693 ms | 2.517 ms | 3.547 | 3.338 | 193,1 ms | 99,9 ms |

**Um byte de diferença em 10 mil conexões.** E isso *é* o resultado, não a
ausência dele: confirma que Elixir e Erlang não são duas plataformas que
interoperam — são a mesma, e a escolha entre elas é de **ergonomia**, não de
desempenho.

Nos degraus maiores o Erlang aparece ~6 % abaixo em memória (3.338 contra
3.547), o que seria consistente com a camada fina que o `GenServer` do Elixir
acrescenta sobre o `gen_server` do Erlang. Mas 6 % com esta dispersão **não
está estabelecido** — e os tempos de abertura e difusão alternam de vencedor
sem padrão, que é o que se espera de ruído.

O caos vale para as duas: matar 30 % de 20 mil conexões Erlang converge e
deixa o supervisor intacto, exatamente como na versão em Elixir. `temporary` é
`temporary` nas duas linguagens.

#### O bug que custou cinco testes: módulo não é nome

```erlang
%% errado
via(Id) -> {via, 'Elixir.Mesh.Registry', {'Elixir.Mesh.Registry', Id}}.
%% certo
via(Id) -> {via, 'Elixir.Registry', {'Elixir.Mesh.Registry', Id}}.
```

No `{via, Modulo, Nome}`, o **módulo** é quem implementa o comportamento de
registro — `Registry` — e o **nome** é a instância — `Mesh.Registry`.
Conflatá-los dá `undef: Mesh.Registry.whereis_name/1`, porque `Mesh.Registry`
não é módulo: é só um átomo usado como nome de processo.

O erro é fácil em Elixir, onde os dois aparecem com a mesma cara. Em Erlang,
com o prefixo `'Elixir.'` explícito, a distinção fica visível — e foi
escrevendo a versão Erlang que ela ficou óbvia.

### Gleam: o mesmo protocolo, com os erros movidos para o compilador

O protocolo da ponte tem quatro implementações: Elixir (a fonte do formato), Go
(o gateway), Rust (a medição da travessia, abaixo) e **Gleam** — que existe para
mostrar o que a tipagem estática sobre a BEAM muda na forma de escrever a mesma
coisa.

Nas outras três, um quadro é um punhado de bytes com uma convenção na cabeça de
quem escreveu. Em Gleam, é um tipo:

```gleam
pub type Frame {
  Connect(client_id: Int)
  Disconnect(client_id: Int)
  Data(client_id: Int, payload: BitArray)
  Push(client_id: Int, payload: BitArray)
}

pub fn decode(bits: BitArray) -> Result(Frame, DecodeError)
```

Três erros deixam de ser possíveis:

| erro | Elixir / Go | Gleam |
|---|---|---|
| construir quadro sem `client_id` | roda e falha longe | não compila |
| esquecer de tratar o tipo 4 | quadro cai no `_ ->` em silêncio | `case` não exaustivo não compila |
| ignorar um quadro malformado | precisa de disciplina (e de teste) | `Result` obriga a tratar |

O terceiro é o mais interessante: o teste *"quadro malformado não derruba o
handler"* existe do lado Elixir **em tempo de execução**. Em Gleam, o
compilador não deixa chamar `decode` sem lidar com o `Error`. É o mesmo bug,
pego em dois momentos diferentes — e essa é a comparação que o projeto quer.

### Um protocolo, quatro linguagens, os mesmos bytes

O arquivo `protocolo/vetores.txt` tem 10 quadros em hexadecimal, gerados pelo
Elixir. **As quatro implementações são verificadas contra ele:**

| implementação | teste | o que verifica |
|---|---|---|
| Elixir | `test/protocolo_test.exs` | `frame/3` gera exatamente aqueles bytes |
| Go | `bridge/bridge_test.go` | `Encode`/`Decode` conformes |
| Gleam | `test/mesh_codec_test.gleam` | `encode`/`decode` conformes |
| Rust (NIF) | `test/nif_test.exs` | `encode`/`decode` conformes, e **iguais ao Elixir chamada por chamada** |

A quarta linha acrescenta uma verificação que as outras não podem fazer: como o
NIF roda no mesmo processo, o teste compara as duas implementações **lado a
lado, com os mesmos argumentos** — incluindo as fronteiras do campo de 64 bits
(0 e 2⁶⁴−1), onde errar o sinal ou o tamanho na travessia daria um id diferente
do enviado. O sintoma disso seria "conexão não encontrada" para um cliente que
existe.

Por que isso não é decorativo: **divergência de formato não dá exceção.** Um
lado escrevendo o id em little-endian e o outro em big-endian produz conexões
"não encontradas" para clientes que existem — um bug que aparece longe da
causa, e que os testes de unidade de cada lado passariam sem notar.

Os quatro testes começam verificando que **o arquivo foi lido e tem 10
linhas**.
Sem isso, um caminho errado faria os testes de conformidade iterarem sobre
lista vazia e passarem vacuamente — o jeito mais fácil de um teste de
conformidade não testar nada.

### Gleam não interopera com a BEAM: Gleam é BEAM

Ler o arquivo de vetores precisava de I/O, que a biblioteca padrão do Gleam
não tem — ela é agnóstica de plataforma. A saída não foi uma dependência:

```gleam
@external(erlang, "file", "read_file")
fn read_file(caminho: String) -> Result(BitArray, Dynamic)
```

Chamar `file:read_file/1` do OTP direto, e o `Result` do Gleam casa com o
`{ok, _} | {error, _}` do Erlang sem conversão, porque é a mesma
representação. Não é FFI, não é binding, não tem custo de travessia — é
chamada de função.

É o mesmo ponto que a conexão em Erlang faz do outro lado: três linguagens
(Elixir, Erlang, Gleam) sobre um runtime, sem camada de tradução entre elas.

E é o contraste exato com o NIF em Rust medido na seção seguinte: Gleam chamando
OTP custa uma chamada de função, enquanto Rust chamando a BEAM custa **~30 ns de
travessia**. "Rodar na mesma máquina virtual" e "ser chamável da máquina
virtual" são coisas diferentes, e a diferença tem preço.

### Rust via NIF: o conselho "escreve em Rust" medido

"Se está lento, escreve em Rust" é conselho dado sem número. O custo de um NIF
tem duas partes: a **travessia** (entrar no nativo, converter os termos, voltar)
e o **trabalho**. Se a travessia custa mais do que o Rust economiza, o NIF
perde.

Medido com o codec do protocolo implementado nas duas linguagens, 9 repetições
**alternadas** entre elas, mínimo de cada lado, **três execuções completas para
confirmar reprodutibilidade**.

#### A travessia, isolada

Uma função que soma 1 — todo o tempo acima do equivalente em Elixir é custo de
atravessar:

| | ns por chamada | entre as 3 execuções |
|---|---|---|
| Elixir | 14,1 | 14,1 – 14,3 |
| Rust (NIF) | 44,6 | 44,6 – 45,4 |
| **custo da travessia** | **~30 ns** | 30,4 / 30,5 / 31,3 |

Esse número reproduziu dentro de 3% em três execuções. É o resultado sólido
daqui.

#### O codec, variando o payload

A coluna `veredito` só se pronuncia quando a diferença **supera a dispersão
medida**. Quando não supera, ela diz `no ruído` — e isso é uma resposta, não uma
falha:

| payload | razão (Elixir/Rust) | veredito nas 3 execuções |
|---|---|---|
| vazio | 0,14 – 0,16x | Elixir (2 de 3; 1 no ruído) |
| 16 B | 0,15 – 0,18x | **Elixir, nas 3** |
| 64 B | 0,68 – 0,72x | **Elixir, nas 3** |
| 256 B | 0,66 – 0,69x | Elixir (2 de 3) |
| 1 KiB | 0,72 – 0,76x | Elixir (2 de 3) |
| 4 KiB | 0,71 – 0,73x | **Elixir, nas 3** |
| 16 KiB | 0,83 – 0,85x | Elixir (1 de 3), resto no ruído |
| 64 KiB | 0,93 – 0,99x | **no ruído, nas 3** |
| 256 KiB | 0,99 – 1,01x | **no ruído, nas 3** |
| 1 MiB | 0,93 – 0,94x | **no ruído, nas 3** |

Duas conclusões, com escopos diferentes:

**Até 4 KiB, o Elixir ganha e isso está estabelecido.** A razão fica entre 0,14x
e 0,76x, muito acima da dispersão. Em payload pequeno o NIF chega a ser **6x
mais lento**, porque a travessia é tudo o que existe.

**De 64 KiB para cima, não determinado.** A razão converge para ~0,95x e a
diferença cai **dentro do ruído desta máquina**. Dizer "Elixir ganha em 1 MiB"
seria inventar: as duas fazem o mesmo `memcpy` e a diferença deixa de ser
distinguível.

**O Rust não venceu acima do ruído em nenhum tamanho medido** — mas isso é
afirmação sobre esta carga, não sobre a linguagem.

#### Por que não ganha, mesmo em 1 MiB

Construir um binário concatenando três campos é **uma instrução da máquina
virtual**. A BEAM faz isso sem sair do runtime, e não há nada para o nativo
otimizar — só travessia a pagar. Em payload grande as duas implementações fazem
literalmente a mesma coisa, copiar bytes, e o Rust paga a travessia por cima.

O número para decidir: **~30 ns de travessia por chamada**, e ~200 ns quando a
chamada passa e devolve binários (conversão de termo mais alocação no heap de
binários da BEAM). **Qualquer função que faça menos trabalho que isso fica mais
lenta em Rust.**

NIF compensa quando o trabalho é *algoritmicamente* mais barato em nativo —
compressão, criptografia, parsing com SIMD — não quando é movimentação de dados.

#### A medição errou primeiro, do jeito que eu já sabia

A primeira versão deste benchmark media as 7 repetições do Elixir e **depois**
as 7 do Rust. Duas execuções seguidas deram conclusões **opostas**:

| execução | conclusão | travessia |
|---|---|---|
| 1 | "nenhum ponto de cruzamento" | 30,4 ns |
| 2 | "ponto de cruzamento em 64 B" | 66,5 ns |

É exatamente o erro que o [p01-metal-vm](https://github.com/Brunowdgaster/metal-vm)
documenta: medir A em bloco e B em bloco atribui a B qualquer deriva de
frequência que ocorra no meio. **Sexta vez** que a mesma classe de erro de
instrumentação aparece neste portfólio.

A correção tem quatro partes, e as quatro importaram:

1. **alternar A e B a cada repetição**, para que a deriva atinja os dois;
2. **reportar a dispersão** ao lado de cada número — a coluna mostra picos de
   120% a 240% nesta máquina, que ficavam invisíveis atrás do mínimo;
3. **aquecer** antes de medir e coletar lixo entre repetições, porque os
   binários produzidos são lixo e a coleta deles caía na medição seguinte;
4. **recusar-se a concluir** quando a margem não supera a dispersão. Um
   benchmark que sempre conclui algo é um benchmark que mente em máquina
   ruidosa.

Depois disso, as três execuções deram o mesmo veredito nas dez linhas.

#### A regra que não aparece em benchmark

Um NIF roda **no escalonador da BEAM**, não numa thread à parte. Bloquear por
mais de ~1 ms impede a preempção e destrói a latência de **todo o nó** — é o
jeito mais rápido de jogar fora as propriedades de tempo real da plataforma.

As funções aqui retornam em nanossegundos. Trabalho longo exigiria *dirty
schedulers* (`schedule = "DirtyCpu"`), e esta implementação deliberadamente não
os usa porque não precisa — está anotado no `lib.rs` para que ninguém copie o
código para um caso onde precisaria.

#### Compilação opcional, e duas armadilhas do mix

O NIF só compila com `MESH_BUILD_NIF=1`; sem isso, `Mesh.Nif` é um esqueleto e
`Mesh.Codec` usa a implementação em Elixir. O núcleo é o produto do projeto, o
NIF é uma medição — exigir `cargo` de quem roda `mix test` seria cobrar por algo
que a maioria não usa. Sem o NIF a suíte informa **"9 excluded"** em vez de
passar como se tivesse verificado algo.

**`use Rustler, skip_compilation?: true` ainda gera o `@on_load`.** Ele evita
chamar o `cargo`, mas o módulo continua tentando carregar o `.so` — que não
existe — e o aviso resultante derruba o `--warnings-as-errors` do CI. A solução
foi definir o módulo condicionalmente: sem a variável, não há `@on_load` para
falhar.

**`System.get_env` em tempo de compilação não é rastreado pelo mix.** Alternar a
variável não invalida o `.beam`, então `MESH_BUILD_NIF=1 mix compile` não
recompila nada e a função levanta `:nif_not_loaded` *com a variável definida*.
Tentei `Application.compile_env/3`, que o mix rastreia — e é pior: a validação
roda **antes** da compilação e **aborta** exigindo recompilação manual, em vez de
fazê-la. Ficou o `--force` explícito, documentado em "Como rodar".

### Scala e Loom: o número de memória era a parte menos interessante

O projeto mede **3.534 bytes por conexão** na BEAM, e esse número só significa
algo contra outra coisa. A JVM oferece duas respostas para "uma unidade de
concorrência bloqueada", e a segunda é o análogo direto do processo da BEAM:

| | o que é |
|---|---|
| **thread de plataforma** | uma thread do sistema operacional, com pilha própria reservada |
| **thread virtual** (Loom, JDK 21+) | multiplexada sobre poucas threads carregadoras, pilha no heap, crescendo sob demanda |

Loom promete a mesma coisa que a BEAM: *crie uma por conexão, bloquear é de
graça*. Esta seção mede se a promessa é a mesma.

#### Medindo o primitivo nu, pelo mesmo método

A comparação mais fácil de fazer errado aqui seria pôr os 3.534 bytes da conexão
ao lado dos bytes de uma thread virtual: a conexão é um GenServer com estado e
**duas** entradas de `Registry`, a thread virtual bloqueia numa fila e nada
mais. Estado diferente, custo diferente, comparação sem sentido.

Então `bench/processo_nu.exs` mede o **processo nu da BEAM** — `spawn` +
`receive`, nada mais — pelo mesmo método do lado da JVM: RSS lido de
`/proc/self/status` antes e depois, dividido pelo número de unidades.

**Por que RSS e não `:erlang.memory`:** porque é a única métrica que atravessa a
fronteira. `:erlang.memory` enxerga o heap da BEAM e **não enxerga** pilhas de
threads do sistema operacional — medir a JVM assim daria ~0 bytes por thread de
plataforma, que é exatamente a conclusão errada.

| primitivo | criados | **bytes por unidade (RSS)** | criação/s |
|---|---|---|---|
| thread de plataforma | **30.568, então OOM** | 23.502 | 702 |
| processo da BEAM | 700.000 | **2.732** | **122.079** |
| thread virtual (Loom) | 700.000 | **1.323** | 38.015 |

Três resultados, em ordem de surpresa:

**A thread de plataforma bate num muro em 30 mil**, com
`OutOfMemoryError: unable to create native thread`. Ela reservou **30 GiB** em
pilhas (30.568 × 1 MiB), **44,6x o RSS medido** — porque a pilha de 1 MiB é
mapeada preguiçosamente e a thread bloqueada toca poucas páginas. É o muro que
justifica Loom ter sido criado.

> Reportar só o RSS faria a thread de plataforma parecer barata; reportar só o
> reservado faria parecer catastrófica. O RSS é o número comparável com a BEAM;
> o reservado é o que esgota o espaço de endereçamento **antes** de a memória
> acabar. As duas colunas existem porque uma sozinha mente.

**A thread virtual é mais barata que o processo da BEAM** — 1.323 contra 2.732
bytes, quase a metade. Esse é o resultado que contraria o senso comum, e ele é
real.

**A BEAM cria 3,2x mais rápido** — 122 mil por segundo contra 38 mil.

#### Por que a thread virtual é mais barata: ela compra menos

Se a seção parasse na tabela acima, a conclusão seria "Loom ganhou". O
experimento seguinte é o que faltava.

Threads virtuais são escalonadas **cooperativamente**: cedem o carregador num
ponto de bloqueio (I/O, `sleep`, `lock`). Um laço que só calcula **não tem ponto
de cedência**. A BEAM escalona **preemptivamente por contagem de reduções**:
cada processo recebe um orçamento de ~4.000 reduções e é interrompido ao gastá-lo,
queira ou não.

Mesmo experimento nos dois: **4 unidades em laço fechado sobre 2
escalonadores**, medindo quanto uma unidade nova demora para rodar sua primeira
instrução.

| | sem carga | sob carga de CPU | degradação |
|---|---|---|---|
| **processo da BEAM** | 0,008 ms | **0,170 ms** | 21x |
| **thread virtual** | 0,318 ms | **≥ 10.000 ms** | **nunca rodou** |

A thread virtual **não rodou dentro do teto de 10 segundos**. Não é latência
alta: é inanição. Ela esperaria os laços terminarem.

Em um servidor, essa é a diferença entre *"uma requisição pesada deixa as outras
lentas"* e *"uma requisição pesada trava as outras"*.

E note a primeira coluna: sem carga nenhuma, a BEAM atende em 0,008 ms contra
0,318 ms — **40x mais rápido** para criar e escalonar uma unidade de
concorrência.

#### Sendo justo com Loom

Isto **não é defeito**: é a troca que Loom fez de propósito. Em carga
dominada por I/O — que é o caso de uso que Loom tem como alvo — toda operação de
rede é um ponto de cedência, e a inanição acima não acontece.

O problema aparece em carga **mista**: um endpoint que serializa um JSON grande,
comprime um relatório ou faz um laço de cálculo no meio de um serviço I/O-bound.
Na BEAM esse endpoint fica lento. Na JVM com threads virtuais, ele para os
vizinhos.

A afirmação honesta é esta: **os 1.323 bytes são mais baratos que os 2.732
porque não carregam escalonamento preemptivo, heap isolado por processo nem
supervisão.** O número de memória era a parte menos interessante da comparação.

#### Três detalhes de método que decidiram o resultado

**Um processo JVM por modo.** `Concorrencia.scala` mede um modo por execução.
Criar 30 mil threads de plataforma e então medir as virtuais no mesmo processo
mediria o heap já crescido, as páginas já faultadas e o GC já aquecido pelo
primeiro modo. É a mesma disciplina de `bench/capacity.exs`: o A/B limpo exige
processos separados, e a comparação é feita por quem os invoca.

**O tamanho da pilha é lido, não assumido.** `-XX:ThreadStackSize` é
configurável e o padrão varia por plataforma. Publicar "reservado = N × 1 MiB"
por suposição seria inventar o número mais importante da tabela, então ele vem
do `HotSpotDiagnosticMXBean` — e a função **falha alto** se o MXBean não
existir, em vez de devolver um palpite.

**O paralelismo da BEAM foi reduzido para espelhar a JVM.** Sem
`schedulers_online: 2`, a BEAM usaria os 8 núcleos, sobrariam escalonadores
livres, e o teste não teria medido preempção: teria medido que havia núcleo
sobrando. É o detalhe que decide se o resultado significa algo.

Também: o laço dos *hogs* precisa de uma condição que o JIT não elimine
(`AtomicBoolean`), senão o experimento mede um laço otimizado para fora — e a
conclusão seria "não houve inanição" por um motivo que nada tem a ver com
escalonamento.

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

### A ponte: 500 WebSockets reais viram 500 processos supervisionados

O gateway e o núcleo eram dois resultados independentes, e o README dizia isso.
Agora falam por uma ponte TCP, e o teste de integração atravessa as duas
linguagens:

```
$ bash tests/integracao.sh

  ok   build do Go
  ok   núcleo em Elixir escutando a ponte em 4141
  ok   gateway conectado à ponte
  ok   /stats confirma nucleo_ligado=true
  conexões no gateway : 500
  conexões no núcleo  : 500
  ok   o gateway aceitou 500 de 500 WebSockets reais
  ok   o NÚCLEO vê 500 conexões: a ponte funciona de ponta a ponta
  após fechar a carga : 0 no núcleo
  ok   fechar os WebSockets limpou as conexões no núcleo

7 passaram, 0 falharam
```

**Por que esse teste é obrigatório:** testes de unidade dos dois lados passariam
mesmo com o protocolo divergindo. O enquadramento só é exercitado de verdade
quando os bytes atravessam — e divergência de formato não dá exceção, dá
comportamento errado silencioso.

O protocolo tem quatro tipos de quadro: `CONNECT`, `DISCONNECT`, `DATA` (do
gateway para o núcleo) e `PUSH` (de volta, para o núcleo entregar a um
cliente). Decisões que valem explicação:

**O enquadramento é da VM.** A opção `packet: 4` do `inet` prefixa e consome um
tamanho de 32 bits. Do lado Elixir ninguém escreve "li metade de um quadro";
do lado Go são quatro bytes à mão. Alternativas descartadas: distribuição
Erlang (o Go teria de falar o protocolo da BEAM, desproporcional para três
eventos), NATS (broker num enlace ponto a ponto) e HTTP por evento (inviável na
escala medida).

**O id do cliente é escopado pelo socket do handler.** Dois gateways numerando
clientes a partir de 1 colidiriam no `Registry`, que tem `keys: :unique`, e a
colisão apareceria como `already_started` num cliente legítimo. Há teste para
dois gateways usando os mesmos ids.

**Gateway que cai fecha as conexões que abriu.** O `terminate/2` do handler
chama `Mesh.close/1` para cada cliente registrado. Sem isso, elas ficariam
vivas no `Registry` sem ninguém do outro lado — e a contagem de conexões
deixaria de significar algo. Há teste que fecha o socket sem `DISCONNECT`
nenhum, que é o que acontece quando o processo do gateway morre.

**Quadro malformado não derruba o handler.** Um gateway com bug não deve levar
consigo todas as conexões dele. Há teste que envia três bytes soltos e verifica
que o handler segue aceitando quadros.

### O bug de OTP que o teste de integração expôs

A primeira versão da ponte aceitava conexões dentro de `handle_continue/2`,
devolvendo `{:continue, :aceitar}` a cada iteração. Parece idiomático — e está
errado: **enquanto um GenServer processa continuações, ele não volta à caixa de
mensagens**. O `GenServer.call(Mesh.Bridge, :port)` nunca era atendido, e sete
testes falhavam com timeout de 5 s.

Aceitar é uma operação bloqueante de duração indefinida; quem bloqueia não pode
ser o mesmo processo que responde chamadas. O laço foi para um processo
`spawn_link`: se ele morrer, a ponte morre com ele e o supervisor reconstrói os
dois — que é o correto, porque um listener sem aceitador é um listener inútil.

*Lição:* `handle_continue` serve para continuar uma inicialização, não para
rodar um laço. A diferença só aparece quando alguém tenta falar com o processo.

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
mix run bench/erlang_vs_elixir.exs   # a mesma conexão nas duas linguagens

cd ../../go && go test ./...   # 7 testes do WebSocket, zero dependências
cd .. && bash bench/gateway.sh # custo de uma conexão real + efeito dos buffers
bash tests/integracao.sh       # Go <-> Elixir de ponta a ponta

cd gleam/mesh_codec && gleam test  # codec tipado, contra os mesmos vetores

# O NIF em Rust e opcional. O --force e necessario: System.get_env em tempo de
# compilacao nao e rastreado pelo mix (ver lib/mesh/nif.ex).
cd ../../elixir/mesh
MESH_BUILD_NIF=1 mix test --force       # inclui os 9 testes do NIF
MESH_BUILD_NIF=1 mix run bench/nif.exs  # custo da travessia BEAM<->Rust

# Concorrencia: BEAM contra JVM, pelo mesmo metodo.
# Um processo por modo, de proposito -- ver a secao do Scala.
mix run bench/processo_nu.exs 700000      # processo nu da BEAM: bytes/unidade
mix run bench/preempcao.exs 4 2           # latencia sob carga de CPU

cd ../../scala/loadgen
scala-cli run Concorrencia.scala -- platform 64000   # bate o muro em ~30 mil
scala-cli run Concorrencia.scala -- virtual  700000  # 1.323 bytes/unidade
scala-cli run Preempcao.scala    -- 4 2              # inanicao: nunca roda
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

O gateway em Go e o núcleo falam por uma ponte TCP:

```
  cliente WebSocket ──▶ gateway (Go) ──TCP──▶ ponte ──▶ núcleo (Elixir/OTP)
                        1 goroutine/conn     packet:4   1 processo/conn
                        ~7,1 KB/conn                    ~3,8 KB/conn
                        ws/ sem dependência             Registry + supervisão
                             ◀──────── PUSH ────────────
```

O enquadramento é **da VM**: a opção `packet: 4` do `inet` prefixa e consome um
tamanho de 32 bits, então nem o handler em Elixir nem o lado em Go precisam de
máquina de estado para "li metade de um quadro". É uma das coisas que a BEAM dá
de graça e que num runtime comum custa uma biblioteca.

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
| **Scala 3.10 + JDK 25** | `scala/loadgen`, custo e escalonamento da concorrência | Loom promete o que a BEAM promete — "crie uma por conexão" — e a comparação direta é o que dá sentido aos 3.534 bytes do projeto. Resultado: a thread virtual é **mais barata** (1.323 contra 2.732 bytes) e **sofre inanição completa** sob carga de CPU, onde a BEAM degrada 21x. Mede também o muro da thread de plataforma: 30.568 e OOM | **Akka/Pekko ou Cats Effect**: trariam seu próprio escalonador e mediriam a biblioteca, não a plataforma. O JDK tem `Thread.ofVirtual` e cliente WebSocket embutidos, então o projeto segue sem dependências |
| **Rust 1.93 + rustler** | `native/mesh_nif`, codec como NIF | Existe para **medir o custo da travessia** BEAM↔nativo, que é a decisão que todo projeto BEAM enfrenta e quase ninguém mede. Resultado: ~30 ns por chamada, e o NIF não venceu acima do ruído em nenhum tamanho até 1 MiB | **NIF à mão contra a ABI do `erl_nif.h`**: dezenas de linhas de `unsafe extern "C"` e conversão manual de termos — mediria a qualidade do meu boilerplate, não o custo real. `rustler` é o que se usaria de verdade |
| **Gleam 1.19** | `gleam/mesh_codec`, terceira implementação do protocolo | Tipagem estática sobre a BEAM: o quadro deixa de ser convenção e passa a ser tipo, e três classes de erro migram de tempo de execução para tempo de compilação. O `@external` para `file:read_file/1` mostra que chamar OTP de Gleam é chamada de função, não FFI | **`simplifile`** para o I/O: traria dependência e esconderia justamente o ponto de que Gleam é BEAM |
| **Erlang/OTP 27** | `src/mesh_conn.erl`, conexão alternativa no mesmo nó | É a prova de que Elixir e Erlang são a mesma plataforma: o `mix` compila `src/*.erl` no mesmo app, e a conexão Erlang entra na mesma árvore, no mesmo `Registry`, recebendo a mesma difusão. Escrever a versão em Erlang também expôs um bug que o Elixir escondia — `{via, Modulo, Nome}` com módulo e nome conflatados | **Repositório separado com nó distribuído**: mostraria interoperação entre nós, que é outra coisa — e esconderia justamente o fato de ser um nó só |
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

- **Gleam, Rust, Scala, Clojure e HCL** estão no plano do projeto e **não**
  foram integrados. O ambiente deles está instalado e verificado, o que é
  diferente de estar em uso.
- **Nó único.** Não há distribuição BEAM, nem particionamento entre nós, nem
  `Horde`/`libcluster`. Toda a medição é de um processo `beam.smp`.
- **A difusão melhorou ~3x mas segue não escalando de graça.** 142 ms para
  200 mil conexões com oito escalonadores; a próxima barreira é a emissão de
  `cast` em si, que é uma mensagem por destino. Reduzir isso exigiria agrupar
  destinatários por nó ou trocar difusão por *pull*, o que muda a semântica.
- **A ponte não tem reconexão automática.** Se o núcleo cair, o gateway
  continua servindo WebSocket mas perde o núcleo até ser reiniciado — degrada
  em vez de recusar, e `/stats` mostra `nucleo_ligado: false` para que a
  degradação seja visível. Reconexão com *backoff* está no roadmap.
- **A ponte é um nó só.** Um gateway fala com um núcleo; não há descoberta nem
  balanceamento entre vários núcleos.
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
3. ~~**A ponte gateway ↔ núcleo**~~ **Feita.** TCP com `packet: 4`, quatro
   tipos de quadro, bidirecional, com teste de integração no CI.
4. **Reconexão da ponte com *backoff***, para o gateway sobreviver a um núcleo
   que reinicia.
5. **Buffers de kernel por socket**, via `/proc/net/sockstat`, para fechar a
   conta de memória de uma conexão real.
3. ~~**Supervisão em Erlang puro**~~ **Feito.** `mesh_conn.erl` no mesmo nó,
   com benchmark comparativo: um byte de diferença por conexão.
4. ~~**Serviço em Gleam** na mesma BEAM~~ **Feito.** Codec tipado do
   protocolo, verificado contra os mesmos vetores de bytes do Elixir e do Go.
5. ~~**Caminho crítico em Rust** via NIF~~ **Feito.** Travessia medida em
   ~30 ns por chamada; o Elixir ganha até 4 KiB e acima de 64 KiB a diferença
   cai dentro do ruído.
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
- **A plataforma mais leve não é a mais barata, e o número de memória era a
  parte menos interessante.** A thread virtual do Loom custa 1.323 bytes contra
  2.732 do processo da BEAM — e **nunca rodou** sob carga de CPU, onde a BEAM
  degradou 21x. Ela é mais barata porque não carrega escalonamento preemptivo,
  heap isolado nem supervisão. Medir só memória teria dado a conclusão oposta.
- **"Escreve em Rust que fica mais rápido" é folclore, e agora tenho o
  número.** A travessia custa **~30 ns por chamada** (reproduzido em três
  execuções, ±3%). Até 4 KiB o Elixir ganha de forma estabelecida — em payload
  pequeno o NIF é 6x mais lento. Acima de 64 KiB a diferença cai dentro do
  ruído. NIF compensa quando o trabalho é algoritmicamente mais barato em
  nativo, não quando é movimentação de dados.
- **Erro de instrumentação, sexta vez.** Medi todas as repetições do Elixir e
  depois todas as do Rust — o erro que o P01 me ensinou — e duas execuções
  deram conclusões opostas. Saber a lição não substitui aplicá-la: a correção
  agora é **código** (alternar, reportar dispersão, aquecer, e recusar-se a
  concluir quando a margem não supera o ruído), não disciplina.
- **A tipagem estática move o erro de lugar, não o elimina.** As três classes
  de erro que o Gleam pega em compilação são as mesmas que o Elixir pega em
  teste. O que muda é quando você descobre — e quanto custa descobrir tarde.
- **Um arquivo de vetores vale mais que quatro suítes isoladas.** Divergência de
  formato entre linguagens não dá exceção: dá comportamento errado silencioso.
  Dez linhas de hexadecimal compartilhadas resolvem o que nenhum teste de
  unidade pegaria.
- **Elixir e Erlang são a mesma plataforma, e agora tenho o número.** 3.304
  contra 3.305 bytes por conexão. A escolha entre as duas é ergonomia, e quem
  disser que uma é mais rápida que a outra para o mesmo algoritmo precisa
  mostrar a medição.
- **Escrever em Erlang expôs um bug que o Elixir escondia.** O `{via, Modulo,
  Nome}` com módulo e nome conflatados passa desapercebido em Elixir, onde
  `Registry` e `Mesh.Registry` têm a mesma cara. Com o prefixo `'Elixir.'`
  explícito, o erro fica visível.
- **`handle_continue` não é lugar de laço.** Enquanto um GenServer processa
  continuações, ele não atende chamadas — e o sintoma apareceu longe da causa:
  sete testes com timeout, nenhum deles sobre aceitação de conexão. Quem
  bloqueia não pode ser quem responde.
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
| Suíte ExUnit | ✅ 35/35 com o NIF, 26 + 9 excluídos sem ele |
| Benchmark de capacidade | ✅ 700 mil conexões, 3.783 bytes cada |
| Benchmark de difusão, 3 implementações | ✅ intercalado, com dispersão reportada |
| Fanout particionado | ✅ ~3x medido; +7% de memória por conexão |
| Gateway em Go, WebSocket real | ✅ zero dependências, 7 testes, ~7,1 KB/conn |
| Efeito do tamanho dos buffers | ✅ +35 % com o padrão das bibliotecas |
| Ponte gateway ↔ núcleo | ✅ TCP `packet: 4`, 7 testes + integração no CI |
| Teste de integração entre as linguagens | ✅ 500 WebSockets → 500 processos |
| **Erlang** no mesmo nó | ✅ `mesh_conn.erl`, 5 testes, benchmark comparativo |
| **Gleam** — codec tipado do protocolo | ✅ 13 testes, conformes aos vetores |
| **Rust** — codec como NIF | ✅ 9 testes, travessia em ~30 ns (3 execuções, ±3%) |
| **Scala** — BEAM vs Loom | ✅ 1.323 vs 2.732 bytes/unidade; inanição medida |
| Protocolo verificado em 4 linguagens | ✅ Elixir, Go, Gleam e Rust contra `protocolo/vetores.txt` |
| Clojure | ⬜ ambiente pronto, não integrado |
| Distribuição entre nós | ⬜ |
| NATS, OpenTofu, kind em uso | ⬜ instalados e verificados, não integrados |
| CI | ⬜ |

## Licença

MIT.
