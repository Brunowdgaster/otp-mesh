defmodule Mesh.Stats do
  @moduledoc """
  Contadores globais do mesh.

  ## Por que este processo é supervisionado para reiniciar

  Ao contrário das conexões (`:temporary`), este GenServer é `:permanent`: se
  ele morrer, o supervisor o traz de volta. A razão é que o estado dele é
  **reconstruível** — o número de conexões vivas está no `Registry`, que é a
  fonte de verdade, e não aqui.

  É a distinção que define uma árvore de supervisão útil: processos cujo estado
  pode ser recuperado de outra fonte devem reiniciar; processos cujo estado
  morreu com o cliente não devem. O teste de caos mata este processo e mede que
  a contagem de conexões volta correta — porque é relida do `Registry`, não
  restaurada de um backup.

  Os contadores de entrega e descarte, em troca, **são perdidos no reinício**, e
  isso está declarado: eles são métricas de observação, não estado de negócio.
  Preservá-los exigiria persistência, que custaria escrita em disco no caminho
  quente para proteger um número que serve só para o operador olhar.
  """

  use GenServer

  defstruct delivered: 0, dropped: 0, restarts: 0, started_at: nil

  # ------------------------------------------------------------------ API

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Conta entregas, quando o produtor quiser contabilizar.

  `Mesh.broadcast/1` **não** chama esta função, e a omissão é deliberada: a
  difusão é particionada em um processo por partição do registro, então saber o
  total exigiria ou uma consulta extra ao registro antes do envio, ou juntar os
  resultados dos processos paralelos — e qualquer das duas desfaz o ganho que a
  paralelização trouxe.

  Quem precisa do número conta na ponta: cada `Mesh.Connection` mantém o próprio
  `received`, que é a informação verdadeira — endereçar é uma promessa, receber
  é um fato.
  """
  def delivered(n \\ 1), do: GenServer.cast(__MODULE__, {:delivered, n})

  @doc "Conta uma mensagem descartada por contrapressão."
  def drop, do: GenServer.cast(__MODULE__, :drop)

  @doc """
  Fotografia do estado do mesh.

  `conexoes` é contado no `Registry` **no momento da chamada**, não mantido
  aqui: é o que permite este processo reiniciar sem perder a verdade.
  """
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  # --------------------------------------------------------------- callbacks

  @impl true
  def init(:ok) do
    {:ok, %__MODULE__{started_at: System.monotonic_time(:millisecond)}}
  end

  @impl true
  def handle_cast({:delivered, n}, state),
    do: {:noreply, %{state | delivered: state.delivered + n}}

  @impl true
  def handle_cast(:drop, state), do: {:noreply, %{state | dropped: state.dropped + 1}}

  @impl true
  def handle_call(:snapshot, _from, state) do
    snap = %{
      conexoes: Registry.count(Mesh.Registry),
      entregas: state.delivered,
      descartes: state.dropped,
      uptime_ms: System.monotonic_time(:millisecond) - state.started_at
    }

    {:reply, snap, state}
  end
end
