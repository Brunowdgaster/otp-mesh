defmodule Mesh.Bridge.Handler do
  @moduledoc """
  Um processo por gateway conectado. Traduz quadros da ponte em operações no
  núcleo.

  ## `:temporary`, pelo mesmo motivo das conexões

  Se o gateway cai, não há o que reiniciar: o socket morreu e os clientes dele
  também. Reiniciar este processo criaria um handler sem socket. O gateway
  reconecta, e os `Mesh.Connection` que ele tinha aberto são fechados aqui no
  `terminate/2` — senão ficariam órfãos, contando como conexões vivas que já não
  existem.

  Essa limpeza é a diferença entre um número de conexões que significa algo e um
  contador que só sobe.
  """

  use GenServer, restart: :temporary
  require Logger

  alias Mesh.Bridge

  defstruct [:socket, clientes: %{}]

  def start_link(socket), do: GenServer.start_link(__MODULE__, socket)

  @doc "Avisa o handler que ele já é dono do socket e pode começar a ler."
  def assumir(pid), do: GenServer.cast(pid, :assumir)

  @doc """
  Envia um PUSH ao gateway, para entrega a um cliente.

  É o caminho de volta: o núcleo decide, o gateway escreve no WebSocket.
  """
  def push(pid, client_id, payload) do
    GenServer.cast(pid, {:push, client_id, payload})
  end

  @impl true
  def init(socket), do: {:ok, %__MODULE__{socket: socket}}

  @impl true
  def handle_cast(:assumir, state) do
    :ok = :inet.setopts(state.socket, active: :once)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:push, client_id, payload}, state) do
    quadro = Bridge.frame(Bridge.tipo_push(), client_id, payload)
    :gen_tcp.send(state.socket, quadro)
    {:noreply, state}
  end

  # `active: :once` em vez de `active: true`: com `true`, um gateway que
  # despeje quadros mais rápido do que este processo consome enche a caixa de
  # mensagens sem limite -- é contrapressão invertida. Com `:once`, a VM só
  # entrega o próximo quadro depois que este foi tratado.
  @impl true
  def handle_info({:tcp, socket, quadro}, state) do
    novo = trata(quadro, state)
    :ok = :inet.setopts(socket, active: :once)
    {:noreply, novo}
  end

  @impl true
  def handle_info({:tcp_closed, _socket}, state) do
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:tcp_error, _socket, motivo}, state) do
    Logger.warning("ponte: erro de tcp #{inspect(motivo)}")
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_motivo, state) do
    # Fecha as conexões que este gateway abriu. Sem isto, elas ficariam vivas
    # no Registry sem ninguém do outro lado -- e a contagem de conexões
    # deixaria de significar algo.
    Enum.each(Map.keys(state.clientes), &Mesh.close/1)
    :ok
  end

  # ---------------------------------------------------------------- tradução

  defp trata(<<tipo::8, client_id::big-64, payload::binary>>, state) do
    cond do
      tipo == Bridge.tipo_connect() ->
        id = chave(state, client_id)

        case Mesh.open(id) do
          {:ok, _pid} ->
            %{state | clientes: Map.put(state.clientes, id, true)}

          {:error, {:already_started, _}} ->
            # O gateway reusou um id. Não é erro fatal, mas é sintoma: ou ele
            # reiniciou sem avisar, ou há dois gateways com o mesmo prefixo.
            Logger.warning("ponte: CONNECT para id ja existente #{inspect(id)}")
            state
        end

      tipo == Bridge.tipo_disconnect() ->
        id = chave(state, client_id)
        Mesh.close(id)
        %{state | clientes: Map.delete(state.clientes, id)}

      tipo == Bridge.tipo_data() ->
        Mesh.Connection.deliver(chave(state, client_id), payload)
        state

      true ->
        Logger.warning("ponte: tipo de quadro desconhecido #{tipo}")
        state
    end
  end

  defp trata(lixo, state) do
    Logger.warning("ponte: quadro malformado de #{byte_size(lixo)} bytes")
    state
  end

  # O id do cliente é escopado pelo pid do handler.
  #
  # Dois gateways numerando clientes a partir de 1 colidiriam no Registry, que
  # tem `keys: :unique` -- e a colisão apareceria como "already_started" num
  # cliente legítimo. Escopar pelo handler torna os ids globalmente únicos sem
  # exigir coordenação entre gateways.
  defp chave(%{socket: socket}, client_id), do: {:gw, socket, client_id}
end
