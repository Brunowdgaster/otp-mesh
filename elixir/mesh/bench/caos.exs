# caos.exs — convergência do Registry e reinício do Stats, com repetições.
#
#   mix run bench/caos.exs
#   N=200000 REPS=4 mix run bench/caos.exs
#
# ## Por que existe: auditoria
#
# O `capacity.exs` mede o caos com **um** `:timer.tc` e publica o número:
#
#   * convergência em **8.914 ms** para matar 210 mil de 700 mil;
#   * `Stats` reiniciou em **5,83 ms**.
#
# Execução única, sem dispersão. Pelas regras deste repositório (ver
# `docs/AUDITORIA.md`), nenhum dos dois está estabelecido — e o segundo é um
# número pequeno, onde ruído pesa mais.
#
# Este script repete os dois e reporta a faixa.
#
# ## Por que 200 mil e não 700 mil
#
# Repetir em 700 mil exigiria reabrir 210 mil conexões entre as repetições, com
# a máquina já perto do limite de memória (1,9 GiB de 3,8 GiB disponíveis no
# WSL2). A pressão de memória entraria na medição — foi exatamente o defeito
# que a auditoria encontrou na comparação de taxa de criação com o Loom.
#
# Em 200 mil há folga, e a repetição mede convergência em vez de pressão.
#
# O número de 700 mil continua publicado como **capacidade**, que é contagem e
# não tempo.
#
# ## O que cada repetição faz
#
#   1. garante exatamente N conexões abertas;
#   2. mata 30% e mede quanto o `Registry` leva para convergir;
#   3. reabre o que morreu, para a próxima repetição começar igual.
#
# O passo 3 é o que torna as repetições comparáveis. Sem ele, cada repetição
# mataria 30% de uma população menor, e os tempos não seriam da mesma coisa.

n = String.to_integer(System.get_env("N") || "200000")
reps = String.to_integer(System.get_env("REPS") || "4")
fracao = 0.30

fmt = fn x -> Float.round(x, 2) end

disp = fn amostras ->
  mn = Enum.min(amostras)
  mx = Enum.max(amostras)
  if mn <= 0, do: 0.0, else: Float.round((mx - mn) / mn * 100, 1)
end

IO.puts("""

=== Caos, com repetições ===

conexões por repetição : #{n}
fração morta           : #{round(fracao * 100)}%
repetições             : #{reps}
otp                    : #{:erlang.system_info(:otp_release)}
""")

# Garante exatamente `n` conexões, abrindo o que faltar.
#
# ## Os ids NUNCA são reusados, e isso não é detalhe
#
# `Mesh.Chaos.kill_fraction` mata com `Enum.take_random/2`: as vítimas são
# **aleatórias**, então os sobreviventes ficam espalhados em `0..max`.
#
# Reabrir "a partir da contagem atual" colidiria com ids vivos. `Mesh.open/1`
# falharia nessas colisões, `open_many` contaria como erro, e a população
# ficaria **menor que n** — com a repetição seguinte matando 30% de um grupo
# diferente do anterior, sem que nada reclamasse.
#
# Por isso o contador abaixo só cresce, e cada repetição abre ids inéditos.
#
# ## E a espera falha ALTO
#
# A primeira versão desta função esperava a convergência num
# `Enum.reduce_while` de 200 tentativas e **seguia em frente** se estourasse.
# Oitava encarnação da lição deste portfólio: harness que continua depois de
# falhar mede outra coisa e não avisa.
garante = fn proximo_id ->
  atual = Mesh.count()
  faltam = n - atual

  novo_proximo =
    if faltam > 0 do
      {ok, err} = Mesh.open_many(faltam, proximo_id)

      if err > 0 do
        IO.puts("FALHA: #{err} de #{faltam} aberturas deram erro (colisao de id?)")
        System.halt(1)
      end

      if ok < faltam do
        IO.puts("FALHA: abriu #{ok} de #{faltam} conexoes pedidas")
        System.halt(1)
      end

      proximo_id + faltam
    else
      proximo_id
    end

  convergiu =
    Enum.reduce_while(1..400, false, fn _, _ ->
      if Mesh.count() >= n do
        {:halt, true}
      else
        Process.sleep(50)
        {:cont, false}
      end
    end)

  unless convergiu do
    IO.puts("FALHA: o Registry nao chegou a #{n} em 20 s (esta em #{Mesh.count()}).")
    IO.puts("A medicao seria sobre uma populacao diferente da declarada.")
    System.halt(1)
  end

  {Mesh.count(), novo_proximo}
end

IO.puts("abrindo #{n} conexões...")
{abertas, proximo_id} = garante.(0)
IO.puts("abertas: #{abertas}\n")

IO.puts(
  String.pad_trailing("rep", 6) <>
    String.pad_leading("mortas", 10) <>
    String.pad_leading("convergência", 15) <>
    String.pad_leading("vivas", 10) <>
    String.pad_leading("ok?", 6)
)

IO.puts(String.duplicate("-", 47))

{convergencias, _} =
  Enum.map_reduce(1..reps, proximo_id, fn i, prox ->
    {antes, prox2} = garante.(prox)

    {us, res} = :timer.tc(fn -> Mesh.Chaos.kill_fraction(fracao) end)

    {ms, mortas, vivas, ok} =
      case res do
        {:ok, mortas, _antes, depois} ->
          {us / 1000, mortas, depois, true}

        # `kill_fraction` devolve :timeout com contagem PARCIAL quando o
        # Registry não converge no prazo. Tratar isso como medição válida foi
        # um bug anterior deste repositório -- aqui ele é marcado e excluído.
        {:timeout, mortas, _antes, parcial} ->
          {us / 1000, mortas, parcial, false}
      end

    IO.puts(
      String.pad_trailing("#{i}", 6) <>
        String.pad_leading("#{mortas}", 10) <>
        String.pad_leading("#{fmt.(ms)} ms", 15) <>
        String.pad_leading("#{vivas}", 10) <>
        String.pad_leading(if(ok, do: "sim", else: "NAO"), 6)
    )

    {%{ms: ms, mortas: mortas, ok: ok, antes: antes}, prox2}
  end)

