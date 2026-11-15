# genserver_so.exs — SÓ a medição do GenServer, para comparação alternada.
#
#   mix run bench/genserver_so.exs 8 200000
#
# Par de `clojure/contencao/agent_so.clj`. Ver o comentário de lá: a comparação
# publicada entre os dois modelos tinha 8% de diferença, medida sem alternância
# entre as plataformas — dentro do que carga de fundo explica.
#
# Imprime UMA linha: `genserver <ops_s> <ms> <final>`.

[n_workers, por_worker] =
  case System.argv() do
    [a, b | _] -> [String.to_integer(a), String.to_integer(b)]
    _ -> [8, 200_000]
  end

esperado = n_workers * por_worker

defmodule C do
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, 0, name: __MODULE__)
  def init(n), do: {:ok, n}
  def inc, do: GenServer.call(__MODULE__, :inc)
  def valor, do: GenServer.call(__MODULE__, :valor, 300_000)
  def handle_call(:inc, _d, n), do: {:reply, :ok, n + 1}
  def handle_call(:valor, _d, n), do: {:reply, n, n}
end

{:ok, _} = C.start_link(nil)
pai = self()

pids =
  for _ <- 1..n_workers do
    spawn_link(fn ->
      receive do
        :va -> :ok
      end

      Enum.each(1..por_worker, fn _ -> C.inc() end)
      send(pai, :feito)
    end)
  end

t0 = System.monotonic_time(:microsecond)
Enum.each(pids, &send(&1, :va))

for _ <- 1..n_workers do
  receive do
    :feito -> :ok
  after
    300_000 -> raise "trabalhador nao terminou"
  end
end

us = System.monotonic_time(:microsecond) - t0
final = C.valor()

IO.puts(
  "genserver #{round(esperado / max(us / 1_000_000, 0.000001))} " <>
    "#{Float.round(us / 1000, 1)} #{final}"
)
