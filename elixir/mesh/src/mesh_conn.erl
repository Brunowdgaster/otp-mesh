%%% @doc Conexão implementada em Erlang puro, equivalente a `Mesh.Connection'.
%%%
%%% == Por que no mesmo projeto, e não num repositório separado ==
%%%
%%% O `mix' compila `src/*.erl' automaticamente, no mesmo app e no mesmo nó. Isso
%%% não é conveniência: é o ponto da demonstração.
%%%
%%% Elixir e Erlang não são linguagens que "interoperam" — elas compilam para o
%%% mesmo bytecode da BEAM e compartilham o mesmo escalonador, o mesmo
%%% `Registry', o mesmo supervisor. Uma conexão Erlang e uma conexão Elixir
%%% convivem na mesma árvore, recebem o mesmo `broadcast', e o `Registry' não
%%% sabe a diferença.
%%%
%%% A prova disso é concreta: `Mesh.broadcast/1' faz `cast' de `{deliver,
%%% Payload}' para o que estiver registrado no tópico. Este módulo trata a mesma
%%% mensagem, com o mesmo átomo, sem nenhuma camada de tradução. Um teste abre
%%% metade das conexões em cada linguagem e verifica que todas recebem.
%%%
%%% == O que muda em relação à versão em Elixir ==
%%%
%%% Nada de semântica: mesma contrapressão por descarte, mesmo limite de fila,
%%% mesmo `restart: temporary' (definido por quem chama o supervisor). Muda a
%%% ergonomia — `-record' em vez de `defstruct', casamento em cláusulas
%%% separadas em vez de `case', e nenhum açúcar de pipe.
%%%
%%% O custo por conexão das duas está medido em `bench/erlang_vs_elixir.exs'.
-module(mesh_conn).
-behaviour(gen_server).

-export([start_link/1, deliver/2, stats/1, via/1, child_spec/1]).
-export([init/1, handle_call/3, handle_cast/2]).

-define(MAX_QUEUE, 100).
-define(TOPIC, <<"all">>).

%% Os nomes de módulo do Elixir, vistos de Erlang, levam o prefixo 'Elixir.'.
%% Não há mágica no meio: é só o átomo que o compilador do Elixir gera.
%%
%% A distinção entre as duas primeiras macros é a origem de um bug que custou
%% cinco testes: no `{via, Modulo, Nome}', o MÓDULO é quem implementa o
%% comportamento de registro — `Registry' — e o NOME é a instância do registro
%% — `Mesh.Registry'. Conflatá-los produz
%% `undef: Mesh.Registry.whereis_name/1', porque `Mesh.Registry' não é módulo:
%% é só um átomo usado como nome de processo.
-define(REG_MOD, 'Elixir.Registry').
-define(REG_NAME, 'Elixir.Mesh.Registry').
-define(PUBSUB_NAME, 'Elixir.Mesh.PubSub').
-define(STATS, 'Elixir.Mesh.Stats').

-record(state, {id, received = 0, dropped = 0}).

%%====================================================================
%% API
%%====================================================================

%% @doc Especificação de filho, com `temporary' pelo mesmo motivo da versão em
%% Elixir: conexão caída não deve reiniciar, o cliente reconecta. Supervisioná-la
%% como `permanent' faria um pico de desconexões estourar `max_restarts' e
%% derrubar a árvore inteira.
child_spec(Id) ->
    #{
        id => {mesh_conn, Id},
        start => {?MODULE, start_link, [Id]},
        restart => temporary,
        type => worker
    }.

start_link(Id) ->
    gen_server:start_link(via(Id), ?MODULE, Id, []).

%% @doc Nome registrado, via o mesmo `Registry' particionado que a versão em
%% Elixir usa.
via(Id) ->
    {via, ?REG_MOD, {?REG_NAME, Id}}.

deliver(Id, Payload) ->
    case ?REG_MOD:lookup(?REG_NAME, Id) of
        [{Pid, _}] -> gen_server:cast(Pid, {deliver, Payload});
        [] -> {error, nao_encontrada}
    end.

stats(Id) ->
    gen_server:call(via(Id), stats).

%%====================================================================
%% gen_server
%%====================================================================

init(Id) ->
    %% Assina o tópico de difusão no registro de chaves duplicadas. É o mesmo
    %% registro da versão em Elixir, então `Registry.dispatch' particionado
    %% alcança as duas sem saber qual é qual.
    {ok, _} = ?REG_MOD:register(?PUBSUB_NAME, ?TOPIC, nil),
    {ok, #state{id = Id}}.

%% A contrapressão é decidida AQUI, dentro do processo que sofre a pressão: só
%% ele conhece o tamanho real da própria fila. Idêntico à versão em Elixir, e
%% deliberadamente — a comparação é de ergonomia, não de algoritmo.
handle_cast({deliver, _Payload}, State) ->
    {message_queue_len, Len} = process_info(self(), message_queue_len),
    case Len > ?MAX_QUEUE of
        true ->
            ?STATS:drop(),
            {noreply, State#state{dropped = State#state.dropped + 1}};
        false ->
            {noreply, State#state{received = State#state.received + 1}}
    end;
handle_cast(_Outro, State) ->
    {noreply, State}.

handle_call(stats, _From, State) ->
    Resposta = #{
        id => State#state.id,
        received => State#state.received,
        dropped => State#state.dropped,
        impl => erlang
    },
    {reply, Resposta, State};
handle_call(_Outro, _From, State) ->
    {reply, {error, chamada_desconhecida}, State}.
