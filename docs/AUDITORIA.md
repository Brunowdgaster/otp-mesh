# Auditoria das medições

Revisão de **toda** afirmação numérica deste README contra as regras de medição
do repositório. Feita depois de descobrir que parte das medições de sessões
anteriores rodou com carga de fundo na máquina — um jogo e um navegador abertos
no Windows, que o `/proc/loadavg` do WSL2 não vê.

Três afirmações foram **corrigidas publicamente**. O resto está listado com o
motivo de ser robusto ou frágil, inclusive as que sobreviveram.

## As cinco regras

Estão implementadas em `bench/cruzado.sh` e `bench/calibra.sh`, e cada uma
existe porque uma medição deste portfólio falhou por não a seguir:

1. **Alternar A e B** a cada repetição, invertendo a ordem nas pares.
2. **Aquecer fora da medição.**
3. **Calibrar a máquina antes e depois**, com espera de resfriamento na
   verificação final.
4. **Falhar alto** se o resultado computado estiver errado.
5. **Decidir por sobreposição de faixas**, não por margem dos mínimos.

## Classificação

O que determina a robustez de uma afirmação, em ordem de importância:

| critério | por quê |
|---|---|
| é **memória ou correção**, não tempo | carga de fundo não muda quantos bytes um processo precisa, nem se um contador fechou |
| o **efeito é grande** (≫ dispersão) | 1.400x não vira ruído |
| foi **alternada** entre A e B | sem isso, deriva no meio é atribuída a B |
| tem **dispersão reportada** | número sem dispersão não é medição |

## Robustas: memória e correção

Imunes a carga de fundo por natureza.

| afirmação | método | por que é robusta |
|---|---|---|
| 700 mil conexões, **3.534 B** cada | A/B limpo em `capacity.exs` | contagem de bytes |
| difusão particionada custa **+7%** de memória | A/B limpo, dois processos | contagem de bytes |
| Erlang **3.304** vs Elixir **3.305** B | alternado, melhor de 5 | contagem de bytes, e a conclusão é "um byte" |
| gateway: **7,1 KB** por conexão | RSS de `/proc/self/statm` | páginas tocadas; a ressalva de que **não inclui buffers de socket do kernel** já está publicada |
| buffers de 1 KiB economizam **35%** | A/B de configuração | contagem de bytes |
| Loom **1.323 B** vs BEAM **2.732 B** por unidade | RSS/N, um processo por modo | contagem de bytes |
| sem coordenação perde **70%** das atualizações | determinístico | é correção, não desempenho |
| dois atoms: **130.235** violações; dois refs: **0** | determinístico | é correção |
| HCL: **20 asserções** em 5 propriedades | determinístico | é correção |
| portes: **9/9** em 5 linguagens, bytes idênticos | determinístico | é correção |

## Robustas: o efeito é grande demais para ser ruído

| afirmação | efeito | por que sobrevive |
|---|---|---|
| ETS 1 chave vs 1/worker | **1.400x** | nenhuma carga de fundo produz três ordens de grandeza |
| `cast` on-heap vs `off_heap` | **254x** | idem |
| STM vs CAS no mesmo processo | **~500x** | idem, e medidos no mesmo processo |
| Loom sofre inanição: **≥10.000 ms** vs 0,170 ms | **≥31.000x** | o valor do Loom é o **teto do cronômetro**: ele não rodou |
| thread de plataforma morre em **30.568** | limite | é contagem até falhar, não tempo |

## Robustas: método já correto

| afirmação | método | observação |
|---|---|---|
| NIF: travessia **~30 ns** | alternado, 9 reps, **3 execuções ±3%** | corrigido ainda na sessão original, depois de duas execuções darem conclusões opostas |
| NIF: Elixir ganha até 4 KiB, resto **no ruído** | alternado + dispersão + veredito explícito | a tabela já reporta "no ruído" em 4 das 10 linhas |
| difusão particionada **~3x** | alternado, melhor de 5, **dispersão 45–107%** | o texto já diz: *"a dispersão é da ordem do ganho, então o multiplicador exato não está estabelecido"* |

A linha da difusão é o caso em que eu acertei na primeira: a dispersão foi
reportada e a conclusão foi limitada ao que ela sustenta — a **ordenação** é a
mesma nos quatro degraus, e isso é o que está afirmado.

## Corrigidas

### 1. `agent` de Clojure × `GenServer` de Elixir

