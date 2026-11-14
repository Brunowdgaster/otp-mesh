defmodule Mesh.Application do
  @moduledoc """
  Árvore de supervisão do mesh.

  A ordem dos filhos importa e não é arbitrária: `Registry` e `Stats` precisam
  estar de pé antes que qualquer conexão possa se registrar ou contabilizar, e
  é por isso que o `ConnSupervisor` vem depois. Com `:one_for_one`, cada filho
  reinicia isolado — mas se o `Registry` caísse, as conexões ficariam com
  referências mortas, e é por isso que ele é o primeiro e nunca é derrubado
  pelo caos.

      Mesh.Supervisor            (:one_for_one)
      ├── Mesh.Registry          partitioned, :unique
      ├── Mesh.Stats             GenServer, estado reconstruível
      └── Mesh.ConnSupervisor    DynamicSupervisor
          ├── Mesh.Connection    :temporary
          ├── Mesh.Connection    :temporary
          └── ...

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
      Mesh.Stats,
      {DynamicSupervisor, name: Mesh.ConnSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Mesh.Supervisor)
  end
end
