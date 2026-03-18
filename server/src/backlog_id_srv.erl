-module(backlog_id_srv).
-behaviour(gen_server).

%% Centralized task ID counter.
%% Each prefix (sf, hl, vox, ...) has a monotonically increasing counter.
%% State is persisted to counters.json after every increment.

-export([start_link/1, next_id/1, get_counters/0, sync/2]).
-export([init/1, handle_call/3, handle_cast/2]).

-record(state, {
    counters = #{} :: #{binary() => non_neg_integer()},
    file_path :: string()
}).

%%% Public API

start_link(DataDir) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [DataDir], []).

-spec next_id(binary()) -> {ok, #{id := binary(), number := non_neg_integer()}}.
next_id(Prefix) ->
    gen_server:call(?MODULE, {next_id, Prefix}).

-spec get_counters() -> {ok, #{binary() => non_neg_integer()}}.
get_counters() ->
    gen_server:call(?MODULE, get_counters).

-spec sync(binary(), non_neg_integer()) -> ok | {error, term()}.
sync(Prefix, Value) ->
    gen_server:call(?MODULE, {sync, Prefix, Value}).

%%% gen_server callbacks

init([DataDir]) ->
    FilePath = filename:join(DataDir, "counters.json"),
    Counters = load_counters(FilePath),
    logger:info("backlog_id_srv started, counters file: ~s, prefixes: ~p",
                [FilePath, maps:keys(Counters)]),
    {ok, #state{counters = Counters, file_path = FilePath}}.

handle_call({next_id, Prefix}, _From, #state{counters = Counters, file_path = FilePath} = State) ->
    Lower = string:lowercase(Prefix),
    Current = maps:get(Lower, Counters, 0),
    Next = Current + 1,
    NewCounters = Counters#{Lower => Next},
    persist(FilePath, NewCounters),
    Upper = string:uppercase(Lower),
    Id = iolist_to_binary([Upper, $-, integer_to_list(Next)]),
    {reply, {ok, #{id => Id, number => Next}}, State#state{counters = NewCounters}};

handle_call(get_counters, _From, #state{counters = Counters} = State) ->
    {reply, {ok, Counters}, State};

handle_call({sync, Prefix, Value}, _From, #state{counters = Counters, file_path = FilePath} = State) ->
    Lower = string:lowercase(Prefix),
    Current = maps:get(Lower, Counters, 0),
    case Value >= Current of
        true ->
            NewCounters = Counters#{Lower => Value},
            persist(FilePath, NewCounters),
            logger:info("backlog_id_srv: synced ~s to ~p", [Lower, Value]),
            {reply, ok, State#state{counters = NewCounters}};
        false ->
            {reply, {error, <<"Value is less than current counter">>}, State}
    end.

handle_cast(_Msg, State) ->
    {noreply, State}.

%%% Internal

load_counters(FilePath) ->
    case file:read_file(FilePath) of
        {ok, Bin} ->
            try jsx:decode(Bin, [return_maps]) of
                Map when is_map(Map) ->
                    %% Normalize keys to lowercase binaries, values to integers
                    maps:fold(fun(K, V, Acc) ->
                        Key = string:lowercase(to_bin(K)),
                        Val = to_int(V),
                        Acc#{Key => Val}
                    end, #{}, Map)
            catch
                _:_ ->
                    logger:warning("backlog_id_srv: failed to parse ~s, starting empty", [FilePath]),
                    #{}
            end;
        {error, enoent} ->
            #{};
        {error, Reason} ->
            logger:warning("backlog_id_srv: failed to read ~s: ~p", [FilePath, Reason]),
            #{}
    end.

persist(FilePath, Counters) ->
    Json = jsx:encode(Counters, [space, indent]),
    ok = filelib:ensure_dir(FilePath),
    ok = file:write_file(FilePath, Json).

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(L) when is_list(L) -> list_to_binary(L).

to_int(V) when is_integer(V) -> V;
to_int(V) when is_float(V) -> round(V);
to_int(V) when is_binary(V) -> binary_to_integer(V).
