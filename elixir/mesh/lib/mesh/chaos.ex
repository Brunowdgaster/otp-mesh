defmodule Mesh.Chaos do
  @moduledoc """
  Injeção de falhas, usada pelos testes e pelo benchmark.

  Não é um enfeite: a afirmação de que a árvore de supervisão funciona só vale
  se alguém a quebrar de propósito. Cada função aqui existe para medir uma
  propriedade diferente:

  * `kill_fraction/1` — matar conexões **não** deve afetar as outras, nem o
    supervisor. Mede o acerto de `restart: :temporary`.
  * `kill_stats/0` — matar um processo `:permanent` com estado reconstruível
    deve resultar em reinício e contagem correta. Mede o acerto da árvore.
  * `flood/2` — saturar uma conexão deve resultar em **descarte contabilizado**,
    não em crescimento de fila sem limite. Mede a contrapressão.
  """

  @doc """
  Mata uma fração aleatória das conexões, de forma abrupta (`Process.exit/2`
  com `:kill`, que não dá chance de terminar limpo).

  Devolve `{:ok, mortas, antes, depois}` quando o `Registry` converge, ou
  `{:timeout, mortas, antes, parcial}` quando não converge no prazo.

  ## Por que o resultado é etiquetado

  A primeira versão devolvia `{mortas, antes, depois}` e, no timeout, entregava
  **a contagem parcial sem avisar**. Com 700 mil conexões a convergência passou
  de 8 s contra um prazo de 5 s, e o benchmark imprimiu "210.000 mortas de
  700.000, 610.523 vivas" — um número que não fecha, porque o `Registry` ainda
  estava limpando.

  É o mesmo defeito que o harness de benchmark do projeto P01 tinha: degradar
  em silêncio. Ferramenta de medição que entrega número errado sem reclamar é
  pior que ferramenta quebrada, porque o número **parece** certo.

  O prazo agora acompanha o tamanho do massacre: desregistrar 200 mil entradas
  não pode ter o mesmo orçamento de tempo que desregistrar 200.
  """
  def kill_fraction(fraction) when fraction > 0 and fraction <= 1 do
    pids = Mesh.pids()
    antes = length(pids)
    alvo = max(1, trunc(antes * fraction))

    vitimas = Enum.take_random(pids, alvo)
    Enum.each(vitimas, &Process.exit(&1, :kill))

    # O desregistro é assíncrono: o Registry monitora cada processo e limpa a
    # entrada ao receber o :DOWN. Sem esperar, a medição pegaria o sistema no
    # meio da limpeza -- mediria o escalonador, não o sistema.
    prazo = max(5_000, alvo)

    case aguarda_convergencia(antes - alvo, prazo) do
      :ok -> {:ok, alvo, antes, Mesh.count()}
      :timeout -> {:timeout, alvo, antes, Mesh.count()}
    end
  end

  @doc """
  Mata o processo `Mesh.Stats` e espera o supervisor trazê-lo de volta.

  Devolve `{:ok, ms}` com o tempo de recuperação, ou `{:error, :nao_voltou}`.
  """
  def kill_stats do
    pid = Process.whereis(Mesh.Stats)
    t0 = System.monotonic_time(:microsecond)
    Process.exit(pid, :kill)

    case aguarda_novo_pid(Mesh.Stats, pid, 5_000) do
      :ok -> {:ok, (System.monotonic_time(:microsecond) - t0) / 1000}
      :timeout -> {:error, :nao_voltou}
    end
  end

  @doc """
  Despeja `n` mensagens numa conexão sem pausa, para forçar a contrapressão.

  Devolve o `stats` da conexão depois do dilúvio.
  """
  def flood(id, n) do
    Enum.each(1..n, fn i -> Mesh.Connection.deliver(id, {:carga, i}) end)
    # Dá tempo de a conexão drenar o que aceitou antes de ler os contadores.
    Process.sleep(200)
    Mesh.Connection.stats(id)
  end

  # ------------------------------------------------------------- auxiliares

  defp aguarda_convergencia(esperado, timeout_ms) do
    fim = System.monotonic_time(:millisecond) + timeout_ms
    loop_convergencia(esperado, fim)
  end

  defp loop_convergencia(esperado, fim) do
    cond do
      Mesh.count() <= esperado ->
        :ok

      System.monotonic_time(:millisecond) > fim ->
        :timeout

      true ->
        Process.sleep(10)
        loop_convergencia(esperado, fim)
    end
  end

  defp aguarda_novo_pid(name, antigo, timeout_ms) do
    fim = System.monotonic_time(:millisecond) + timeout_ms
    loop_novo_pid(name, antigo, fim)
  end

  defp loop_novo_pid(name, antigo, fim) do
    atual = Process.whereis(name)

    cond do
      is_pid(atual) and atual != antigo ->
        :ok

      System.monotonic_time(:millisecond) > fim ->
        :timeout

      true ->
        Process.sleep(5)
        loop_novo_pid(name, antigo, fim)
    end
  end
end
