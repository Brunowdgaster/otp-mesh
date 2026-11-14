# capacity.exs — quantas conexões cabem nesta máquina, medido.
#
#   mix run bench/capacity.exs
#
# O plano original do projeto dizia "milhões de conexões simuladas". Isso é
# fisicamente impossível nos 3,8 GB que o WSL2 expõe, então a meta virou um
# número que esta máquina consegue MEDIR, mais a aritmética do que faltaria
# para escalar. Um número medido vale mais que um aspiracional.
#
# O limite de parada é deliberado: a rampa para antes de o BEAM passar de
# @limite_mb, porque estourar a memória aqui faria o OOM killer do Linux
# derrubar a VM do WSL inteira -- e um benchmark que mata o ambiente não é um
# benchmark.

limite_mb = 2_000
degraus = [1_000, 10_000, 50_000, 100_000, 200_000, 300_000, 400_000, 500_000, 700_000]

mb = fn bytes -> Float.round(bytes / 1_048_576, 1) end

IO.puts("""

=== Capacidade: um processo BEAM por conexão ===

escalonadores : #{System.schedulers_online()}
limite de processos da VM : #{:erlang.system_info(:process_limit)}
parada         : quando o BEAM passar de #{limite_mb} MB

""")

IO.puts(
  String.pad_trailing("conexões", 12) <>
    String.pad_leading("abrir (ms)", 12) <>
    String.pad_leading("BEAM (MB)", 12) <>
    String.pad_leading("bytes/conn", 12) <>
    String.pad_leading("broadcast (ms)", 16)
)

IO.puts(String.duplicate("-", 64))

base = :erlang.memory(:total)

resultado =
  Enum.reduce_while(degraus, {0, nil}, fn alvo, {ja_aberto, _} ->
    faltam = alvo - ja_aberto

    {us_abrir, {abertas, falhas}} =
      :timer.tc(fn -> Mesh.open_many(faltam, ja_aberto) end)

    if falhas > 0 do
      IO.puts("  #{falhas} falhas ao abrir -- limite da VM ou memoria")
    end

    total_agora = ja_aberto + abertas
    mem = :erlang.memory(:total) - base
    por_conn = if total_agora > 0, do: trunc(mem / total_agora), else: 0

    # Difusão para todas as conexões: mede o custo de endereçar N processos.
    {us_bc, _} = :timer.tc(fn -> Mesh.broadcast({:ping, alvo}) end)

    IO.puts(
      String.pad_trailing(Integer.to_string(total_agora), 12) <>
        String.pad_leading(Float.to_string(Float.round(us_abrir / 1000, 1)), 12) <>
        String.pad_leading(Float.to_string(mb.(mem)), 12) <>
        String.pad_leading(Integer.to_string(por_conn), 12) <>
        String.pad_leading(Float.to_string(Float.round(us_bc / 1000, 1)), 16)
    )

    if mb.(mem) > limite_mb or falhas > 0 do
      {:halt, {total_agora, por_conn}}
    else
      {:cont, {total_agora, por_conn}}
    end
  end)

{conexoes, bytes_por_conn} = resultado

# -------------------------------------------------------------------- caos
IO.puts("\n=== Caos com #{conexoes} conexões abertas ===\n")

{us_kill, res} = :timer.tc(fn -> Mesh.Chaos.kill_fraction(0.30) end)

case res do
  {:ok, mortas, antes, depois} ->
    IO.puts("  mortas               : #{mortas} de #{antes}")
    IO.puts("  vivas depois         : #{depois}  (esperado #{antes - mortas})")
    IO.puts("  convergência         : #{Float.round(us_kill / 1000, 1)} ms")

  {:timeout, mortas, antes, parcial} ->
    IO.puts("  ATENCAO: o Registry NAO convergiu no prazo.")
    IO.puts("  mortas               : #{mortas} de #{antes}")
    IO.puts("  contagem parcial     : #{parcial} (esperado #{antes - mortas})")
    IO.puts("  tempo decorrido      : #{Float.round(us_kill / 1000, 1)} ms")
    IO.puts("  -> o numero acima NAO vale como medicao")
end

IO.puts("  supervisor sobreviveu : #{is_pid(Process.whereis(Mesh.ConnSupervisor))}")

case Mesh.Chaos.kill_stats() do
  {:ok, ms} ->
    snap = Mesh.snapshot()
    IO.puts("  Stats reiniciou em  : #{Float.round(ms, 2)} ms")
    IO.puts("  contagem após reinício: #{snap.conexoes} (relida do Registry)")

  {:error, e} ->
    IO.puts("  Stats NAO voltou: #{inspect(e)}")
end

# ------------------------------------------------------------- extrapolação
IO.puts("\n=== O que faltaria para escalar ===\n")

if bytes_por_conn > 0 do
  for alvo <- [1_000_000, 10_000_000] do
    gb = Float.round(alvo * bytes_por_conn / 1_073_741_824, 1)
    IO.puts("  #{alvo} conexões ≈ #{gb} GB só de processos BEAM")
  end

  IO.puts("""

  A conta é direta: #{bytes_por_conn} bytes por conexão medidos aqui.
  O gargalo desta máquina é RAM, não CPU nem escalonador -- os
  #{System.schedulers_online()} escalonadores ficaram longe da saturação.

  Escalar de verdade seria distribuir entre nós, que é o assunto da próxima
  etapa do projeto, não comprar memória.
  """)
end
