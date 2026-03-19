-module(warrant_provider_backlog).
-behaviour(warrant_task_provider).

%% Provider that delegates to backlog_srv (Backlog.md CLI).
%% Tasks live in git-tracked markdown files. Warrant provides
%% traceability on top (artifact links, audit, hash chain, leases).

-export([list/2, get/2, create/2, update_status/4, search/2, columns/1]).

list(_Config, Filters) ->
    Opts = normalize_filters(Filters),
    case backlog_srv:list_tasks(Opts) of
        {ok, Tasks} -> {ok, [normalize_task(T) || T <- Tasks]};
        Error -> Error
    end.

get(_Config, TaskId) ->
    case backlog_srv:view_task(TaskId) of
        {ok, Task} -> {ok, normalize_task(Task)};
        Error -> Error
    end.

create(_Config, Params) ->
    backlog_srv:create_task(Params).

update_status(_Config, TaskId, NewStatus, _ExpectedStatus) ->
    DisplayStatus = internal_to_display(NewStatus),
    backlog_srv:edit_task(TaskId, #{status => DisplayStatus}).

search(_Config, Query) ->
    case backlog_srv:search_tasks(Query) of
        {ok, Tasks} -> {ok, [normalize_task(T) || T <- Tasks]};
        Error -> Error
    end.

columns(_Config) ->
    [{<<"To Do">>, <<"open">>},
     {<<"In Progress">>, <<"in_progress">>},
     {<<"Done">>, <<"done">>}].

%%% Internal — status normalization

%% Backlog.md uses display names ("To Do", "In Progress", "Done").
%% Warrant uses internal names ("open", "in_progress", "done").

normalize_task(Task) ->
    Status = maps:get(status, Task, <<"unknown">>),
    NormalizedStatus = display_to_internal(Status),
    Defaults = #{
        id => maps:get(id, Task, <<>>),
        title => maps:get(title, Task, <<>>),
        status => NormalizedStatus,
        priority => maps:get(priority, Task, null),
        labels => maps:get(labels, Task, []),
        assigned_to => maps:get(assignee, Task, maps:get(assigned_to, Task, null)),
        created_at => maps:get(created, Task, maps:get(created_at, Task, <<>>)),
        updated_at => maps:get(updated_at, Task, maps:get(created, Task, <<>>)),
        created_by => maps:get(created_by, Task, <<>>),
        intent => maps:get(description, Task, maps:get(intent, Task, null))
    },
    maps:merge(Defaults, maps:with([id, title, priority, labels], Task)).

display_to_internal(<<"To Do">>) -> <<"open">>;
display_to_internal(<<"In Progress">>) -> <<"in_progress">>;
display_to_internal(<<"In Review">>) -> <<"in_review">>;
display_to_internal(<<"Done">>) -> <<"done">>;
display_to_internal(<<"Blocked">>) -> <<"blocked">>;
display_to_internal(<<"Cancelled">>) -> <<"cancelled">>;
%% Already internal format
display_to_internal(<<"open">>) -> <<"open">>;
display_to_internal(<<"in_progress">>) -> <<"in_progress">>;
display_to_internal(<<"in_review">>) -> <<"in_review">>;
display_to_internal(<<"done">>) -> <<"done">>;
display_to_internal(<<"blocked">>) -> <<"blocked">>;
display_to_internal(Other) -> Other.

internal_to_display(<<"open">>) -> <<"To Do">>;
internal_to_display(<<"in_progress">>) -> <<"In Progress">>;
internal_to_display(<<"in_review">>) -> <<"In Review">>;
internal_to_display(<<"done">>) -> <<"Done">>;
internal_to_display(<<"blocked">>) -> <<"Blocked">>;
internal_to_display(<<"cancelled">>) -> <<"Cancelled">>;
internal_to_display(Other) -> Other.

normalize_filters(Filters) ->
    maps:fold(fun
        (status, V, Acc) -> Acc#{status => internal_to_display(V)};
        (assigned_to, V, Acc) -> Acc#{assignee => V};
        (K, V, Acc) -> Acc#{K => V}
    end, #{}, Filters).
