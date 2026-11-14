defmodule Mesh.Reporter do
  @moduledoc """
  Imprime uma linha de telemetria em intervalo fixo.

  Sobe só quando `:mesh, :report_interval_ms` está configurado — o padrão é não
  subir, porque um processo que escreve no log a cada segundo é ruído em uso
  normal e viés em benchmark.

  Existe por um motivo concreto: o teste de integração precisa saber quantas
  conexões o **núcleo** vê, e o jeito óbvio seria um RPC de um nó efêmero. Isso
  exigiria nó distribuído, nome e cookie só para um `assert` — infraestrutura
  desproporcional, e uma fonte de falha que não tem nada a ver com o que está
  sendo testado. Uma linha no log é suficiente e não acrescenta dependência.

  O formato é deliberadamente rasteiro (`chave=valor`) para ser lido com `grep`
  e `cut`, sem parser.
  """

  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    case Keyword.get(opts, :interval_ms) do
      nil ->
        :ignore

      ms when is_integer(ms) and ms > 0 ->
        Process.send_after(self(), :reportar, ms)
        {:ok, ms}
    end
  end

  @impl true
  def handle_info(:reportar, ms) do
    s = Mesh.snapshot()

    Logger.info(
      "conexoes_nucleo=#{s.conexoes} " <>
        "descartes=#{s.descartes} " <>
        "memoria_mb=#{div(:erlang.memory(:total), 1_048_576)} " <>
        "processos=#{:erlang.system_info(:process_count)}"
    )

    Process.send_after(self(), :reportar, ms)
    {:noreply, ms}
  end
end
