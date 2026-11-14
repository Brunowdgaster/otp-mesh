# preempcao.exs — o que os 2.732 bytes do processo da BEAM compram.
#
#   mix run bench/preempcao.exs 4 2
#
# ## O par deste arquivo
#
# `scala/loadgen/Preempcao.scala` roda o mesmo experimento na JVM e mede
# **inanição completa**: com 4 threads virtuais em laço fechado sobre 2
# carregadoras, uma thread virtual nova **não rodou em 10 segundos**. A latência
# foi de 0,318 ms para o teto do cronômetro.
#
# A razão é de projeto: threads virtuais são escalonadas **cooperativamente** e
# um laço sem ponto de bloqueio nunca cede o carregador.
#
# A BEAM escalona por **contagem de reduções**: cada processo recebe um orçamento
# de ~4.000 reduções e é interrompido quando o gasta, queira ou não. Este script
# mede se essa promessa se sustenta sob a mesma carga.
#
# ## Espelhando o experimento
#
# A JVM foi limitada a 2 threads carregadoras. Aqui, `schedulers_online` é
# reduzido ao mesmo número — sem isso a BEAM usaria os 8 núcleos, sobrariam
# escalonadores livres, e o teste não teria medido preempção nenhuma: teria
# medido que havia núcleo sobrando.
#
# É o detalhe que decide se o resultado significa algo.

[ocupados, escalonadores] =
  case System.argv() do
    [a, b | _] -> [String.to_integer(a), String.to_integer(b)]
    _ -> [4, 2]
  end

antes = :erlang.system_info(:schedulers_online)
:erlang.system_flag(:schedulers_online, escalonadores)

IO.puts("""

=== Latencia de atendimento sob carga de CPU (BEAM) ===

processos em laco fechado : #{ocupados}
escalonadores online      : #{:erlang.system_info(:schedulers_online)} (de #{antes})
otp                       : #{:erlang.system_info(:otp_release)}

Escalonamento da BEAM e PREEMPTIVO por contagem de reducoes: o processo que
calcula e interrompido ao gastar seu orcamento, queira ou nao.
""")

# Mede quanto tempo um processo novo demora para rodar sua primeira instrucao.
# Mesma definicao do lado da JVM, para os numeros serem comparaveis.
latencia = fn ->
  pai = self()
  t0 = System.monotonic_time(:nanosecond)

  spawn(fn -> send(pai, {:pronto, self()}) end)

  receive do
    {:pronto, _} -> (System.monotonic_time(:nanosecond) - t0) / 1_000_000
  after
    # Mesmo teto de 10 s do lado da JVM. Sem ele, inanicao real penduraria o
    # script e o resultado seria "travou" em vez de um numero.
    10_000 -> 10_000.0
  end
end

melhor = fn n -> 1..n |> Enum.map(fn _ -> latencia.() end) |> Enum.min() end

sem_carga = melhor.(5)
IO.puts("  1. sem carga        : #{Float.round(sem_carga, 3)} ms")

# Laco fechado de verdade: nada de receive, nada de sleep, nada de I/O. Na BEAM
# nem ha como "ceder" explicitamente -- o escalonador tira o processo a forca.
pai = self()

hogs =
  for _ <- 1..ocupados do
    spawn(fn ->
      send(pai, :em_laco)
      girar = fn f, x -> f.(f, x + 1) end
      girar.(girar, 0)
    end)
  end

# Espera os hogs entrarem no laco antes de medir. Sem isto, a medicao
# aconteceria antes de a carga existir.
for _ <- 1..ocupados do
  receive do
    :em_laco -> :ok
  after
    5_000 -> :ok
  end
end

Process.sleep(300)

com_carga = melhor.(5)
IO.puts("  2. sob carga de CPU : #{Float.round(com_carga, 3)} ms")

Enum.each(hogs, &Process.exit(&1, :kill))
:erlang.system_flag(:schedulers_online, antes)

fator = if sem_carga > 0, do: com_carga / sem_carga, else: 0.0

IO.puts("""

=== Resultado (BEAM, processos) ===

  latencia sem carga  : #{Float.round(sem_carga, 3)} ms
  latencia sob carga  : #{Float.round(com_carga, 3)} ms
  **degradacao        : #{Float.round(fator, 1)}x**
""")

if com_carga < 100 do
  IO.puts("""
  O processo novo foi atendido mesmo com todos os escalonadores ocupados por
  lacos fechados. O escalonador interrompeu os hogs a forca.

  Compare com a JVM no mesmo experimento: 10.000 ms, isto e, NUNCA. A thread
  virtual e mais barata em memoria (1.323 contra 2.732 bytes) justamente
  porque nao carrega o que faz isto funcionar.
  """)
else
  IO.puts("""
  A latencia tambem degradou aqui, o que contraria a promessa da plataforma.
  Antes de publicar: confira se os hogs sao de fato lacos fechados (um
  `receive` no meio viraria ponto de cedencia) e se schedulers_online foi
  aplicado.
  """)
end
