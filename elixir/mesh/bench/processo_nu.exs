# processo_nu.exs — o custo do processo da BEAM, nu, pelo mesmo método do Scala.
#
#   mix run bench/processo_nu.exs 700000
#
# ## Por que este arquivo existe
#
# O número de manchete do projeto é **3.534 bytes por conexão**, e ele mede uma
# conexão de verdade: um GenServer com estado, registrado em dois `Registry`
# (o `:unique` por id e o `:duplicate` da difusão), com caixa de mensagens.
#
# O `scala/loadgen/Concorrencia.scala` mede **1.323 bytes por thread virtual** —
# e comparar um com o outro seria desonesto, porque a thread virtual de lá só
# bloqueia numa fila. Estado diferente, custo diferente, comparação sem sentido.
#
# Este script mede o **primitivo nu** dos dois lados pelo mesmo método: um
# processo bloqueado em `receive`, nada mais, e o RSS lido de `/proc/self/status`
# antes e depois.
#
# ## Por que RSS, e não `:erlang.memory`
#
# Porque é o que dá para comparar. `:erlang.memory` enxerga o heap da BEAM e
# **não enxerga** as pilhas de threads do sistema operacional — medir a JVM
# assim daria ~0 bytes por thread de plataforma, que é a conclusão errada.
#
# RSS é páginas de fato tocadas, nos dois runtimes, e portanto a única métrica
# que atravessa a fronteira. O preço é que o RSS inclui ruído do alocador: por
# isso a rampa reporta a curva, e não só o ponto final.

alvo =
  case System.argv() do
    [n | _] -> String.to_integer(n)
    [] -> 700_000
  end

rss = fn ->
  "/proc/self/status"
  |> File.read!()
  |> String.split("\n")
  |> Enum.find_value(0, fn linha ->
    case linha do
      "VmRSS:" <> resto ->
        resto |> String.split() |> hd() |> String.to_integer() |> Kernel.*(1024)

      _ ->
        nil
    end
  end)
end

fmt = fn b ->
  cond do
    abs(b) >= 1024 * 1024 -> "#{Float.round(b / 1_048_576, 1)} MiB"
    abs(b) >= 1024 -> "#{Float.round(b / 1024, 1)} KiB"
    true -> "#{b} B"
  end
end

IO.puts("""

=== Custo do processo da BEAM, nu ===

alvo        : #{alvo}
otp         : #{:erlang.system_info(:otp_release)}
escalonadores: #{:erlang.system_info(:schedulers)}
""")

:erlang.garbage_collect()
Process.sleep(100)

rss0 = rss.()
mem0 = :erlang.memory(:total)

IO.puts("  base: RSS #{fmt.(rss0)}, :erlang.memory #{fmt.(mem0)}")
IO.puts("")

IO.puts(
  String.pad_trailing("criados", 10) <>
    String.pad_leading("RSS", 13) <>
    String.pad_leading("erlang.memory", 15) <>
    String.pad_leading("RSS/proc", 12) <>
    String.pad_leading("mem/proc", 12)
)

IO.puts(String.duplicate("-", 62))

marcos =
  Stream.iterate(1000, &(&1 * 2))
  |> Enum.take_while(&(&1 <= alvo))
  |> Kernel.++([alvo])
  |> Enum.uniq()
  |> Enum.sort()

t0 = System.monotonic_time(:millisecond)

# Cada processo bloqueia em receive para sempre. Nada de estado, nada de
# Registry, nada de GenServer -- o primitivo nu, para casar com a thread
# virtual do lado da JVM.
{_pids, _} =
  Enum.reduce(marcos, {[], 0}, fn marco, {pids, criados} ->
    novos =
      for _ <- (criados + 1)..marco do
        spawn(fn ->
          receive do
            :nunca -> :ok
          end
        end)
      end

    :erlang.garbage_collect()
    Process.sleep(60)

    r = rss.()
    m = :erlang.memory(:total)

    IO.puts(
      String.pad_trailing("#{marco}", 10) <>
        String.pad_leading(fmt.(r), 13) <>
        String.pad_leading(fmt.(m), 15) <>
        String.pad_leading("#{div(r - rss0, marco)} B", 12) <>
        String.pad_leading("#{div(m - mem0, marco)} B", 12)
    )

    {novos ++ pids, marco}
  end)

segundos = (System.monotonic_time(:millisecond) - t0) / 1000

:erlang.garbage_collect()
Process.sleep(150)

rss_final = rss.()
mem_final = :erlang.memory(:total)
vivos = length(Process.list())

IO.puts("""

=== Resultado ===

  criados             : #{alvo}
  processos vivos     : #{vivos}
  tempo               : #{Float.round(segundos, 2)} s  (#{round(alvo / max(segundos, 0.001))} por segundo)
  RSS total           : #{fmt.(rss_final)}
  RSS acima da base   : #{fmt.(rss_final - rss0)}
  :erlang.memory acima: #{fmt.(mem_final - mem0)}

  **RSS por processo   : #{div(rss_final - rss0, alvo)} bytes**
  :erlang.memory/proc  : #{div(mem_final - mem0, alvo)} bytes

  A diferenca entre as duas ultimas linhas e o que o RSS ve e o
  :erlang.memory nao: paginas tocadas pelo alocador da BEAM que ainda nao
  foram devolvidas ao sistema. Por isso o numero comparavel com a JVM e o RSS.
""")
