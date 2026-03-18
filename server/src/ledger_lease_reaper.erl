-module(ledger_lease_reaper).
-behaviour(gen_server).

%% Periodically cleans up expired leases.

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(REAP_INTERVAL_MS, 60000). %% 1 minute

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    erlang:send_after(?REAP_INTERVAL_MS, self(), reap),
    {ok, #{}}.

handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(reap, State) ->
    Now = ledger_util:now_iso8601(),
    %% Find expired leases, log audit events, then delete
    Expired = ledger_db:q(
        <<"SELECT l.task_id, l.owner, t.org_id FROM leases l
           JOIN tasks t ON t.id = l.task_id
           WHERE l.expires_at < ?1">>,
        [Now]
    ),
    lists:foreach(fun({TaskId, Owner, OrgId}) ->
        ledger_audit_srv:log(OrgId, null, TaskId, <<"lease.expired">>, Owner, #{}),
        ledger_db:exec(<<"DELETE FROM leases WHERE task_id = ?1">>, [TaskId])
    end, Expired),
    case length(Expired) of
        0 -> ok;
        N -> logger:info("ledger_lease_reaper: reaped ~p expired leases", [N])
    end,
    erlang:send_after(?REAP_INTERVAL_MS, self(), reap),
    {noreply, State}.
