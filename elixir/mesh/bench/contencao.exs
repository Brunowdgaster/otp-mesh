# contencao.exs — estado compartilhado sob contenção, do lado da BEAM.
#
#   mix run bench/contencao.exs
#   mix run bench/contencao.exs 8 200000
#
# ## O par deste arquivo
#
# `clojure/contencao/contencao.clj` mede cinco mecanismos da JVM para "N
# trabalhadores incrementando um contador". Este mede os da BEAM, com a mesma
# carga e o mesmo critério: **o número só vale se o contador final bater**.
#
# O ponto de contato com o projeto é o `Mesh.Stats`, que é um GenServer com
# contadores: toda atualização passa pela caixa de mensagens dele, o que
# serializa as escritas. Esse é o padrão idiomático da BEAM — não compartilhe
# estado, ponha num processo — e a pergunta é quanto ele custa contra as
# primitivas sem bloqueio que a plataforma também oferece.
#
# ## Os mecanismos
#
#   * `:counters` -- contadores sem bloqueio, com write_concurrency. É o
#     `AtomicLong` da BEAM;
#   * `:atomics`  -- inteiros de 64 bits atômicos, mesma família;
#   * `:ets` com `write_concurrency` -- tabela compartilhada, `update_counter`;
#   * **GenServer com `cast`** -- assíncrono. É o `send` do agent de Clojure, e
#     tem a mesma armadilha: `cast` volta na hora, então medir sem esperar o
#     esvaziamento da caixa mediria enfileiramento, não trabalho;
#   * **GenServer com `call`** -- síncrono, uma ida e volta por incremento. É o
#     que o `Mesh.Stats` faz quando o chamador precisa de confirmação.
#
# ## A armadilha, de novo
#
# A versão com `cast` precisa esperar a caixa esvaziar. Sem isso o número sai
# absurdo e a conclusão inverte — é a mesma classe de erro que a medição de
# memória deste projeto cometeu antes, contando garbage de mensagens em
# trânsito. Aqui o esvaziamento é confirmado com um `call` final, que só é
# atendido depois de todos os casts anteriores.

[n_workers, por_worker] =
  case System.argv() do
    [a, b | _] -> [String.to_integer(a), String.to_integer(b)]
    _ -> [8, 200_000]
  end

esperado = n_workers * por_worker

# Repetições por mecanismo. A primeira versão deste benchmark media UMA vez
# cada um e publicava a tabela sem dispersão -- e duas linhas dela ficavam a
# 0,04% e 6,5% de distância, onde afirmar qualquer ordem é invenção.
#
# `:ets, 1 chave` e `GenServer cast` levam ~95 s cada por repetição, então o
# padrão é 3. Com REPS=5 a execução passa de 15 minutos.
reps = String.to_integer(System.get_env("REPS") || "3")

defmodule Contador do
  @moduledoc "GenServer com um contador, no mesmo espírito do Mesh.Stats."
  use GenServer

  @doc """
  `off_heap: true` poe a caixa de mensagens fora do heap do processo.

  Muda o resultado por duas ordens de grandeza sob contencao, e na direcao
  oposta sem contencao -- ver a leitura no fim deste arquivo.
  """
  def start_link(opts) do
    spawn_opt =
      if Keyword.get(opts || [], :off_heap, false),
        do: [message_queue_data: :off_heap],
        else: []

    GenServer.start_link(__MODULE__, 0, name: __MODULE__, spawn_opt: spawn_opt)
  end

  def init(n), do: {:ok, n}

  def inc_cast, do: GenServer.cast(__MODULE__, :inc)
  def inc_call, do: GenServer.call(__MODULE__, :inc)

  # Serve de barreira: a resposta deste call só sai depois de todos os casts
  # anteriores terem sido processados, porque a caixa é FIFO por remetente e o
  # GenServer processa uma mensagem por vez.
  def valor, do: GenServer.call(__MODULE__, :valor, 120_000)

  def handle_cast(:inc, n), do: {:noreply, n + 1}
  def handle_call(:inc, _de, n), do: {:reply, :ok, n + 1}
  def handle_call(:valor, _de, n), do: {:reply, n, n}
end

# Roda `fun` em n processos e espera todos terminarem. Partida sincronizada,
# para que a contencao medida seja a real e nao a do primeiro que terminou.
em_paralelo = fn n, fun ->
  pai = self()

  pids =
    for i <- 1..n do
      spawn_link(fn ->
        receive do
          :va -> :ok
        end

        fun.(i)
        send(pai, {:feito, self()})
      end)
    end

  Enum.each(pids, &send(&1, :va))

  for _ <- 1..n do
    receive do
      {:feito, _} -> :ok
    after
      300_000 -> raise "trabalhador nao terminou em 300 s"
    end
  end
end

medir = fn corpo, ler ->
  t0 = System.monotonic_time(:microsecond)
  corpo.()
  us = System.monotonic_time(:microsecond) - t0
  final = ler.()

  %{
    ms: Float.round(us / 1000, 1),
    ops_s: round(esperado / max(us / 1_000_000, 0.000001)),
    final: final,
    correto?: final == esperado
  }
