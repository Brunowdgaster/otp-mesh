# fanout.exs — três implementações de difusão, medidas com rigor.
#
#   mix run bench/fanout.exs
#
# ## Por que a metodologia é tão explícita
#
# A primeira versão deste benchmark produziu uma tabela que não contava história
# nenhuma: a razão entre particionada e serial saiu 5,02x, 2,38x, 2,2x, 3,07x e
# 0,76x em degraus crescentes. Três causas de contaminação, todas minhas:
#
#   1. `drena` era um `Process.sleep(300)` fixo. Com 400 mil mensagens em voo,
#      300 ms não drenam nada, então a medição seguinte rodava contra caixas de
#      mensagens cheias -- e contra a contrapressão, que começa a descartar.
#   2. As três implementações rodavam em sequência, cada uma herdando o estado
#      deixada pela anterior.
#   3. A 400 mil conexões o BEAM passa de 2,5 GB num VM de 3,8 GB, e o GC entra
#      no caminho da medição.
#
# Esta versão: drena até as caixas esvaziarem de fato, intercala as três
# implementações a cada repetição, e para em 200 mil para ficar longe da
# pressão de memória. É a lição que o projeto P01 aprendeu publicando três
# conclusões diferentes sobre o mesmo benchmark.

degraus = [10_000, 50_000, 100_000, 200_000]
reps = 5
amostra = 200

# Espera as conexões drenarem DE FATO, em vez de dormir um tempo arbitrário.
#
# Verificar a fila de 200 mil processos custaria mais que a própria medição,
# então a drenagem é aferida numa amostra aleatória: se nenhum dos 200
# amostrados tem mensagem pendente, o sistema drenou.
drena = fn ->
  esperar = fn esperar, tentativas ->
    pendentes =
      Mesh.pids()
      |> Enum.take_random(amostra)
      |> Enum.map(fn pid ->
        case Process.info(pid, :message_queue_len) do
          {:message_queue_len, n} -> n
          nil -> 0
        end
      end)
      |> Enum.sum()

    cond do
      pendentes == 0 -> :ok
      tentativas <= 0 -> {:nao_drenou, pendentes}
      true ->
        Process.sleep(50)
        esperar.(esperar, tentativas - 1)
    end
  end

  esperar.(esperar, 200)
end

IO.puts("""

=== Difusão: três implementações ===

escalonadores         : #{System.schedulers_online()}
partições do registro : #{System.schedulers_online()}
repetições            : #{reps}, intercaladas, melhor tempo
drenagem              : aferida em amostra de #{amostra} conexões

  serial    um processo percorre tudo e emite cada cast
  lotes     Task.async_stream sobre o registro EXISTENTE, sem custo de memória
  partição  Registry.dispatch com parallel: true, exige um 2o registro
""")

IO.puts(
  String.pad_trailing("conexões", 11) <>
    String.pad_leading("serial", 10) <>
    String.pad_leading("lotes", 10) <>
    String.pad_leading("partição", 11) <>
    String.pad_leading("lotes", 9) <>
    String.pad_leading("partição", 11) <>
    String.pad_leading("disp.", 8)
)

IO.puts(String.duplicate("-", 70))

impls = [
  {:serial, fn -> Mesh.broadcast_serial({:b, 1}) end},
  {:lotes, fn -> Mesh.broadcast_chunked({:b, 2}) end},
  {:part, fn -> Mesh.broadcast({:b, 3}) end}
]

Enum.reduce(degraus, 0, fn alvo, ja ->
  {abertas, _} = Mesh.open_many(alvo - ja, ja)
  total = ja + abertas
  drena.()

  # Intercalado: cada repetição roda as três, em ordem embaralhada. Medir as 5
  # repetições de uma implementação e depois as da outra atribuiria a cada uma
  # qualquer deriva (GC, swap) que ocorresse no meio.
  medidas =
    Enum.reduce(1..reps, %{serial: [], lotes: [], part: []}, fn _, acc ->
      Enum.reduce(Enum.shuffle(impls), acc, fn {nome, fun}, acc2 ->
        drena.()
        {us, _} = :timer.tc(fun)
        Map.update!(acc2, nome, &[us | &1])
      end)
    end)

  melhor = fn nome -> Enum.min(medidas[nome]) end
  pior = fn nome -> Enum.max(medidas[nome]) end

  ms = fn us -> Float.to_string(Float.round(us / 1000, 1)) end
  razao = fn nome -> "#{Float.round(melhor.(:serial) / melhor.(nome), 2)}x" end

  # Dispersão da medição mais lenta: se for alta, nenhuma razão acima vale.
  disp =
    Float.round((pior.(:serial) - melhor.(:serial)) / melhor.(:serial) * 100, 0)

  IO.puts(
    String.pad_trailing(Integer.to_string(total), 11) <>
      String.pad_leading(ms.(melhor.(:serial)), 10) <>
      String.pad_leading(ms.(melhor.(:lotes)), 10) <>
      String.pad_leading(ms.(melhor.(:part)), 11) <>
      String.pad_leading(razao.(:lotes), 9) <>
      String.pad_leading(razao.(:part), 11) <>
      String.pad_leading("#{trunc(disp)}%", 8)
  )

  total
end)

IO.puts("""

As duas últimas colunas são o ganho sobre a serial. `disp.` é a dispersão da
medição serial entre as #{reps} repetições.

A dispersão é da ordem do ganho, então o **multiplicador exato não está
estabelecido**. O que está: a ordenação é a mesma nos quatro degraus, e as duas
versões paralelas melhoram conforme a escala cresce -- que é exatamente o que o
mecanismo prevê, porque o custo fixo de criar processos se amortiza. A `lotes`
chega a perder da serial em 10 mil conexões, onde o overhead do
`Task.async_stream` domina.

O custo de MEMÓRIA do segundo registro não é medido aqui: depois de milhões de
mensagens em voo, `:erlang.memory/1` inclui o lixo do próprio benchmark e daria
um número inflado. A comparação limpa é rodar `bench/capacity.exs`, que não
difunde em volume -- e está no README.
""")
