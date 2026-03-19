-module(warrant_intent_backlog).
-behaviour(warrant_intent).

%% Backlog.md intent source plugin.
%%
%% Extracts task references like HL-131, SF-42, W-7 from text.
%% Fetches task data by reading backlog/tasks/*.md files or by
%% calling the backlog_srv if running on the server.

-export([source_type/0, extract_refs/2, fetch/2]).

source_type() -> <<"backlog">>.

%% Extract backlog task references from text.
%% Matches patterns like PREFIX-NNN (one or more uppercase letters,
%% dash, one or more digits). Deduplicates.
extract_refs(Text, _Config) ->
    case re:run(Text, "[A-Z]{1,10}-[0-9]+", [global, {capture, first, binary}]) of
        {match, Matches} ->
            Refs = lists:usort([M || [M] <- Matches]),
            Refs;
        nomatch ->
            []
    end.

%% Fetch a backlog task and return it as an intent source.
%% Tries backlog_srv first (server context), then direct file read.
fetch(TaskRef, Config) ->
    case fetch_via_srv(TaskRef) of
        {ok, _} = Result -> Result;
        {error, _} -> fetch_from_file(TaskRef, Config)
    end.

%%% Internal

%% Try to fetch via the running backlog_srv gen_server.
fetch_via_srv(TaskRef) ->
    try
        case backlog_srv:view_task(TaskRef) of
            {ok, Task} when is_map(Task) ->
                Id = make_id(maps:get(id, Task, TaskRef)),
                {ok, #{
                    id => Id,
                    source_type => <<"backlog">>,
                    source_ref => TaskRef,
                    title => maps:get(title, Task, TaskRef),
                    body => maps:get(description, Task, null),
                    author => maps:get(assignee, Task, null),
                    labels => maps:get(labels, Task, []),
                    metadata => #{
                        status => maps:get(status, Task, null),
                        priority => maps:get(priority, Task, null),
                        dependencies => maps:get(dependencies, Task, [])
                    },
                    created_at => maps:get(created, Task,
                        maps:get(created_at, Task, ledger_util:now_iso8601())),
                    updated_at => maps:get(updated_at, Task,
                        maps:get(created, Task, ledger_util:now_iso8601()))
                }};
            _ ->
                {error, not_found}
        end
    catch
        _:_ -> {error, srv_unavailable}
    end.

%% Direct file read — scan tasks directory for a matching file.
fetch_from_file(TaskRef, Config) ->
    TasksDir = maps:get(tasks_dir, Config,
        maps:get(backlog_dir, Config, "backlog/tasks")),
    LowerRef = string:lowercase(TaskRef),
    case file:list_dir(TasksDir) of
        {ok, Files} ->
            case find_task_file(Files, LowerRef) of
                {ok, Filename} ->
                    Path = filename:join(TasksDir, Filename),
                    parse_task_file(Path, TaskRef);
                error ->
                    {error, not_found}
            end;
        {error, _} ->
            {error, not_found}
    end.

find_task_file([], _Ref) -> error;
find_task_file([F | Rest], LowerRef) ->
    LowerF = string:lowercase(unicode:characters_to_binary(F)),
    case binary:match(LowerF, LowerRef) of
        nomatch -> find_task_file(Rest, LowerRef);
        _ -> {ok, F}
    end.

parse_task_file(Path, TaskRef) ->
    case file:read_file(Path) of
        {ok, Content} ->
            FM = parse_frontmatter(Content),
            Title = strip_quotes(maps:get(<<"title">>, FM, TaskRef)),
            Id = make_id(maps:get(<<"id">>, FM, TaskRef)),
            Body = extract_section(Content, <<"Intent">>),
            {ok, #{
                id => Id,
                source_type => <<"backlog">>,
                source_ref => TaskRef,
                title => Title,
                body => Body,
                author => maps:get(<<"created_by">>, FM,
                    maps:get(<<"assignee">>, FM, null)),
                labels => parse_labels(maps:get(<<"labels">>, FM, <<"[]">>)),
                metadata => #{
                    status => maps:get(<<"status">>, FM, null),
                    priority => maps:get(<<"priority">>, FM, null)
                },
                created_at => strip_quotes(maps:get(<<"created_at">>, FM,
                    ledger_util:now_iso8601())),
                updated_at => strip_quotes(maps:get(<<"updated_at">>, FM,
                    maps:get(<<"created_at">>, FM, ledger_util:now_iso8601())))
            }};
        {error, Reason} ->
            {error, Reason}
    end.

make_id(TaskRef) ->
    Ref = ensure_binary(TaskRef),
    <<"backlog:", Ref/binary>>.

parse_frontmatter(Content) ->
    case binary:match(Content, <<"---\n">>) of
        {0, _} ->
            Rest = binary:part(Content, 4, byte_size(Content) - 4),
            case binary:match(Rest, <<"---">>) of
                {EndPos, _} ->
                    Block = binary:part(Rest, 0, EndPos),
                    Lines = binary:split(Block, <<"\n">>, [global]),
                    lists:foldl(fun(Line, Acc) ->
                        case binary:split(Line, <<": ">>) of
                            [Key, Value] when byte_size(Key) > 0 ->
                                Acc#{string:trim(Key) => string:trim(Value)};
                            _ -> Acc
                        end
                    end, #{}, Lines);
                nomatch -> #{}
            end;
        _ -> #{}
    end.

extract_section(Content, Heading) ->
    Pattern = <<"## ", Heading/binary>>,
    case binary:match(Content, Pattern) of
        {Pos, Len} ->
            After = binary:part(Content, Pos + Len, byte_size(Content) - Pos - Len),
            Section = case binary:match(After, <<"\n## ">>) of
                {NPos, _} -> binary:part(After, 0, NPos);
                nomatch -> After
            end,
            case string:trim(Section) of
                <<>> -> null;
                T -> T
            end;
        nomatch -> null
    end.

parse_labels(Raw) ->
    Trimmed = string:trim(Raw),
    Inner = case Trimmed of
        <<"[", R/binary>> ->
            case binary:match(R, <<"]">>) of
                {Pos, _} -> binary:part(R, 0, Pos);
                nomatch -> R
            end;
        _ -> Trimmed
    end,
    [string:trim(L) || L <- binary:split(Inner, <<",">>, [global]),
     string:trim(L) =/= <<>>].

strip_quotes(V) ->
    S = string:trim(ensure_binary(V)),
    case S of
        <<"'", Rest/binary>> -> strip_trailing(Rest, $');
        <<"\"", Rest/binary>> -> strip_trailing(Rest, $");
        _ -> S
    end.

strip_trailing(Bin, Char) ->
    case byte_size(Bin) > 0 andalso binary:last(Bin) =:= Char of
        true -> binary:part(Bin, 0, byte_size(Bin) - 1);
        false -> Bin
    end.

ensure_binary(V) when is_binary(V) -> V;
ensure_binary(V) when is_list(V) -> list_to_binary(V);
ensure_binary(V) when is_atom(V) -> atom_to_binary(V, utf8).
