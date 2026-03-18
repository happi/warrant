-module(ledger_audit_srv).
-behaviour(gen_server).

%% Append-only audit event log.
%% All mutations in the Change Ledger produce an audit event.

-export([start_link/0]).
-export([log/5, log/6, list/2]).
-export([init/1, handle_call/3, handle_cast/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Log an audit event (async — fire and forget)
log(OrgId, ProjectId, TaskId, EventType, Actor) ->
    log(OrgId, ProjectId, TaskId, EventType, Actor, #{}).

log(OrgId, ProjectId, TaskId, EventType, Actor, Detail) ->
    gen_server:cast(?MODULE, {log, OrgId, ProjectId, TaskId, EventType, Actor, Detail}).

%% List audit events with filters
list(OrgId, Filters) ->
    gen_server:call(?MODULE, {list, OrgId, Filters}, 30000).

%%% gen_server callbacks

init([]) ->
    {ok, #{}}.

handle_call({list, OrgId, Filters}, _From, State) ->
    TaskId = maps:get(task_id, Filters, undefined),
    Since = maps:get(since, Filters, undefined),
    Until = maps:get('until', Filters, undefined),
    Limit = maps:get(limit, Filters, 100),
    Offset = maps:get(offset, Filters, 0),

    {SQL, Params} = build_list_query(OrgId, TaskId, Since, Until, Limit, Offset),
    Rows = ledger_db:q(SQL, Params),
    Events = [row_to_event(R) || R <- Rows],
    {reply, {ok, Events}, State}.

handle_cast({log, OrgId, ProjectId, TaskId, EventType, Actor, Detail}, State) ->
    DetailJson = case map_size(Detail) of
        0 -> null;
        _ -> jsx:encode(Detail)
    end,
    Ts = ledger_util:now_iso8601(),
    ledger_db:exec(
        <<"INSERT INTO audit_events (org_id, project_id, task_id, event_type, actor, detail, timestamp)
           VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)">>,
        [OrgId, ProjectId, TaskId, EventType, Actor, DetailJson, Ts]
    ),
    {noreply, State}.

%%% Internal

build_list_query(OrgId, TaskId, Since, Until, Limit, Offset) ->
    Base = <<"SELECT id, org_id, project_id, task_id, event_type, actor, detail, timestamp
             FROM audit_events WHERE org_id = ?1">>,
    {Clauses, Params0} = {[], [OrgId]},
    {C1, P1} = case TaskId of
        undefined -> {Clauses, Params0};
        _ -> {[<<" AND task_id = ?", (integer_to_binary(length(Params0) + 1))/binary>> | Clauses],
              Params0 ++ [TaskId]}
    end,
    {C2, P2} = case Since of
        undefined -> {C1, P1};
        _ -> {[<<" AND timestamp >= ?", (integer_to_binary(length(P1) + 1))/binary>> | C1],
              P1 ++ [Since]}
    end,
    {C3, P3} = case Until of
        undefined -> {C2, P2};
        _ -> {[<<" AND timestamp <= ?", (integer_to_binary(length(P2) + 1))/binary>> | C2],
              P2 ++ [Until]}
    end,
    LimitP = length(P3) + 1,
    OffsetP = LimitP + 1,
    FinalSQL = iolist_to_binary([
        Base,
        lists:reverse(C3),
        <<" ORDER BY id ASC">>,
        <<" LIMIT ?", (integer_to_binary(LimitP))/binary>>,
        <<" OFFSET ?", (integer_to_binary(OffsetP))/binary>>
    ]),
    {FinalSQL, P3 ++ [Limit, Offset]}.

row_to_event({Id, _OrgId, ProjectId, TaskId, EventType, Actor, Detail, Ts}) ->
    Base = #{
        id => Id,
        event_type => EventType,
        actor => Actor,
        timestamp => Ts
    },
    B1 = case ProjectId of null -> Base; _ -> Base#{project_id => ProjectId} end,
    B2 = case TaskId of null -> B1; _ -> B1#{task_id => TaskId} end,
    case Detail of
        null -> B2;
        _ ->
            try jsx:decode(Detail, [return_maps]) of
                Map -> B2#{detail => Map}
            catch _:_ -> B2
            end
    end.
