-module(warrant_task_provider).

%% Task provider behaviour + dispatcher.
%% Providers implement 5 callbacks for task CRUD.
%% Traceability (artifact links, audit, hash chain, leases) always
%% lives in warrant's own SQLite regardless of provider.

-export([resolve/2, columns/2]).

%% Behaviour callbacks — every provider must export these.
-callback list(Config :: map(), Filters :: map()) ->
    {ok, [map()]} | {error, term()}.
-callback get(Config :: map(), TaskId :: binary()) ->
    {ok, map()} | {error, not_found | term()}.
-callback create(Config :: map(), Params :: map()) ->
    {ok, map()} | {error, term()}.
-callback update_status(Config :: map(), TaskId :: binary(),
                         NewStatus :: binary(), ExpectedStatus :: binary()) ->
    {ok, map()} | {error, term()}.
-callback search(Config :: map(), Query :: binary()) ->
    {ok, [map()]} | {error, term()}.

%% Optional callback for board columns. Default provided below.
-callback columns(Config :: map()) ->
    [{DisplayName :: binary(), InternalStatus :: binary()}].
-optional_callbacks([columns/1]).

%% Resolve which provider module + config to use for an org/project pair.
-spec resolve(binary(), binary()) -> {module(), map()}.
resolve(OrgId, ProjectId) ->
    case get_provider_setting(OrgId, ProjectId) of
        <<"backlog">> ->
            {warrant_provider_backlog, backlog_config(OrgId, ProjectId)};
        <<"local">> ->
            {warrant_provider_local, local_config(OrgId, ProjectId)};
        _ ->
            {warrant_provider_ledger, #{org_id => OrgId, project_id => ProjectId}}
    end.

%% Return board column definitions for a given org/project.
-spec columns(binary(), binary()) ->
    [{binary(), binary()}].
columns(OrgId, ProjectId) ->
    {Module, Config} = resolve(OrgId, ProjectId),
    case erlang:function_exported(Module, columns, 1) of
        true  -> Module:columns(Config);
        false -> default_columns()
    end.

%%% Internal

get_provider_setting(OrgId, ProjectId) ->
    case ledger_db:one(
        <<"SELECT task_provider FROM projects WHERE id = ?1 AND org_id = ?2">>,
        [ProjectId, OrgId]
    ) of
        {ok, {null}} -> null;
        {ok, {Provider}} -> Provider;
        _ -> null
    end.

backlog_config(OrgId, ProjectId) ->
    ProviderConfig = get_provider_config(OrgId, ProjectId),
    BacklogDir = case ProviderConfig of
        #{<<"backlog_dir">> := Dir} -> Dir;
        _ -> os:getenv("BACKLOG_DIR", "/data")
    end,
    #{org_id => OrgId, project_id => ProjectId, backlog_dir => BacklogDir}.

local_config(OrgId, ProjectId) ->
    ProviderConfig = get_provider_config(OrgId, ProjectId),
    TasksDir = case ProviderConfig of
        #{<<"tasks_dir">> := Dir} -> Dir;
        _ -> ".warrant/tasks"
    end,
    #{org_id => OrgId, project_id => ProjectId, tasks_dir => TasksDir}.

get_provider_config(OrgId, ProjectId) ->
    case ledger_db:one(
        <<"SELECT task_provider_config FROM projects WHERE id = ?1 AND org_id = ?2">>,
        [ProjectId, OrgId]
    ) of
        {ok, {null}} -> #{};
        {ok, {Json}} ->
            try jsx:decode(Json, [return_maps])
            catch _:_ -> #{}
            end;
        _ -> #{}
    end.

default_columns() ->
    [{<<"Open">>, <<"open">>},
     {<<"In Progress">>, <<"in_progress">>},
     {<<"In Review">>, <<"in_review">>},
     {<<"Done">>, <<"done">>},
     {<<"Blocked">>, <<"blocked">>}].
