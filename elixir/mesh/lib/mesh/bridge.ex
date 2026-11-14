defmodule Mesh.Bridge do
  @moduledoc """
  Ponte entre o gateway em Go e o núcleo em Elixir.

  O gateway aceita WebSocket de verdade; o núcleo sustenta um processo por
  conexão. Até esta ponte existir, os dois eram resultados independentes — o
  README dizia isso em vez de insinuar integração, e agora não precisa mais.

  ## O protocolo, e por que TCP cru

  Uma conexão TCP persistente por gateway, multiplexando todos os clientes.
  Cada quadro:

      +--------+------------------+------------------+
      | tipo   | client_id        | payload          |
      | 1 byte | 8 bytes, big-end | resto do quadro  |
      +--------+------------------+------------------+

      tipo 1 = CONNECT     um cliente abriu WebSocket no gateway
      tipo 2 = DISCONNECT  fechou
      tipo 3 = DATA        mandou mensagem
      tipo 4 = PUSH        (núcleo -> gateway) entregar a um cliente

  O enquadramento em si é **da VM**: `packet: 4` faz o `inet` prefixar e
  consumir um tamanho de 32 bits, então nem este módulo nem o lado em Go
  precisam de máquina de estado para "li metade de um quadro". É uma das coisas
  que a BEAM dá de graça e que num runtime comum custa uma biblioteca.

  Alternativas descartadas:

  * **distribuição Erlang** — o lado em Go teria de falar o protocolo de
    distribuição da BEAM, que é desproporcional para três tipos de evento;
  * **NATS** — introduzir um broker num enlace ponto a ponto, e o NATS é outro
    item do roadmap, com propósito diferente (barramento entre nós);
  * **HTTP por evento** — uma requisição por conexão aberta inviabiliza a
    escala que o projeto mede.

  ## Por que a porta é configurável, e 0 desliga

  A árvore de supervisão é a mesma em teste, em CI e em uso. Um listener que
  insiste em tomar uma porta fixa quebra o CI quando a porta está ocupada e
  quebra testes paralelos. Com `0`, o sistema operacional escolhe uma porta
  livre; com `nil`, a ponte não sobe.
  """

  use GenServer
  require Logger

  @tipo_connect 1
  @tipo_disconnect 2
  @tipo_data 3
  @tipo_push 4

  defstruct [:listen_socket, :port, :acceptor]

  # ------------------------------------------------------------------ API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Porta em que a ponte está escutando.

  Útil quando ela subiu com `0`: o teste precisa descobrir qual porta o SO deu.
  """
  def port, do: GenServer.call(__MODULE__, :port)

  @doc "Codifica um quadro. Exposto para que o teste use o mesmo codificador."
  def frame(tipo, client_id, payload \\ <<>>)
      when tipo in [@tipo_connect, @tipo_disconnect, @tipo_data, @tipo_push] do
    <<tipo::8, client_id::big-64, payload::binary>>
  end

  def tipo_connect, do: @tipo_connect
  def tipo_disconnect, do: @tipo_disconnect
  def tipo_data, do: @tipo_data
  def tipo_push, do: @tipo_push

  # --------------------------------------------------------------- callbacks

  @impl true
  def init(opts) do
    case Keyword.get(opts, :port) do
      nil ->
        :ignore

      porta ->
        opcoes = [
          :binary,
          # O enquadramento é da VM: ver o moduledoc.
          packet: 4,
          active: false,
          reuseaddr: true,
          backlog: 128
        ]

        case :gen_tcp.listen(porta, opcoes) do
          {:ok, socket} ->
            {:ok, {_addr, real}} = :inet.sockname(socket)
            Logger.info("Mesh.Bridge escutando na porta #{real}")

            # O laço de aceitação roda em processo PRÓPRIO, ligado a este.
            #
            # A primeira versão aceitava dentro de `handle_continue/2`,
            # devolvendo `{:continue, :aceitar}` a cada iteração. Parece
            # idiomático e está errado: enquanto um GenServer processa
            # continuações ele **não volta à caixa de mensagens**, então
            # `GenServer.call(Mesh.Bridge, :port)` nunca era atendido e sete
            # testes falhavam por timeout de 5 s.
            #
            # Aceitar é uma operação bloqueante e de duração indefinida; quem
            # bloqueia não pode ser o mesmo processo que responde chamadas.
            # Ligado em vez de supervisionado à parte: se o aceitador morrer de
            # verdade, este processo morre com ele e o supervisor reconstrói os
            # dois juntos -- que é o comportamento correto, porque um listener
            # sem aceitador é um listener inútil.
            aceitador = spawn_link(fn -> laco_aceitacao(socket) end)

            {:ok, %__MODULE__{listen_socket: socket, port: real, acceptor: aceitador}}

          {:error, motivo} ->
            {:stop, {:listen_falhou, porta, motivo}}
        end
    end
  end

  # Um processo por gateway conectado, sob o DynamicSupervisor. O aceitador não
  # processa quadro nenhum: se processasse, um gateway lento atrasaria a
  # aceitação dos outros.
  defp laco_aceitacao(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        {:ok, pid} =
          DynamicSupervisor.start_child(
            Mesh.Bridge.Supervisor,
            {Mesh.Bridge.Handler, socket}
          )

        # Transferir a posse do socket é obrigatório: quem chamou accept é o
        # dono, e se o aceitador morrer o socket morre com ele. Esquecer isto
        # produz conexões que fecham sozinhas sem motivo aparente.
        :ok = :gen_tcp.controlling_process(socket, pid)
        Mesh.Bridge.Handler.assumir(pid)
        laco_aceitacao(listen_socket)

      {:error, :closed} ->
        # O listener foi fechado: encerrar normalmente, sem derrubar o pai.
        :ok

      {:error, motivo} ->
        Logger.warning("Mesh.Bridge accept falhou: #{inspect(motivo)}")
        laco_aceitacao(listen_socket)
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl true
  def terminate(_reason, %{listen_socket: s}) when is_port(s) do
    :gen_tcp.close(s)
  end

  def terminate(_reason, _state), do: :ok
end
