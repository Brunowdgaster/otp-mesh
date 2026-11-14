defmodule Mesh do
  @moduledoc """
  API do mesh: abrir e fechar conexões, difundir mensagens, observar.

  Toda função aqui é fina de propósito — a lógica vive nos processos
  (`Mesh.Connection`, `Mesh.Stats`) e na árvore de supervisão
  (`Mesh.Application`). Este módulo existe para que o teste e o benchmark não
  precisem conhecer a topologia.
  """

  @doc """
  Abre uma conexão com o identificador dado.

  Devolve `{:ok, pid}` ou `{:error, {:already_started, pid}}` — o `Registry`
  com `keys: :unique` garante que dois processos não disputem o mesmo id.
  """
  def open(id) do
    DynamicSupervisor.start_child(Mesh.ConnSupervisor, {Mesh.Connection, id})
  end

  @doc """
  Abre `n` conexões, numeradas de `from` em diante.

  Devolve `{abertas, falhas}`. Falha aqui quase sempre significa limite de
  processos da VM ou memória — e é informação, não exceção: é justamente o que
  `bench/capacity.exs` mede.
  """
  def open_many(n, from \\ 0) do
    Enum.reduce(from..(from + n - 1), {0, 0}, fn id, {ok, err} ->
      case open(id) do
        {:ok, _pid} -> {ok + 1, err}
        _ -> {ok, err + 1}
      end
    end)
  end

  @doc """
  Abre uma conexão implementada em **Erlang puro** (`mesh_conn`).

  Mesma árvore de supervisão, mesmo `Registry`, mesmo tópico de difusão — o
  `Mesh.broadcast/1` alcança as duas implementações sem saber qual é qual,
  porque as duas tratam o mesmo `{:deliver, payload}` e compilam para o mesmo
  bytecode da BEAM.

  Não há camada de tradução, adaptador nem porta. É o que significa dizer que
  Elixir e Erlang são a mesma plataforma, e não duas que interoperam.
  """
  def open_erlang(id) do
    DynamicSupervisor.start_child(Mesh.ConnSupervisor, :mesh_conn.child_spec(id))
  end

  @doc """
  Abre `n` conexões em Erlang, numeradas de `from` em diante.
  """
  def open_many_erlang(n, from \\ 0) do
    Enum.reduce(from..(from + n - 1), {0, 0}, fn id, {ok, err} ->
      case open_erlang(id) do
        {:ok, _pid} -> {ok + 1, err}
        _ -> {ok, err + 1}
      end
    end)
  end

  @doc """
  Lê os contadores de uma conexão, seja ela Elixir ou Erlang.

  As duas respondem `:stats` com um mapa que tem `:received` e `:dropped`; a
  versão em Erlang acrescenta `impl: :erlang`, que é como o teste distingue sem
  olhar o pid.
  """
  def stats_de(id), do: GenServer.call(via(id), :stats)

  defp via(id), do: {:via, Registry, {Mesh.Registry, id}}

  @doc """
  Fecha uma conexão e **espera** o `Registry` refletir o fechamento.

  ## Por que a espera existe

  `DynamicSupervisor.terminate_child/2` devolve `:ok` assim que o processo
  morre — mas o `Registry` só remove a entrada quando **ele** recebe o `:DOWN`
  do monitor, o que é assíncrono. Sem a espera, esta sequência falha de forma
  intermitente:

      :ok = Mesh.close("c1")
      0 = Mesh.count()          # às vezes ainda 1

  Foi exatamente assim que o bug apareceu: o teste de ciclo de vida falhava em
  ~2 de 12 execuções, sem depender de semente. A API dizer "fechei" enquanto a
  contagem ainda inclui a conexão é uma armadilha para quem chama, não uma
  peculiaridade aceitável.

  `Mesh.Chaos.kill_fraction/1` **não** espera do mesmo jeito, e a diferença é
  deliberada: lá o ponto é justamente medir quanto tempo a convergência leva
  sob morte em massa.
  """
  def close(id) do
    case Registry.lookup(Mesh.Registry, id) do
      [{pid, _}] ->
        res = DynamicSupervisor.terminate_child(Mesh.ConnSupervisor, pid)
        aguarda_desregistro(id, 1_000)
        res

      [] ->
        {:error, :nao_encontrada}
    end
  end

  defp aguarda_desregistro(id, timeout_ms) do
    fim = System.monotonic_time(:millisecond) + timeout_ms
    loop_desregistro(id, fim)
  end

  defp loop_desregistro(id, fim) do
    cond do
      Registry.lookup(Mesh.Registry, id) == [] ->
        :ok

      System.monotonic_time(:millisecond) > fim ->
        :timeout

      true ->
        Process.sleep(1)
        loop_desregistro(id, fim)
    end
  end

  @doc "Número de conexões vivas, lido do Registry."
  def count, do: Registry.count(Mesh.Registry)

  @doc """
  Lista os pids de todas as conexões vivas, lendo do `Registry`.

  A primeira versão usava `DynamicSupervisor.which_children/1`, que é uma
  chamada **síncrona ao processo supervisor**: ele monta a lista inteira a
  partir do próprio estado e a copia para quem pediu. Com 700 mil filhos isso
  entra no caminho de medição do teste de caos e passa a medir o supervisor, não
  o sistema.

  O `Registry` guarda os pids em ETS particionada, e `select/2` lê sem envolver
  processo nenhum.
  """
  def pids do
    Registry.select(Mesh.Registry, [{{:_, :"$1", :_}, [], [:"$1"]}])
  end

  @topic "all"

  @doc """
  Difunde `payload` para todas as conexões, **em paralelo por partição**.

  `Registry.dispatch/4` com `parallel: true` invoca o callback uma vez por
  partição do registro, cada uma num processo próprio. Com oito escalonadores
  são oito processos emitindo `cast` ao mesmo tempo, em vez de um.

  O envio é assíncrono e **pode ser descartado** pela conexão de destino se a
  caixa de mensagens dela estiver cheia — ver a contrapressão em
  `Mesh.Connection`. A diferença entre endereçadas e processadas aparece em
  `descartes` no `Mesh.Stats.snapshot/0`.

  Compare com `broadcast_serial/1`: a medição está no README.
  """
  def broadcast(payload) do
    Registry.dispatch(
      Mesh.PubSub,
      @topic,
      fn entries ->
        Enum.each(entries, fn {pid, _} -> GenServer.cast(pid, {:deliver, payload}) end)
      end,
      parallel: true
    )
  end

  @doc """
  Difusão paralela **sobre o registro que já existe**, sem segundo registro.

  Lê os pids uma vez (`Registry.select/2`, que é serial) e divide o trabalho de
  envio em lotes processados concorrentemente por `Task.async_stream/3`.

  Existe por dois motivos. O primeiro é não exigir o segundo registro: se você
  não quiser a entrada extra por conexão, esta é a versão a usar. O segundo é
  mais interessante — foi ela que permitiu medir **quanto o segundo registro
  custa de verdade**.

  A primeira medição apontou +72% de memória por conexão para o registro de
  difusão, e o número estava errado: vinha de `:erlang.memory/1` chamado depois
  de milhões de mensagens em voo, ou seja, contava o lixo do próprio benchmark.
  Medido com a mesma carga do `bench/capacity.exs`, o custo real é **+249 bytes
  por conexão, +7%** — e a capacidade máxima da máquina não muda na prática.

  Com isso, `broadcast/1` particionado passou a ser o padrão: ~3x mais rápido
  por 7% de memória. Esta versão fica como alternativa sem custo de registro e
  como a referência que estabeleceu o número.
  """
  def broadcast_chunked(payload, lote \\ 10_000) do
    pids()
    |> Stream.chunk_every(lote)
    |> Task.async_stream(
      fn chunk -> Enum.each(chunk, &GenServer.cast(&1, {:deliver, payload})) end,
      ordered: false,
      max_concurrency: System.schedulers_online(),
      timeout: 60_000
    )
    |> Stream.run()
  end

  @doc """
  Difusão serial, de um processo só. **Mantida apenas para comparação.**

  Era a implementação original de `broadcast/1`, e levava 2,7 s para 700 mil
  conexões contra 228 ms para 100 mil — crescimento pior que linear, porque um
  único processo emitindo centenas de milhares de `cast` é serial por definição.

  Usa o mesmo registro e faz o mesmo trabalho que `broadcast/1`; a única
  diferença é não paralelizar. É o que torna a comparação justa.
  """
  def broadcast_serial(payload) do
    Mesh.PubSub
    |> Registry.lookup(@topic)
    |> Enum.each(fn {pid, _} -> GenServer.cast(pid, {:deliver, payload}) end)
  end

  @doc "Fotografia do mesh. Ver `Mesh.Stats.snapshot/0`."
  def snapshot, do: Mesh.Stats.snapshot()
end
