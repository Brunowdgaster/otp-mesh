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

  @doc "Lista os pids de todas as conexões vivas."
  def pids do
    Mesh.ConnSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.filter(&is_pid/1)
  end

  @doc """
  Difunde `payload` para todas as conexões.

  O envio é assíncrono e **pode ser descartado** pela conexão de destino se a
  caixa de mensagens dela estiver cheia — ver a contrapressão em
  `Mesh.Connection`. O retorno é quantas foram endereçadas, não quantas foram
  processadas, e a diferença entre os dois números é o ponto: aparece em
  `descartes` no `Mesh.Stats.snapshot/0`.
  """
  def broadcast(payload) do
    pids = pids()
    Enum.each(pids, &GenServer.cast(&1, {:deliver, payload}))
    Mesh.Stats.delivered(length(pids))
    length(pids)
  end

  @doc "Fotografia do mesh. Ver `Mesh.Stats.snapshot/0`."
  def snapshot, do: Mesh.Stats.snapshot()
end