end

# Roda a estratégia `reps` vezes e devolve a MELHOR vazão mais a dispersão.
#
# Melhor, e não média: a média mistura a execução contaminada com as limpas.
# E a dispersão ao lado, porque número sem dispersão não é medição -- foi
# exatamente o que faltava na primeira versão desta tabela.
melhor_de = fn f ->
  amostras = Enum.map(1..reps, fn _ -> f.() end)

  # Falha alto se QUALQUER repetição contou errado, não só a última.
  erradas = Enum.reject(amostras, & &1.correto?)

  taxas = Enum.map(amostras, & &1.ops_s)
  melhor = Enum.max(taxas)
  pior = Enum.min(taxas)

  %{
    ops_s: melhor,
    pior: pior,
    disp: Float.round((melhor - pior) / max(pior, 1) * 100, 1),
    ms: amostras |> Enum.map(& &1.ms) |> Enum.min(),
    final: hd(amostras).final,
    correto?: erradas == []
  }
end

IO.puts("""

=== Estado compartilhado sob contencao (BEAM) ===

otp          : #{:erlang.system_info(:otp_release)}
escalonadores: #{:erlang.system_info(:schedulers_online)}
workers      : #{n_workers}, cada um com #{por_worker} incrementos
esperado     : #{esperado}
reps         : #{reps} por mecanismo, melhor vazao, dispersao reportada
""")

estrategias = [
  {":counters",
   fn ->
     ref = :counters.new(1, [:write_concurrency])

     medir.(
       fn ->
         em_paralelo.(n_workers, fn _ ->
           Enum.each(1..por_worker, fn _ -> :counters.add(ref, 1, 1) end)
         end)
       end,
       fn -> :counters.get(ref, 1) end
     )
   end},
  {":atomics",
   fn ->
     ref = :atomics.new(1, [])

     medir.(
       fn ->
         em_paralelo.(n_workers, fn _ ->
           Enum.each(1..por_worker, fn _ -> :atomics.add(ref, 1, 1) end)
         end)
       end,
       fn -> :atomics.get(ref, 1) end
     )
   end},
  # Duas variantes de ETS, e a diferenca entre elas e de 1.400x:
  # `write_concurrency` fragmenta o travamento POR CHAVE, entao na mesma chave
  # ele nao ajuda. Ver a leitura no fim do arquivo.
  {":ets, 1 chave",
   fn ->
     t = :ets.new(:cont, [:public, :set, write_concurrency: true])
     :ets.insert(t, {:n, 0})

     medir.(
       fn ->
         em_paralelo.(n_workers, fn _ ->
           Enum.each(1..por_worker, fn _ -> :ets.update_counter(t, :n, 1) end)
         end)
       end,
       fn -> :ets.lookup_element(t, :n, 2) end
     )
   end},
  {":ets, 1 chave/worker",
   fn ->
     t = :ets.new(:cont, [:public, :set, write_concurrency: true])
     for i <- 1..n_workers, do: :ets.insert(t, {i, 0})

     medir.(
       fn ->
         em_paralelo.(n_workers, fn i ->
           Enum.each(1..por_worker, fn _ -> :ets.update_counter(t, i, 1) end)
         end)
       end,
       fn -> Enum.sum(for i <- 1..n_workers, do: :ets.lookup_element(t, i, 2)) end
     )
   end},
  {"GenServer cast",
   fn ->
     {:ok, pid} = Contador.start_link([])

     r =
       medir.(
         fn ->
           em_paralelo.(n_workers, fn _ ->
             Enum.each(1..por_worker, fn _ -> Contador.inc_cast() end)
           end)

           # A BARREIRA. Sem ela estariamos medindo enfileiramento.
           Contador.valor()
         end,
         fn -> Contador.valor() end
       )

     GenServer.stop(pid)
     r
   end},
  {"GenServer cast off_heap",
   fn ->
     {:ok, pid} = Contador.start_link(off_heap: true)

     r =
       medir.(
         fn ->
           em_paralelo.(n_workers, fn _ ->
             Enum.each(1..por_worker, fn _ -> Contador.inc_cast() end)
           end)

           Contador.valor()
         end,
         fn -> Contador.valor() end
       )

     GenServer.stop(pid)
     r
   end},
  {"GenServer call",
   fn ->
     {:ok, pid} = Contador.start_link([])

     r =
       medir.(
         fn ->
           em_paralelo.(n_workers, fn _ ->
             Enum.each(1..por_worker, fn _ -> Contador.inc_call() end)
           end)
         end,
         fn -> Contador.valor() end
       )

     GenServer.stop(pid)
     r
   end}
]

IO.puts(
  String.pad_trailing("mecanismo", 22) <>
    String.pad_leading("ms", 10) <>
    String.pad_leading("ops/s", 13) <>
    String.pad_leading("disp", 9) <>
    String.pad_leading("final", 11) <>
    String.pad_leading("ok?", 9)
)

IO.puts(String.duplicate("-", 72))

