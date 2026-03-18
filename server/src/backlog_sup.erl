-module(backlog_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    DataDir = case os:getenv("BACKLOG_DATA_DIR") of
        false -> ".";
        Dir -> Dir
    end,
    Children = [
        %% Legacy services
        #{id => backlog_srv,
          start => {backlog_srv, start_link, []},
          restart => permanent},
        #{id => backlog_id_srv,
          start => {backlog_id_srv, start_link, [DataDir]},
          restart => permanent},
        %% Change Ledger services
        #{id => ledger_db,
          start => {ledger_db, start_link, [DataDir]},
          restart => permanent},
        #{id => ledger_audit_srv,
          start => {ledger_audit_srv, start_link, []},
          restart => permanent},
        #{id => ledger_task_srv,
          start => {ledger_task_srv, start_link, []},
          restart => permanent},
        #{id => ledger_lease_reaper,
          start => {ledger_lease_reaper, start_link, []},
          restart => permanent}
    ],
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, Children}}.
