defmodule Mesh.Connection do
  @moduledoc """
  Um processo por conexão. É o objeto que o projeto existe para medir.

  ## Por que um processo por conexão

  É a pergunta que separa a BEAM do resto: num runtime de threads do SO, um
  processo por conexão custa ~1 MB de pilha e o escalonador começa a sofrer na
  casa dos milhares. Na BEAM, um processo nasce com algumas centenas de bytes
  e o escalonador é cooperativo e preemptivo por redução.

  Quanto custa de fato está medido em `bench/capacity.exs` — não estimado.

  ## `:temporary`, e isso é a decisão central

  `restart: :temporary` significa que o supervisor **não** reinicia esta
  conexão quando ela morre. É o correto: cliente caído reconecta, e o estado
  anterior não vale mais. Supervisionar conexão como `:permanent` é o erro
  clássico — um pico de desconexões estoura `max_restarts` e derruba a árvore,
  levando as conexões saudáveis.

  ## Contrapressão

  Cada conexão mede a própria caixa de mensagens antes de aceitar trabalho. Se
  a fila passa de `@max_queue`, a mensagem é **descartada e contabilizada** em
  vez de enfileirada.

  É contrapressão por descarte, não por bloqueio, e a escolha é deliberada:
  bloquear o produtor numa topologia de *fanout* propaga a lentidão de um
  consumidor para todos os outros. Descartar mantém o sistema previsível e
  torna a perda **visível** — `Mesh.Stats` conta cada descarte, e um número de
  descartes é informação, enquanto uma latência que cresce em silêncio não é.
  """

  use GenServer, restart: :temporary

  @max_queue 100
  @topic "all"

  defstruct [:id, received: 0, dropped: 0]

  # ------------------------------------------------------------------ API

  def start_link(id) do
    GenServer.start_link(__MODULE__, id, name: via(id))
  end

  @doc "Nome registrado desta conexão, via Registry particionado."
  def via(id), do: {:via, Registry, {Mesh.Registry, id}}

  @doc "Envia trabalho de forma assíncrona; pode ser descartado por contrapressão."
  def deliver(id, payload) do
    case Registry.lookup(Mesh.Registry, id) do
      [{pid, _}] -> GenServer.cast(pid, {:deliver, payload})
      [] -> {:error, :nao_encontrada}
    end
  end

  @doc "Lê os contadores desta conexão."
  def stats(id), do: GenServer.call(via(id), :stats)

  # --------------------------------------------------------------- callbacks

  @impl true
  def init(id) do
    # Assina o tópico de difusão. O registro em `Mesh.Registry` (único) vem do
    # `:via` no `start_link`; este aqui é o de chaves duplicadas, que permite a
    # difusão particionada.
    {:ok, _} = Registry.register(Mesh.PubSub, @topic, nil)
    {:ok, %__MODULE__{id: id}}
  end

  @impl true
  def handle_cast({:deliver, _payload}, state) do
    # A contrapressão é decidida AQUI, dentro do processo que sofre a pressão,
    # e não no produtor: só este processo sabe o tamanho real da própria fila.
    {:message_queue_len, len} = Process.info(self(), :message_queue_len)

    if len > @max_queue do
      Mesh.Stats.drop()
      {:noreply, %{state | dropped: state.dropped + 1}}
    else
      {:noreply, %{state | received: state.received + 1}}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, %{id: state.id, received: state.received, dropped: state.dropped}, state}
  end
end