validas = Enum.filter(convergencias, & &1.ok)

IO.puts("")

if validas == [] do
  IO.puts("""
  NENHUMA repetição convergiu no prazo. O número de convergência não existe
  nesta configuração -- e isso é um resultado, não uma falha do script.
  """)
else
  ms_lista = Enum.map(validas, & &1.ms)
  mortas_media = round(Enum.sum(Enum.map(validas, & &1.mortas)) / length(validas))

  IO.puts("""
  === Convergência do Registry ===

    repetições válidas : #{length(validas)} de #{reps}
    mortas por rep     : ~#{mortas_media}
    melhor             : #{fmt.(Enum.min(ms_lista))} ms
    pior               : #{fmt.(Enum.max(ms_lista))} ms
    **dispersão        : #{disp.(ms_lista)}%**
  """)
end

# ------------------------------------------------- reinício do Stats
#
# ## A intensidade de reinício é um limite REAL, e ela me pegou
#
# A primeira versão desta seção matava o `Stats` 9 vezes com 120 ms de
# intervalo. Resultado: `{:error, :nao_voltou}` e, na iteração seguinte,
# `Process.exit(nil, :kill)` — porque o `Stats` não existia mais.
#
# A causa é o `Supervisor.start_link(children, strategy: :one_for_one)` da
# `Mesh.Application`, **sem `max_restarts`**: vale o padrão do OTP, que é
# **3 reinícios em 5 segundos**. Estourado o limite, o supervisor desiste e
# derruba a árvore inteira.
#
# Isso não é defeito do sistema: é exatamente o mecanismo que a seção "O erro
# de OTP que este projeto existe para não cometer" descreve, funcionando — e
# funcionando contra o meu benchmark, que era o papel dele.
#
# Então o espaçamento abaixo é de 5,2 s, e o script **confere que o supervisor
# está vivo antes de cada morte**. Se não estiver, para e diz o motivo, em vez
# de estourar com "not a pid" três quadros de pilha abaixo.

reps_stats = String.to_integer(System.get_env("REPS_STATS") || "5")
espaco_ms = 5_200

IO.puts("""
=== Reinício do Stats (#{reps_stats} repetições) ===

espaçamento : #{espaco_ms} ms entre as mortes

A intensidade de reinício padrão do OTP é 3 em 5 s. Matar mais rápido que isso
faz o supervisor DESISTIR e derrubar a árvore -- o que é o comportamento certo,
e o que derrubou a primeira versão desta medição.
""")

# Diagnóstico de estado, usado antes de cada morte.
vivo? = fn nome -> is_pid(Process.whereis(nome)) end

IO.puts("  antes de começar: supervisor=#{vivo?.(Mesh.Supervisor)} stats=#{vivo?.(Mesh.Stats)}")
IO.puts("")

stats_ms =
  Enum.flat_map(1..reps_stats, fn i ->
    cond do
      not vivo?.(Mesh.Supervisor) ->
        IO.puts("""
        PARADO na repetição #{i}: o supervisor NÃO está vivo.

        A árvore caiu. Causa mais provável: intensidade de reinício estourada
        (3 em 5 s é o padrão). As #{length([])} amostras colhidas até aqui não
        bastam para publicar.
        """)

        []

      not vivo?.(Mesh.Stats) ->
        IO.puts("PARADO na repetição #{i}: o Stats não está vivo e o supervisor está.")
        IO.puts("Isso contradiz a supervisão :permanent e merece investigação.")
        []

      true ->
        case Mesh.Chaos.kill_stats() do
          {:ok, ms} ->
            IO.puts("  rep #{i}: #{Float.round(ms, 2)} ms")
            # Espaço maior que a janela de intensidade, para a próxima morte
            # não contar na mesma janela.
            Process.sleep(espaco_ms)
            [ms]

          {:error, e} ->
            IO.puts("  rep #{i}: NAO VOLTOU (#{inspect(e)})")
            IO.puts("  supervisor=#{vivo?.(Mesh.Supervisor)} stats=#{vivo?.(Mesh.Stats)}")
            []
        end
    end
  end)

if stats_ms == [] do
  IO.puts("")
  IO.puts("FALHA: nenhuma amostra de reinício foi colhida. Ver as mensagens acima.")
  System.halt(1)
end

IO.puts("""

  amostras   : #{stats_ms |> Enum.map(&Float.round(&1, 2)) |> Enum.join(", ")} ms
  melhor     : #{fmt.(Enum.min(stats_ms))} ms
  pior       : #{fmt.(Enum.max(stats_ms))} ms
  **dispersão: #{disp.(stats_ms)}%**  (#{length(stats_ms)} amostras)

  supervisor sobreviveu : #{vivo?.(Mesh.Supervisor)}
  contagem após reinício: #{Mesh.snapshot().conexoes} (relida do Registry)

=== Leitura ===

  O que estes números sustentam é a ORDEM DE GRANDEZA e o fato qualitativo:
  o supervisor sobrevive, o Stats volta em MILISSEGUNDOS, e a contagem é
  reconstruída do Registry em vez de restaurada de um estado salvo.

  A medição original publicou 5,83 ms de uma execução única. Compare com a
  faixa acima: se a dispersão for baixa, aquele número era representativo; se
  for alta, era uma amostra.
""")