| | antes | depois |
|---|---|---|
| afirmação | "**empatam**, 8% de diferença" (534 k vs 493 k) | **não determinado** |
| método | processos e momentos distintos, sem alternância | `bench/fila_cruzada.sh`, 7 reps alternadas |
| resultado | — | faixas **437–634 mil** e **370–522 mil**, que **se sobrepõem**; margem 21,4% dentro da dispersão de 45,0% |

Sobrevive a substância: as duas ficam na mesma ordem de grandeza, longe dos
106 M do `:counters` e dos 62 mil do STM.

### 2. `:counters` da BEAM × `AtomicLong` da JVM

| | antes | depois |
|---|---|---|
| afirmação | BEAM **3,4x** mais rápido | BEAM **1,19x a 2,97x** |
| método | processos e momentos distintos, sem alternância | `bench/contador_cruzado.sh`, 7 reps alternadas |
| resultado | — | faixas **12,4–40,7 M** e **48,4–120,9 M**, **disjuntas** |

A explicação continua de pé: `write_concurrency` fragmenta por escalonador e
evita disputa de linha de cache. E uma ressalva que faltava: com 8
trabalhadores em 4 núcleos físicos a fragmentação tem onde render; **com 1
trabalhador a comparação provavelmente inverte, e isso não foi medido**.

### 3. Taxa de criação: processo BEAM × thread virtual

| | antes | depois |
|---|---|---|
| afirmação | BEAM **3,2x** mais rápido (122.079/s vs 38.015/s) | BEAM **3,07x a 5,32x** |
| método | execução única, sem alternância, **e sob pressões de memória diferentes** | `bench/concorrencia_cruzada.sh`, 7 reps alternadas, em 200 mil |
| resultado | — | faixas **96,5–167,4 mil/s** e **24,9–31,5 mil/s**, **disjuntas** |

O segundo defeito era pior que a falta de alternância: a medição original usou
**700 mil unidades dos dois lados**, onde a BEAM ocupa ~1,9 GiB e o Loom
~930 MiB numa máquina com 3,8 GiB. Os dois lados não estavam sob a mesma
pressão de memória, e isso entra na taxa.

Esta correção **fortalece** a afirmação: o 3,2x publicado ficou exatamente no
limite conservador do intervalo real.

> A **capacidade** de 700 mil unidades de cada lado continua válida — é
> contagem, não tempo.

### 4. Latência de atendimento sem carga

| | antes | depois |
|---|---|---|
| afirmação | BEAM **40x** mais rápida (0,008 vs 0,318 ms) | BEAM **12x a 36x** |
| método | execuções únicas, sem alternância | `bench/concorrencia_cruzada.sh` fase 2, 7 reps alternadas |
| resultado | — | faixas **2–6 µs** e **72–371 µs**, **disjuntas** |

A dispersão é altíssima (200% e 415%) porque são microssegundos, perto da
granularidade do relógio. Mas as faixas não se tocam: a pior amostra da BEAM
(6 µs) ainda é menor que a melhor do Loom (72 µs).

Os "40x" eram levemente otimistas — o melhor caso medido agora é 36x.

### 5. Tabela de contenção da BEAM

Sete valores, **uma execução cada, sem dispersão**. Refeita com 3 repetições:

| mecanismo | antes | depois | dispersão |
|---|---|---|---|
| `:counters` | 106.354.693 | **53.045.122** | 7,2% |
| `:atomics` | 32.149.172 | 32.630.420 | **113,9%** |
| `:ets`, 1 chave/worker | 32.136.258 | **15.586.035** | 22,1% |
| `cast` `off_heap` | 4.304.547 | 3.518.084 | 4,8% |
| `call` | 492.567 | 488.031 | 27,1% |
| `cast` on-heap | 17.106 | **52.879** | **164,1%** |
| `:ets`, 1 chave | 16.057 | 17.088 | 4,5% |

Duas afirmações derivadas morreram:

* *"`:atomics` empata com `:ets` de uma chave por worker"* — agora estão a
  2,1x, mas com 113,9% de dispersão as faixas se sobrepõem: **não determinado**;
* os multiplicadores **1.400x** (ETS por chave) e **254x** (`off_heap`) viraram
  **~912x** e **~66x**. Os fatos sobrevivem; os números finos não.

