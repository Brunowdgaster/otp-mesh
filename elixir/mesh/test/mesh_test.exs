defmodule MeshTest do
  @moduledoc """
  A suíte testa as propriedades que o projeto afirma, não a API.

  Cada teste corresponde a uma frase do README, e é o que impede o README de
  virar prosa: se a propriedade deixar de valer, o teste quebra.
  """

  use ExUnit.Case, async: false

  setup do
    # Fecha o que sobrou de um teste anterior. `async: false` porque todos
    # compartilham a mesma árvore de supervisão -- paralelizar aqui mediria
    # interferência entre testes, não o sistema.
    Enum.each(Mesh.pids(), &DynamicSupervisor.terminate_child(Mesh.ConnSupervisor, &1))
    # Espera o Registry esvaziar: terminate_child devolve :ok antes de o
    # Registry processar o :DOWN, e sem esta espera um teste herdava conexoes
    # do anterior -- que foi a causa de a suite falhar em ~2 de 12 execucoes.
    wait_until(fn -> Mesh.count() == 0 end, 2_000)
    :ok
  end

  describe "ciclo de vida" do
    test "abre, registra e fecha" do
      assert {:ok, pid} = Mesh.open("c1")
      assert is_pid(pid)
      assert Mesh.count() == 1
      assert [{^pid, _}] = Registry.lookup(Mesh.Registry, "c1")

      assert :ok = Mesh.close("c1")
      assert Mesh.count() == 0
    end

    test "close/1 e sincrono em relacao ao Registry" do
      # terminate_child devolve :ok antes de o Registry limpar a entrada.
      # close/1 espera por isso; sem a espera, esta sequencia falhava de forma
      # intermitente, e o bug estava na API, nao no teste.
      {:ok, _} = Mesh.open("sinc")
      assert Mesh.count() == 1
      assert :ok = Mesh.close("sinc")
      assert Mesh.count() == 0, "close/1 retornou antes de o Registry convergir"
    end

    test "Registry com keys: :unique recusa id duplicado" do
      {:ok, _} = Mesh.open("dup")
      assert {:error, {:already_started, _}} = Mesh.open("dup")
      assert Mesh.count() == 1
    end

    test "abre mil conexões sem falha" do
      assert {1000, 0} = Mesh.open_many(1000)
      assert Mesh.count() == 1000
    end
  end

  describe "caos: conexões são :temporary" do
    test "matar 30% não afeta as outras nem o supervisor" do
      {1000, 0} = Mesh.open_many(1000)
      sup_antes = Process.whereis(Mesh.ConnSupervisor)

      assert {:ok, mortas, antes, depois} = Mesh.Chaos.kill_fraction(0.30)

      assert mortas == 300
      assert antes == 1000
      # 1. As mortas não voltaram: é o efeito de :temporary. Se voltassem, um
      #    pico de desconexões viraria uma tempestade de reinícios.
      assert depois == 700
      # 2. O supervisor é o MESMO processo: não foi derrubado por intensidade
      #    de reinício. É a propriedade que :permanent quebraria.
      assert Process.whereis(Mesh.ConnSupervisor) == sup_antes
      # 3. As sobreviventes continuam atendendo.
      assert %{received: _} = Mesh.Connection.stats(hd(sobreviventes()))
    end

    test "matar tudo deixa o sistema vazio e utilizável" do
      {500, 0} = Mesh.open_many(500)
      assert {:ok, _, _, depois} = Mesh.Chaos.kill_fraction(1.0)
      assert depois == 0
      # o sistema continua aceitando conexão nova depois do extermínio
      assert {:ok, _} = Mesh.open("depois-do-caos")
      assert Mesh.count() == 1
    end
  end

  describe "caos: Stats é :permanent com estado reconstruível" do
    test "reinicia e a contagem de conexões volta correta" do
      {100, 0} = Mesh.open_many(100)
      antes = Mesh.snapshot()
      assert antes.conexoes == 100

      assert {:ok, ms} = Mesh.Chaos.kill_stats()
      assert ms < 1000, "recuperacao levou #{ms} ms"

      depois = Mesh.snapshot()
      # A contagem volta certa porque é LIDA DO REGISTRY, não restaurada de um
      # backup. É a diferença entre estado reconstruível e estado perdido.
      assert depois.conexoes == 100
      # Já os contadores de observação zeraram, e isso é declarado, não um bug.
      assert depois.entregas == 0
    end
  end

  describe "contrapressão" do
    test "conexão saturada descarta e contabiliza, em vez de crescer sem limite" do
      {:ok, _} = Mesh.open("afogada")

      stats = Mesh.Chaos.flood("afogada", 5000)

      assert stats.received + stats.dropped == 5000,
             "toda mensagem tem de ser aceita ou descartada, nunca perdida em silencio"

      assert stats.dropped > 0,
             "com 5000 mensagens de uma vez, a contrapressao tinha de atuar"

      # A fila não ficou crescendo: o processo drenou tudo.
      {:message_queue_len, len} = Process.info(Process.whereis(Mesh.Registry), :message_queue_len)
      assert len < 100
    end

    test "broadcast particionado chega em todas as conexoes" do
      # A versao anterior deste teste verificava o RETORNO do broadcast (quantas
      # foram enderecadas). Com a difusao particionada nao ha retorno util: a
      # contagem exigiria uma consulta extra ou juntar resultados dos processos
      # paralelos, o que desfaria o ganho. Verificar a CHEGADA e melhor teste de
      # qualquer forma -- enderecar e uma promessa, receber e um fato.
      {50, 0} = Mesh.open_many(50)
      assert :ok = Mesh.broadcast({:oi, 1})
      wait_until(fn -> recebidas(0..49) == 50 end, 2_000)
      assert recebidas(0..49) == 50
    end

    test "serial e particionado entregam o mesmo" do
      {30, 0} = Mesh.open_many(30)

      Mesh.broadcast_serial({:a, 1})
      wait_until(fn -> recebidas(0..29) == 30 end, 2_000)
      assert recebidas(0..29) == 30

      Mesh.broadcast({:b, 2})
      wait_until(fn -> recebidas(0..29) == 60 end, 2_000)
      assert recebidas(0..29) == 60
    end
  end

  defp recebidas(faixa) do
    faixa |> Enum.map(&Mesh.Connection.stats(&1).received) |> Enum.sum()
  end

  defp wait_until(fun, timeout_ms) do
    fim = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(fun, fim)
  end

  defp do_wait(fun, fim) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > fim ->
        :timeout

      true ->
        Process.sleep(5)
        do_wait(fun, fim)
    end
  end

  defp sobreviventes do
    Registry.select(Mesh.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end
end