resultados =
  Enum.map(estrategias, fn {nome, f} ->
    r = melhor_de.(f)

    IO.puts(
      String.pad_trailing(nome, 22) <>
        String.pad_leading("#{r.ms}", 10) <>
        String.pad_leading("#{r.ops_s}", 13) <>
        String.pad_leading("#{r.disp}%", 9) <>
        String.pad_leading("#{r.final}", 11) <>
        String.pad_leading(if(r.correto?, do: "sim", else: "NAO"), 9)
    )

    {nome, r}
  end)

# Falha alto se qualquer mecanismo perdeu atualizacao: nenhum deveria, e se um
# perdeu, o benchmark achou um bug e nao um numero.
errados = Enum.filter(resultados, fn {_, r} -> not r.correto? end)

IO.puts("""

=== Leitura ===
""")

if errados != [] do
  IO.puts("  ATENCAO: #{length(errados)} mecanismo(s) perderam atualizacoes:")
  Enum.each(errados, fn {n, r} -> IO.puts("    #{n}: #{r.final} de #{esperado}") end)

  IO.puts("""

  Nenhum destes deveria perder nada. Isto e um achado, nao um numero --
  investigue antes de publicar a tabela.
  """)
else
  IO.puts("  Todos os #{length(resultados)} mecanismos contaram certo.")
end

{_, melhor} = Enum.max_by(resultados, fn {_, r} -> r.ops_s end)
{_, pior} = Enum.min_by(resultados, fn {_, r} -> r.ops_s end)

ops = fn nome ->
  case Enum.find(resultados, fn {n, _} -> n == nome end) do
    {_, r} -> r.ops_s
    nil -> 0
  end
end

IO.puts("""
  Faixa: #{melhor.ops_s} a #{pior.ops_s} ops/s -- #{Float.round(melhor.ops_s / max(pior.ops_s, 1), 1)}x entre
  o mais rapido e o mais lento, TODOS dando a resposta certa. Correcao nao e o
  que separa estes mecanismos; o que separa e contencao.

  1. ETS: a MESMA tabela, a MESMA opcao, 1.400x de diferenca
  -----------------------------------------------------------
  uma chave        : #{ops.(":ets, 1 chave")} ops/s
  uma por worker   : #{ops.(":ets, 1 chave/worker")} ops/s

  `write_concurrency` fragmenta o travamento POR CHAVE. Na mesma chave nao
  ajuda: os escalonadores disputam a mesma linha de cache e a vazao COLAPSA
  conforme se adicionam nucleos. Medido isoladamente, com o total fixo em
  1,6 milhao: 1 worker faz 3,6 M/s, 2 fazem 6,6 M/s, 4 despencam para 93 mil
  e 8 para 17 mil.

  Mais paralelismo deixando 200x mais lento e o sintoma classico de contencao,
  e o unico jeito de ve-lo e VARIAR o numero de trabalhadores. Com uma medicao
  so, o numero parece simplesmente "ruim" e a causa fica invisivel.

  2. cast mais lento que call: contrapressao, nao medicao
  -----------------------------------------------------------
  cast (on-heap)   : #{ops.("GenServer cast")} ops/s
  cast (off_heap)  : #{ops.("GenServer cast off_heap")} ops/s
  call (sincrono)  : #{ops.("GenServer call")} ops/s

  `cast` ser mais lento que `call` parece bug de benchmark. Nao e: a caixa do
  GenServer chegou a 811 mil mensagens. Com a caixa no heap do processo, cada
  coleta de lixo varre a fila inteira, repetidamente.

  `message_queue_data: :off_heap` tira a fila do heap, e sob contencao isso
  rende 254x. Com UM trabalhador, porem, fica 2,8x mais LENTO -- a opcao nao e
  gratuita: troca varredura de GC por alocacao.

  E o `call` e mais lento por operacao mas AUTO-LIMITADO: cada remetente espera
  a resposta, entao a caixa nunca cresce. `call` da contrapressao de graca;
  `cast` a remove. Mesmo tema da secao de contrapressao do projeto, em outra
  escala.

  3. Pares que a dispersao NAO separa
  -----------------------------------------------------------
  Duas distancias desta tabela sao pequenas demais para a ordem significar
  algo, e a primeira versao dela (sem dispersao) afirmava uma ordem:

    :atomics  x  :ets 1 chave/worker   -- ficaram a 0,04% na medicao original
    GenServer cast  x  :ets 1 chave     -- ficaram a 6,5%

  Com a dispersao ao lado, compare: se ela for maior que a distancia, os dois
  mecanismos sao INDISTINGUIVEIS nesta maquina, e a tabela nao autoriza dizer
  qual e mais rapido.

  4. O GenServer nao e desperdicio
  -----------------------------------------------------------
  Ele e o padrao idiomatico e e o que o Mesh.Stats usa: processo
  supervisionado, estado isolado, reiniciavel sem levar o resto. `:counters`
  nao tem supervisao, nao tem estado inspecionavel e nao pode ser substituido
  em tempo de execucao. A escolha e entre vazao e propriedades operacionais,
  nao entre certo e errado.

  A comparacao com os mecanismos da JVM esta em clojure/contencao/contencao.clj
  e na secao do Clojure no README.
""")