E um achado sobre a própria dispersão: os dois mecanismos acima de 100% são
justamente os que disputam recurso compartilhado sem fragmentação. **A
dispersão alta é a assinatura do fenômeno**, não do relógio — uma caixa de
mensagens que cresce sem limite não produz tempo repetível.

### 6. Convergência do `Registry` depois do caos

| | antes | depois |
|---|---|---|
| afirmação | **8.914 ms** para 210 mil mortes | **1.806 – 4.610 ms** para 60 mil |
| método | execução única | `bench/caos.exs`, 4 reps, reabrindo entre elas |
| dispersão | — | **155%** |

Por morte: 30 a 77 µs. O número publicado (42 µs por morte) cai no meio da
faixa — era plausível, e era uma amostra.

Há estrutura dentro da dispersão: a **primeira repetição é ~2,5x mais lenta**
(4.610 → 2.561 → 1.871 → 1.806 ms). Isso é aquecimento, e só aparece com
repetição.

### 7. Reinício do `Stats` — o caso mais interessante da auditoria

| contexto | reinício |
|---|---|
| sistema quieto, 200 mil conexões ociosas | **6,0 – 6,7 ms** |
| depois de 4 rodadas matando 60 mil cada | **19,2 – 37,1 ms** (disp. 94%) |

O número original (**5,83 ms**) **não estava errado** — estava **condicional**,
e a condição não foi declarada. Ele é reprodutível num sistema quieto; sob
agitação o mesmo reinício custa 3x a 6x mais, porque o supervisor precisa notar
o `:DOWN` e iniciar o filho num nó com 140 mil processos e rotatividade
recente.

O fato qualitativo sobrevive nos dois contextos: volta em **milissegundos**, com
o estado reconstruído do `Registry`.

### E o benchmark bateu na intensidade de reinício

A primeira versão de `bench/caos.exs` matava o `Stats` 9 vezes com 120 ms de
intervalo. Resultado: `{:error, :nao_voltou}` e, na iteração seguinte,
`Process.exit(nil, :kill)` — o `Stats` não existia mais.

Causa: `Supervisor.start_link(children, strategy: :one_for_one)` **sem
`max_restarts`**, então vale o padrão do OTP — **3 reinícios em 5 segundos**.
Estourado o limite, o supervisor desiste e derruba a árvore.

O benchmark acionou **o mecanismo que o README descreve na seção seguinte**, e
levou a árvore abaixo por fazer exatamente o que aquela seção diz para não
fazer. Dois bugs foram corrigidos no script:

1. espaçamento de 5,2 s entre as mortes, e verificação de que o supervisor está
   vivo antes de cada uma — falhando com o motivo, em vez de estourar com "not
   a pid" três quadros de pilha abaixo;
2. **ids nunca reusados** na reabertura. `kill_fraction` mata com
   `Enum.take_random/2`, então os sobreviventes ficam espalhados; reabrir "a
   partir da contagem atual" colidiria com ids vivos, `open_many` contaria erro,
   e a população ficaria menor que a declarada — com a repetição seguinte
   matando 30% de um grupo diferente, em silêncio.

## Nada pendente

As sete correções estão aplicadas no README, cada uma marcada no ponto onde o
número aparece.

## O que esta auditoria mudou no instrumento

Três melhorias, todas provocadas por achados:

**`bench/calibra.sh`** — detecta máquina ocupada por tempo de um laço fixo,
porque `/proc/loadavg` não vê carga do lado do Windows em WSL2. Medido: com 4
núcleos do Windows ocupados, o laço inflou **74%** (183 → 319 ms) e o `loadavg`
mal se moveu.

**Modo `--esperar`** — a calibração *depois* da medição mede, em parte, o calor
que o próprio benchmark gerou. Sem isso, toda medição longa reprovaria a si
mesma. O modo espera a máquina voltar à faixa, com teto de tentativas, e assim
distingue "meu benchmark aqueceu a CPU" (volta) de "há carga externa" (não
volta). Na primeira execução da taxa de criação, voltou na **segunda
tentativa** — era o benchmark.

**Regra de sobreposição de faixas** — a regra anterior ("margem dos mínimos
contra dispersão") declarou "não determinado" para o par `AtomicLong` ×
`:counters`, cujas faixas **não se tocam**. Dispersão alta não importa quando a
pior amostra do vencedor supera a melhor do perdedor. A regra nova decide esse
par e **mantém** o par `agent`/`GenServer` como não determinado — um
instrumento que decide tudo é tão inútil quanto um que não decide nada.
