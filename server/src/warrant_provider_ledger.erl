-module(warrant_provider_ledger).
-behaviour(warrant_task_provider).

%% Provider that delegates to ledger_task_srv (warrant's own SQLite).
%% This is the default provider when no external task system is configured.

-export([list/2, get/2, create/2, update_status/4, search/2, columns/1]).

list(#{org_id := OrgId, project_id := ProjectId}, Filters) ->
    ledger_task_srv:list(OrgId, ProjectId, Filters).

get(#{org_id := OrgId, project_id := ProjectId}, TaskId) ->
    ledger_task_srv:get(OrgId, ProjectId, TaskId).

create(#{org_id := OrgId, project_id := ProjectId}, Params) ->
    Actor = maps:get(actor, Params, <<"ui">>),
    ledger_task_srv:create(OrgId, ProjectId, Params, Actor).

update_status(#{org_id := OrgId, project_id := ProjectId}, TaskId, NewStatus, ExpectedStatus) ->
    ledger_task_srv:update_status(OrgId, ProjectId, TaskId, NewStatus, ExpectedStatus).

search(#{org_id := OrgId, project_id := ProjectId}, Query) ->
    %% Ledger provider: search by title substring via SQL LIKE
    Pattern = <<"%", Query/binary, "%">>,
    Rows = ledger_db:q(
        <<"SELECT id, title, status, priority, assigned_to, updated_at
           FROM tasks WHERE org_id = ?1 AND project_id = ?2 AND title LIKE ?3
           ORDER BY updated_at DESC LIMIT 50">>,
        [OrgId, ProjectId, Pattern]
    ),
    Tasks = [#{id => Id, title => Title, status => Status,
               priority => Priority, assigned_to => AssignedTo,
               updated_at => UpdatedAt}
             || {Id, Title, Status, Priority, AssignedTo, UpdatedAt} <- Rows],
    {ok, Tasks}.

columns(_Config) ->
    [{<<"Open">>, <<"open">>},
     {<<"In Progress">>, <<"in_progress">>},
     {<<"In Review">>, <<"in_review">>},
     {<<"Done">>, <<"done">>},
     {<<"Blocked">>, <<"blocked">>}].
