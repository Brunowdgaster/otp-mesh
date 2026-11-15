# counters_so.exs — SÓ a medição do :counters, para comparação alternada.
#
#   mix run bench/counters_so.exs 8 200000
#
# Par de `clojure/contencao/atomic_so.clj`. Ver `bench/contador_cruzado.sh`.
#
# Imprime UMA linha: `counters <ops_s> <ms> <final>`.

[n_workers, por_worker] =
  case System.argv() do
    [a, b | _] -> [String.to_integer(a), String.to_integer(b)]
    _ -> [8, 200_000]
  end

esperado = n_workers * por_worker
ref = :counters.new(1, [:write_concurrency])
pai = self()

pids =
  for _ <- 1..n_workers do
    spawn_link(fn ->
      receive do
        :va -> :ok
      end

      Enum.each(1..por_worker, fn _ -> :counters.add(ref, 1, 1) end)
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

IO.puts(
  "counters #{round(esperado / max(us / 1_000_000, 0.000001))} " <>
    "#{Float.round(us / 1000, 1)} #{:counters.get(ref, 1)}"
)
