defmodule Mesh.Application do
  @moduledoc """
  Árvore de supervisão do mesh.

  A ordem dos filhos importa e não é arbitrária: `Registry` e `Stats` precisam
  estar de pé antes que qualquer conexão possa se registrar ou contabilizar, e
  é por isso que o `ConnSupervisor` vem depois. Com `:one_for_one`, cada filho
  reinicia isolado — mas se o `Registry` caísse, as conexões ficariam com
  referências mortas, e é por isso que ele é o primeiro e nunca é derrubado
  pelo caos.

      Mesh.Supervisor              (:one_for_one)
      ├── Mesh.Registry            partitioned, :unique
      ├── Mesh.PubSub              partitioned, :duplicate (difusao)
      ├── Mesh.Stats               GenServer, estado reconstruível
      ├── Mesh.ConnSupervisor      DynamicSupervisor
      │   ├── Mesh.Connection      :temporary
      │   └── ...
      ├── Mesh.Bridge.Supervisor   DynamicSupervisor
      │   └── Mesh.Bridge.Handler  :temporary, um por gateway
      └── Mesh.Bridge              listener TCP, packet: 4

  ## A decisão que mais importa aqui: conexões são `:temporary`

  O erro comum em OTP é supervisionar conexões como `:permanent`. A BEAM
  permite, e o resultado parece correto em teste — até que um pico de
  desconexões estoure a intensidade de reinício do supervisor
  (`max_restarts`/`max_seconds`) e **derrube a árvore inteira**, levando com ela
  as conexões que estavam saudáveis.

  Conexão caída não deve ser reiniciada: o cliente reconecta, e o estado antigo
  não vale mais. Por isso `restart: :temporary` em `Mesh.Connection`, e por isso
  o teste de caos mede que matar 30% das conexões **não** afeta as outras nem o
  supervisor.

  O que é supervisionado para reiniciar é `Mesh.Stats`, cujo estado é
  reconstruível a partir do `Registry` — e o teste de caos mede exatamente essa
  reconstrução.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Registry particionado: uma tabela ETS por partição, o que elimina a
      # contenção de escrita quando milhares de processos se registram ao mesmo
      # tempo. Com uma partição só, o registro vira o gargalo antes da memória.
      {Registry, keys: :unique, name: Mesh.Registry, partitions: System.schedulers_online()},
      # Segundo registro, com chaves DUPLICADAS, usado só para difusão.
      #
      # Ele existe porque `Registry.dispatch/4` com `parallel: true` invoca o
      # callback uma vez por partição, em processos distintos -- ou seja, o
      # fanout particionado já está pronto na biblioteca padrão. A primeira
      # versão deste projeto percorria a lista de pids num processo só e levava
      # 2,7 s para 700 mil conexões; ver o README.
      #
      # O custo é uma entrada ETS a mais por conexão: **+249 bytes, +7%**,
      # medido com a mesma carga do bench/capacity.exs. Compra ~3x na difusão.
      {Registry, keys: :duplicate, name: Mesh.PubSub, partitions: System.schedulers_online()},
      Mesh.Stats,
      {DynamicSupervisor, name: Mesh.ConnSupervisor, strategy: :one_for_one},
      # Supervisor dos handlers da ponte, antes da ponte em si: o aceitador
      # cria filhos aqui, e criar filho num supervisor que ainda nao subiu
      # falharia na primeira conexao de gateway.
      {DynamicSupervisor, name: Mesh.Bridge.Supervisor, strategy: :one_for_one},
      # A porta vem da configuracao. `nil` nao sobe a ponte, `0` deixa o SO
      # escolher -- e o que permite a mesma arvore rodar em teste, em CI e em
      # uso sem disputar porta fixa.
      {Mesh.Bridge, port: Application.get_env(:mesh, :bridge_port)},
      # Telemetria periódica, desligada por padrão: `:ignore` quando o
      # intervalo não está configurado.
      {Mesh.Reporter, interval_ms: Application.get_env(:mesh, :report_interval_ms)}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Mesh.Supervisor)
  end
end
