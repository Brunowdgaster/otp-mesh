defmodule Mesh.ErlangTest do
  @moduledoc """
  Prova que Elixir e Erlang não "interoperam" — são a mesma plataforma.

  Cada teste aqui falharia se houvesse qualquer camada de tradução entre as
  duas implementações de conexão.
  """

  use ExUnit.Case, async: false

  setup do
    Enum.each(Mesh.pids(), &DynamicSupervisor.terminate_child(Mesh.ConnSupervisor, &1))
    espera(fn -> Mesh.count() == 0 end, 2_000)
    :ok
  end

  defp espera(fun, timeout) do
    fim = System.monotonic_time(:millisecond) + timeout
    loop(fun, fim)
  end

  defp loop(fun, fim) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > fim ->
        :timeout

      true ->
        Process.sleep(5)
        loop(fun, fim)
    end
  end

  test "conexao em Erlang abre no mesmo supervisor e registro" do
    assert {:ok, pid} = Mesh.open_erlang("erl-1")
    assert is_pid(pid)
    assert Mesh.count() == 1
    assert [{^pid, _}] = Registry.lookup(Mesh.Registry, "erl-1")

    stats = Mesh.stats_de("erl-1")
    assert stats.impl == :erlang
    assert stats.received == 0
  end

  test "as duas implementacoes convivem na mesma arvore" do
    {:ok, _} = Mesh.open("elixir-1")
    {:ok, _} = Mesh.open_erlang("erlang-1")

    assert Mesh.count() == 2
    # O supervisor nao distingue: para ele sao dois workers.
    assert length(DynamicSupervisor.which_children(Mesh.ConnSupervisor)) == 2

    assert Mesh.stats_de("erlang-1").impl == :erlang
    refute Map.has_key?(Mesh.stats_de("elixir-1"), :impl)
  end

  test "broadcast alcanca as duas sem saber qual e qual" do
    # Metade em cada linguagem, intercaladas no mesmo topico de difusao.
    for i <- 1..20 do
      if rem(i, 2) == 0 do
        {:ok, _} = Mesh.open({:ex, i})
      else
        {:ok, _} = Mesh.open_erlang({:erl, i})
      end
    end

    assert Mesh.count() == 20
    assert :ok = Mesh.broadcast({:oi, 1})

    ids =
      Registry.select(Mesh.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])

    assert :ok =
             espera(
               fn ->
                 Enum.all?(ids, fn id -> Mesh.stats_de(id).received == 1 end)
               end,
               3_000
             )

    # E as duas metades existem de fato: o teste nao estaria medindo nada se
    # todas fossem da mesma implementacao.
    por_impl = Enum.group_by(ids, fn id -> Map.get(Mesh.stats_de(id), :impl, :elixir) end)
    assert length(por_impl[:erlang]) == 10
    assert length(por_impl[:elixir]) == 10
  end

  test "contrapressao em Erlang tem a mesma invariante" do
    {:ok, _} = Mesh.open_erlang("afogada-erl")

    Enum.each(1..5000, fn i -> :mesh_conn.deliver("afogada-erl", {:carga, i}) end)
    Process.sleep(300)

    s = Mesh.stats_de("afogada-erl")

    assert s.received + s.dropped == 5000,
           "aceitas + descartadas tem de fechar, como na versao em Elixir"

    assert s.dropped > 0, "com 5000 de uma vez a contrapressao tinha de atuar"
  end

  test "caos derruba conexoes Erlang sem afetar o supervisor" do
    {_, 0} = Mesh.open_many_erlang(200)
    sup_antes = Process.whereis(Mesh.ConnSupervisor)

    assert {:ok, mortas, antes, depois} = Mesh.Chaos.kill_fraction(0.5)

    assert antes == 200
    assert mortas == 100
    assert depois == 100
    # `temporary` vale igual: as mortas nao voltam e o supervisor sobrevive.
    assert Process.whereis(Mesh.ConnSupervisor) == sup_antes
  end
end
