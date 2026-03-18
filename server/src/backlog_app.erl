-module(backlog_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    Dispatch = cowboy_router:compile([
        {'_', [
            %% Health
            {"/health", backlog_handler, #{action => health}},

            %% Legacy endpoints (preserved)
            {"/api/backlog/tasks", backlog_handler, #{action => list}},
            {"/api/backlog/tasks/:id", backlog_handler, #{action => task}},
            {"/api/backlog/search", backlog_handler, #{action => search}},
            {"/api/id/next", backlog_id_handler, #{action => id_next}},
            {"/api/id/counters", backlog_id_handler, #{action => id_counters}},
            {"/api/id/sync", backlog_id_handler, #{action => id_sync}},

            %% Change Ledger v1 — Organizations & Projects
            {"/api/v1/orgs", ledger_org_handler, #{action => create_org}},
            {"/api/v1/orgs/:org_slug", ledger_org_handler, #{action => get_org}},
            {"/api/v1/orgs/:org_slug/projects", ledger_org_handler, #{action => projects}},
            {"/api/v1/orgs/:org_slug/users", ledger_org_handler, #{action => create_user}},
            {"/api/v1/orgs/:org_slug/users/:username/token", ledger_org_handler, #{action => regen_token}},

            %% Google OAuth
            {"/auth/google", ledger_google_handler, #{action => login}},
            {"/auth/google/callback", ledger_google_handler, #{action => callback}},

            %% Change Ledger v2 — Thin serialization layer
            {"/api/cas/status", ledger_cas_handler, #{action => cas_status}},
            {"/api/cas/status/:org/:project/:task_id", ledger_cas_handler, #{action => cas_get}},
            {"/api/cas/seed", ledger_cas_handler, #{action => cas_seed}},
            {"/api/leases/acquire", ledger_lease_handler, #{action => acquire}},
            {"/api/leases/release", ledger_lease_handler, #{action => release}},
            {"/api/leases/:org/:project", ledger_lease_handler, #{action => list_leases}},
            {"/api/ledger/record", ledger_hash_handler, #{action => record}},
            {"/api/ledger/chain/:org/:project", ledger_hash_handler, #{action => chain}},
            {"/api/ledger/verify/:org/:project", ledger_hash_handler, #{action => verify}},

            %% Change Ledger v1 — Tasks (legacy, will be deprecated)
            {"/api/v1/orgs/:org_slug/projects/:project_slug/tasks",
             ledger_task_handler, #{action => tasks}},
            {"/api/v1/orgs/:org_slug/projects/:project_slug/tasks/:task_id",
             ledger_task_handler, #{action => task}},
            {"/api/v1/orgs/:org_slug/projects/:project_slug/tasks/:task_id/status",
             ledger_task_handler, #{action => task_status}},
            {"/api/v1/orgs/:org_slug/projects/:project_slug/tasks/:task_id/links",
             ledger_task_handler, #{action => task_links}},
            {"/api/v1/orgs/:org_slug/projects/:project_slug/tasks/:task_id/trace",
             ledger_task_handler, #{action => task_trace}},
            {"/api/v1/orgs/:org_slug/projects/:project_slug/tasks/:task_id/lease",
             ledger_task_handler, #{action => task_lease}},

            %% Change Ledger v1 — Audit
            {"/api/v1/orgs/:org_slug/projects/:project_slug/audit",
             ledger_task_handler, #{action => audit}}
        ]}
    ]),
    Port = case os:getenv("BACKLOG_PORT") of
        false ->
            {ok, P} = application:get_env(backlog_server, port),
            P;
        PortStr ->
            list_to_integer(PortStr)
    end,
    {ok, _} = cowboy:start_clear(backlog_http,
        [{port, Port}],
        #{env => #{dispatch => Dispatch}}
    ),
    logger:info("Backlog HTTP server started on port ~p", [Port]),
    {ok, SupPid} = backlog_sup:start_link(),
    %% Bootstrap superadmin orgs on first start (safe to call every time)
    ledger_bootstrap:run(),
    {ok, SupPid}.

stop(_State) ->
    cowboy:stop_listener(backlog_http),
    ok.
