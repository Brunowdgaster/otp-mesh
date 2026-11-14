defmodule Mesh.BridgeTest do
  @moduledoc """
  Testa a ponte pelo **socket**, falando o protocolo byte a byte, em vez de
  chamar as funções do handler.

  A razão é que o outro lado da ponte é escrito em Go, e o que precisa estar
  certo é o formato dos bytes — não a API Elixir. Um teste que chamasse
  `Handler.trata/2` diretamente passaria mesmo se o enquadramento estivesse
  errado, e a falha só apareceria na integração.
  """

  use ExUnit.Case, async: false

  alias Mesh.Bridge

  setup do
    Enum.each(Mesh.pids(), &DynamicSupervisor.terminate_child(Mesh.ConnSupervisor, &1))
    espera(fn -> Mesh.count() == 0 end, 2_000)
    :ok
  end

  defp conecta do
    porta = Bridge.port()
    assert is_integer(porta) and porta > 0, "a ponte nao subiu"

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, porta, [:binary, packet: 4, active: false])

    socket
  end

  defp envia(socket, tipo, id, payload \\ <<>>) do
    :ok = :gen_tcp.send(socket, Bridge.frame(tipo, id, payload))
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

  test "a ponte sobe numa porta que o SO escolheu" do
    assert is_integer(Bridge.port())
    assert Bridge.port() > 0
  end

  test "CONNECT cria uma conexao no nucleo" do
    socket = conecta()

    envia(socket, Bridge.tipo_connect(), 1)
    assert :ok = espera(fn -> Mesh.count() == 1 end, 2_000)

    envia(socket, Bridge.tipo_connect(), 2)
    assert :ok = espera(fn -> Mesh.count() == 2 end, 2_000)

    :gen_tcp.close(socket)
  end

  test "DISCONNECT fecha a conexao" do
    socket = conecta()

    envia(socket, Bridge.tipo_connect(), 10)
    assert :ok = espera(fn -> Mesh.count() == 1 end, 2_000)

    envia(socket, Bridge.tipo_disconnect(), 10)
    assert :ok = espera(fn -> Mesh.count() == 0 end, 2_000)

    :gen_tcp.close(socket)
  end

  test "DATA chega na conexao certa" do
    socket = conecta()

    envia(socket, Bridge.tipo_connect(), 20)
    assert :ok = espera(fn -> Mesh.count() == 1 end, 2_000)

    envia(socket, Bridge.tipo_data(), 20, "ola do gateway")

    # O id visto pelo nucleo e escopado pelo socket do handler, entao o teste
    # nao pode adivinha-lo: pergunta ao Registry qual conexao existe.
    assert :ok =
             espera(
               fn ->
                 case Registry.select(Mesh.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}]) do
                   [id] -> Mesh.Connection.stats(id).received == 1
                   _ -> false
                 end
               end,
               2_000
             )

    :gen_tcp.close(socket)
  end

  test "gateway caindo fecha as conexoes que ele abriu" do
    socket = conecta()

    for id <- 1..5, do: envia(socket, Bridge.tipo_connect(), id)
    assert :ok = espera(fn -> Mesh.count() == 5 end, 2_000)

    # Fecha o socket sem DISCONNECT nenhum: e o que acontece quando o processo
    # do gateway morre. As cinco conexoes tem de ir embora, senao ficariam
    # orfas no Registry e a contagem deixaria de significar algo.
    :gen_tcp.close(socket)

    assert :ok = espera(fn -> Mesh.count() == 0 end, 3_000)
  end

  test "dois gateways podem usar os mesmos ids de cliente" do
    # O Registry tem keys: :unique. Sem escopar o id pelo handler, o segundo
    # gateway colidiria com o primeiro e o sintoma apareceria como
    # "already_started" num cliente legitimo.
    a = conecta()
    b = conecta()

    envia(a, Bridge.tipo_connect(), 1)
    envia(b, Bridge.tipo_connect(), 1)

    assert :ok = espera(fn -> Mesh.count() == 2 end, 2_000)

    :gen_tcp.close(a)
    :gen_tcp.close(b)
  end

  test "quadro malformado nao derruba o handler" do
    socket = conecta()

    envia(socket, Bridge.tipo_connect(), 99)
    assert :ok = espera(fn -> Mesh.count() == 1 end, 2_000)

    # Quadro de 3 bytes: menor que o cabecalho de 9. O handler tem de
    # registrar e seguir, nao morrer -- senao um gateway com bug derrubaria
    # todas as conexoes dele.
    :ok = :gen_tcp.send(socket, <<1, 2, 3>>)

    # A conexao anterior continua de pe, e o handler continua aceitando quadros.
    envia(socket, Bridge.tipo_connect(), 100)
    assert :ok = espera(fn -> Mesh.count() == 2 end, 2_000)

    :gen_tcp.close(socket)
  end
end
