# erlang_vs_elixir.exs — a mesma conexão nas duas linguagens, no mesmo nó.
#
#   mix run bench/erlang_vs_elixir.exs
#
# ## O que esta medição pode e não pode dizer
#
# Elixir e Erlang compilam para o **mesmo bytecode da BEAM**. Um `gen_server`
# em Erlang e um `GenServer` em Elixir com o mesmo algoritmo deveriam dar
# números indistinguíveis — e se derem, isso é o resultado, não a ausência
# dele: confirma que a diferença entre as duas é ergonomia, não desempenho.
#
# A medição é no MESMO nó, com as duas implementações alternando, pelo motivo
# que este portfólio já pagou três vezes: números de sessões diferentes não são
# comparáveis.
#
# O que a medição NÃO isola: o `GenServer` do Elixir acrescenta uma camada fina
# sobre o `gen_server` do Erlang (callbacks via `@impl`, tratamento de
# `:continue`). Se aparecer diferença, é dela — não da linguagem.

alias Mesh.Chaos

degraus = [10_000, 50_000, 100_000]
reps = 5

mb = fn b -> Float.round(b / 1_048_576, 1) end

limpa = fn ->
  Enum.each(Mesh.pids(), &DynamicSupervisor.terminate_child(Mesh.ConnSupervisor, &1))

  esperar = fn esperar, n ->
    cond do
      Mesh.count() == 0 -> :ok
      n <= 0 -> {:erro, Mesh.count()}
      true ->
        Process.sleep(20)
        esperar.(esperar, n - 1)
    end
  end

  esperar.(esperar, 500)
  :erlang.garbage_collect()
  Process.sleep(200)
end

IO.puts("""

=== A mesma conexão em Elixir e em Erlang, no mesmo nó BEAM ===

escalonadores : #{System.schedulers_online()}
repetições    : #{reps}, alternadas, melhor tempo

As duas implementações usam o MESMO Registry, o MESMO tópico de difusão e o
MESMO supervisor. Nenhuma camada de tradução entre elas.
""")

IO.puts(
  String.pad_trailing("conexões", 11) <>
    String.pad_leading("abrir ex", 11) <>
    String.pad_leading("abrir erl", 11) <>
    String.pad_leading("bytes ex", 11) <>
    String.pad_leading("bytes erl", 11) <>
    String.pad_leading("difusão ex", 13) <>
    String.pad_leading("difusão erl", 13)
)

IO.puts(String.duplicate("-", 81))

for alvo <- degraus do
  medir = fn abre ->
    tempos =
      for _ <- 1..reps do
        limpa.()
        base = :erlang.memory(:total)
        {us_abrir, {abertas, 0}} = :timer.tc(fn -> abre.(alvo) end)
        mem = :erlang.memory(:total) - base
        Process.sleep(100)
        {us_bc, _} = :timer.tc(fn -> Mesh.broadcast({:b, 1}) end)
        {us_abrir, div(mem, max(abertas, 1)), us_bc}
      end

    {
      tempos |> Enum.map(&elem(&1, 0)) |> Enum.min(),
      tempos |> Enum.map(&elem(&1, 1)) |> Enum.min(),
      tempos |> Enum.map(&elem(&1, 2)) |> Enum.min()
    }
  end

  {ex_abrir, ex_bytes, ex_bc} = medir.(fn n -> Mesh.open_many(n) end)
  {erl_abrir, erl_bytes, erl_bc} = medir.(fn n -> Mesh.open_many_erlang(n) end)

  ms = fn us -> Float.to_string(Float.round(us / 1000, 1)) end

  IO.puts(
    String.pad_trailing(Integer.to_string(alvo), 11) <>
      String.pad_leading(ms.(ex_abrir), 11) <>
      String.pad_leading(ms.(erl_abrir), 11) <>
      String.pad_leading(Integer.to_string(ex_bytes), 11) <>
      String.pad_leading(Integer.to_string(erl_bytes), 11) <>
      String.pad_leading(ms.(ex_bc), 13) <>
      String.pad_leading(ms.(erl_bc), 13)
  )
end

limpa.()

IO.puts("""

Tempos em ms, memória em bytes por conexão.

=== Caos, nas duas implementações ===
""")

for {nome, abre} <- [{"Elixir", &Mesh.open_many/1}, {"Erlang", &Mesh.open_many_erlang/1}] do
  limpa.()
  {20_000, 0} = abre.(20_000)
  sup_antes = Process.whereis(Mesh.ConnSupervisor)

  {us, res} = :timer.tc(fn -> Chaos.kill_fraction(0.3) end)

  case res do
    {:ok, mortas, antes, depois} ->
      IO.puts(
        "  #{String.pad_trailing(nome, 7)} matou #{mortas} de #{antes}, " <>
          "sobraram #{depois}, convergiu em #{Float.round(us / 1000, 1)} ms, " <>
          "supervisor intacto: #{Process.whereis(Mesh.ConnSupervisor) == sup_antes}"
      )

    {:timeout, mortas, antes, parcial} ->
      IO.puts(
        "  #{nome}: NAO CONVERGIU -- matou #{mortas} de #{antes}, " <>
          "contagem parcial #{parcial}; o numero nao vale"
      )
  end
end

limpa.()
