-module(warrant_provider_local).
-behaviour(warrant_task_provider).

%% Provider that reads .warrant/tasks/*.md files from disk.
%% Simplest case — no external deps, tasks are git-tracked markdown.

-export([list/2, get/2, create/2, update_status/4, search/2, columns/1]).

list(#{tasks_dir := TasksDir}, Filters) ->
    case file:list_dir(TasksDir) of
        {ok, Files} ->
            MdFiles = [F || F <- Files, filename:extension(F) =:= ".md"],
            Tasks = lists:filtermap(fun(F) ->
                Path = filename:join(TasksDir, F),
                case parse_task_file(Path) of
                    {ok, Task} ->
                        case matches_filters(Task, Filters) of
                            true -> {true, Task};
                            false -> false
                        end;
                    error -> false
                end
            end, MdFiles),
            {ok, Tasks};
        {error, Reason} ->
            {error, Reason}
    end.

get(#{tasks_dir := TasksDir}, TaskId) ->
    case find_task_file(TasksDir, TaskId) of
        {ok, Path} ->
            parse_task_file(Path);
        error ->
            {error, not_found}
    end.

create(#{tasks_dir := TasksDir} = Config, Params) ->
    Title = maps:get(title, Params, <<"Untitled">>),
    Priority = maps:get(priority, Params, <<"medium">>),
    Labels = maps:get(labels, Params, []),
    Intent = maps:get(intent, Params, null),

    %% Allocate ID: try server, fall back to local counter
    TaskId = allocate_id(Config),
    Now = ledger_util:now_iso8601(),

    LabelsYaml = case Labels of
        [] -> <<"[]">>;
        _ -> iolist_to_binary([<<"[">>, lists:join(<<", ">>, Labels), <<"]">>])
    end,

    Content = iolist_to_binary([
        <<"---\n">>,
        <<"id: ">>, TaskId, <<"\n">>,
        <<"title: \"">>, Title, <<"\"\n">>,
        <<"status: open\n">>,
        <<"priority: ">>, ensure_binary(Priority), <<"\n">>,
        <<"labels: ">>, LabelsYaml, <<"\n">>,
        <<"created_by: system\n">>,
        <<"created_at: '">>, Now, <<"'\n">>,
        <<"---\n\n">>,
        <<"## Intent\n\n">>,
        case Intent of null -> <<"No intent specified.">>; _ -> Intent end,
        <<"\n">>
    ]),

    Filename = <<(string:lowercase(TaskId))/binary, ".md">>,
    Path = filename:join(TasksDir, Filename),
    case file:write_file(Path, Content) of
        ok ->
            {ok, #{id => TaskId, title => Title, status => <<"open">>,
                   priority => Priority, labels => Labels,
                   created_at => Now, updated_at => Now}};
        {error, Reason} ->
            {error, Reason}
    end.

update_status(#{tasks_dir := TasksDir}, TaskId, NewStatus, ExpectedStatus) ->
    case find_task_file(TasksDir, TaskId) of
        {ok, Path} ->
            {ok, Content} = file:read_file(Path),
            case extract_frontmatter_status(Content) of
                {ok, CurrentStatus} when CurrentStatus =:= ExpectedStatus ->
                    NewContent = replace_frontmatter_field(Content, <<"status">>, NewStatus),
                    Now = ledger_util:now_iso8601(),
                    FinalContent = replace_frontmatter_field(NewContent, <<"updated_at">>, Now),
                    ok = file:write_file(Path, FinalContent),
                    {ok, #{id => TaskId, status => NewStatus,
                           previous_status => CurrentStatus, updated_at => Now}};
                {ok, CurrentStatus} ->
                    {error, {conflict, CurrentStatus, ExpectedStatus}};
                error ->
                    {error, parse_error}
            end;
        error ->
            {error, not_found}
    end.

search(#{tasks_dir := TasksDir}, Query) ->
    case list(#{tasks_dir => TasksDir}, #{}) of
        {ok, AllTasks} ->
            LowerQuery = string:lowercase(Query),
            Matched = [T || #{title := Title, id := Id} = T <- AllTasks,
                        string:find(string:lowercase(Title), LowerQuery) =/= nomatch
                        orelse string:find(string:lowercase(Id), LowerQuery) =/= nomatch],
            {ok, Matched};
        Error ->
            Error
    end.

columns(_Config) ->
    [{<<"Open">>, <<"open">>},
     {<<"In Progress">>, <<"in_progress">>},
     {<<"In Review">>, <<"in_review">>},
     {<<"Done">>, <<"done">>},
     {<<"Blocked">>, <<"blocked">>}].

%%% Internal

find_task_file(TasksDir, TaskId) ->
    %% Try exact ID.md first
    Direct = filename:join(TasksDir, <<TaskId/binary, ".md">>),
    case filelib:is_regular(Direct) of
        true -> {ok, Direct};
        false ->
            %% Try case-insensitive and title-format (prefix-N - Title.md)
            LowerId = string:lowercase(TaskId),
            case file:list_dir(TasksDir) of
                {ok, Files} ->
                    case lists:search(fun(F) ->
                        LowerF = string:lowercase(unicode:characters_to_binary(F)),
                        binary:match(LowerF, LowerId) =/= nomatch
                    end, Files) of
                        {value, Found} ->
                            {ok, filename:join(TasksDir, Found)};
                        false ->
                            error
                    end;
                _ -> error
            end
    end.

parse_task_file(Path) ->
    case file:read_file(Path) of
        {ok, Content} ->
            case parse_frontmatter(Content) of
                {ok, FM} ->
                    {ok, #{
                        id => maps:get(<<"id">>, FM, filename:basename(Path, ".md")),
                        title => strip_quotes(maps:get(<<"title">>, FM, <<>>)),
                        status => maps:get(<<"status">>, FM, <<"open">>),
                        priority => maps:get(<<"priority">>, FM, null),
                        labels => parse_labels(maps:get(<<"labels">>, FM, <<"[]">>)),
                        assigned_to => maps:get(<<"assigned_to">>, FM, null),
                        created_by => maps:get(<<"created_by">>, FM, <<>>),
                        created_at => strip_quotes(maps:get(<<"created_at">>, FM, <<>>)),
                        updated_at => strip_quotes(maps:get(<<"updated_at">>, FM,
                            maps:get(<<"created_at">>, FM, <<>>))),
                        intent => extract_section(Content, <<"Intent">>)
                    }};
                error -> error
            end;
        _ -> error
    end.

parse_frontmatter(Content) ->
    case binary:match(Content, <<"---\n">>) of
        {0, _} ->
            Rest = binary:part(Content, 4, byte_size(Content) - 4),
            case binary:match(Rest, <<"---">>) of
                {EndPos, _} ->
                    FMBlock = binary:part(Rest, 0, EndPos),
                    Lines = binary:split(FMBlock, <<"\n">>, [global]),
                    FM = lists:foldl(fun(Line, Acc) ->
                        case binary:split(Line, <<": ">>) of
                            [Key, Value] when byte_size(Key) > 0 ->
                                Acc#{string:trim(Key) => string:trim(Value)};
                            _ -> Acc
                        end
                    end, #{}, Lines),
                    {ok, FM};
                nomatch -> error
            end;
        _ -> error
    end.

parse_labels(Raw) ->
    Trimmed = string:trim(Raw),
    Inner = case Trimmed of
        <<"[", Rest/binary>> ->
            case binary:match(Rest, <<"]">>) of
                {Pos, _} -> binary:part(Rest, 0, Pos);
                nomatch -> Rest
            end;
        _ -> Trimmed
    end,
    [string:trim(L) || L <- binary:split(Inner, <<",">>, [global]),
     string:trim(L) =/= <<>>].

strip_quotes(V) ->
    S = string:trim(V),
    case S of
        <<"'", Rest/binary>> ->
            case binary:match(Rest, <<"'">>) of
                {Pos, _} -> binary:part(Rest, 0, Pos);
                nomatch -> Rest
            end;
        <<"\"", Rest/binary>> ->
            case binary:match(Rest, <<"\"">>) of
                {Pos, _} -> binary:part(Rest, 0, Pos);
                nomatch -> Rest
            end;
        _ -> S
    end.

extract_section(Content, Heading) ->
    Pattern = <<"## ", Heading/binary>>,
    case binary:match(Content, Pattern) of
        {Pos, Len} ->
            After = binary:part(Content, Pos + Len, byte_size(Content) - Pos - Len),
            %% Find next heading or end
            Section = case binary:match(After, <<"\n## ">>) of
                {NextPos, _} -> binary:part(After, 0, NextPos);
                nomatch -> After
            end,
            Trimmed = string:trim(Section),
            case Trimmed of
                <<>> -> null;
                _ -> Trimmed
            end;
        nomatch -> null
    end.

extract_frontmatter_status(Content) ->
    case parse_frontmatter(Content) of
        {ok, FM} -> {ok, maps:get(<<"status">>, FM, <<"open">>)};
        error -> error
    end.

replace_frontmatter_field(Content, Field, NewValue) ->
    Pattern = <<Field/binary, ": ">>,
    case binary:match(Content, Pattern) of
        {Pos, Len} ->
            Before = binary:part(Content, 0, Pos + Len),
            After = binary:part(Content, Pos + Len, byte_size(Content) - Pos - Len),
            %% Find end of line
            LineEnd = case binary:match(After, <<"\n">>) of
                {EPos, _} -> EPos;
                nomatch -> byte_size(After)
            end,
            Rest = binary:part(After, LineEnd, byte_size(After) - LineEnd),
            <<Before/binary, NewValue/binary, Rest/binary>>;
        nomatch ->
            Content
    end.

matches_filters(Task, Filters) ->
    maps:fold(fun
        (status, V, Acc) -> Acc andalso maps:get(status, Task, <<>>) =:= V;
        (assigned_to, V, Acc) -> Acc andalso maps:get(assigned_to, Task, null) =:= V;
        (label, V, Acc) -> Acc andalso lists:member(V, maps:get(labels, Task, []));
        (_, _, Acc) -> Acc
    end, true, Filters).

allocate_id(#{org_id := OrgId, project_id := ProjectId}) ->
    case ledger_db:one(
        <<"SELECT prefix FROM projects WHERE id = ?1 AND org_id = ?2">>,
        [ProjectId, OrgId]
    ) of
        {ok, {Prefix}} ->
            {ok, #{id := TaskId}} = backlog_id_srv:next_id(Prefix),
            TaskId;
        _ ->
            %% Fallback
            iolist_to_binary([<<"W-">>, integer_to_binary(erlang:unique_integer([positive]))])
    end.

ensure_binary(null) -> <<"medium">>;
ensure_binary(V) when is_binary(V) -> V;
ensure_binary(V) when is_list(V) -> list_to_binary(V);
ensure_binary(V) when is_atom(V) -> atom_to_binary(V, utf8).
