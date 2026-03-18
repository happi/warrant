-module(backlog_srv).
-behaviour(gen_server).

-export([start_link/0]).
-export([list_tasks/1, view_task/1, search_tasks/1, create_task/1, edit_task/2]).
-export([init/1, handle_call/3, handle_cast/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

list_tasks(Opts) -> gen_server:call(?MODULE, {list, Opts}, 30000).
view_task(Id) -> gen_server:call(?MODULE, {view, Id}, 30000).
search_tasks(Query) -> gen_server:call(?MODULE, {search, Query}, 30000).
create_task(Params) -> gen_server:call(?MODULE, {create, Params}, 30000).
edit_task(Id, Params) -> gen_server:call(?MODULE, {edit, Id, Params}, 30000).

init([]) ->
    {ok, Dir0} = application:get_env(backlog_server, backlog_dir),
    Dir = case os:getenv("BACKLOG_DIR") of
        false -> Dir0;
        EnvDir -> EnvDir
    end,
    Bin = resolve_backlog_bin(),
    logger:info("Backlog server using binary: ~s, dir: ~s", [Bin, Dir]),
    {ok, #{backlog_dir => Dir, backlog_bin => Bin}}.

handle_call({list, Opts}, _From, #{backlog_dir := Dir, backlog_bin := Bin} = State) ->
    Cmd = build_list_cmd(Dir, Bin, Opts),
    Output = run_cmd(Cmd),
    Tasks = parse_list_output(Output),
    {reply, {ok, Tasks}, State};

handle_call({view, Id}, _From, #{backlog_dir := Dir, backlog_bin := Bin} = State) ->
    Cmd = io_lib:format("cd ~s && ~s task view ~s --plain 2>&1",
                        [shell_escape(Dir), Bin, shell_escape(to_list(Id))]),
    Output = run_cmd(Cmd),
    Task = parse_view_output(Output),
    {reply, {ok, Task}, State};

handle_call({search, Query}, _From, #{backlog_dir := Dir, backlog_bin := Bin} = State) ->
    Cmd = io_lib:format("cd ~s && ~s search ~s --plain 2>&1",
                        [shell_escape(Dir), Bin, shell_escape(to_list(Query))]),
    Output = run_cmd(Cmd),
    Results = parse_search_output(Output),
    {reply, {ok, Results}, State};

handle_call({create, Params}, _From, #{backlog_dir := Dir, backlog_bin := Bin} = State) ->
    Cmd = build_create_cmd(Dir, Bin, Params),
    Output = run_cmd(Cmd),
    {reply, {ok, #{raw => Output}}, State};

handle_call({edit, Id, Params}, _From, #{backlog_dir := Dir, backlog_bin := Bin} = State) ->
    Cmd = build_edit_cmd(Dir, Bin, Id, Params),
    Output = run_cmd(Cmd),
    {reply, {ok, #{raw => Output}}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% Internal functions

run_cmd(Cmd) ->
    %% os:cmd returns a char list which may contain non-byte Unicode codepoints.
    %% Convert to binary immediately to avoid re:run badarg on UTF-8 text.
    unicode:characters_to_binary(os:cmd(lists:flatten(Cmd))).

build_list_cmd(Dir, Bin, Opts) ->
    Base = io_lib:format("cd ~s && ~s task list --plain", [shell_escape(Dir), Bin]),
    Parts = [Base] ++
        case maps:get(status, Opts, undefined) of
            undefined -> [];
            Status -> [io_lib:format(" --status ~s", [shell_escape(to_list(Status))])]
        end ++
        case maps:get(assignee, Opts, undefined) of
            undefined -> [];
            Assignee -> [io_lib:format(" --assignee ~s", [shell_escape(to_list(Assignee))])]
        end ++
        case maps:get(priority, Opts, undefined) of
            undefined -> [];
            Priority -> [io_lib:format(" --priority ~s", [shell_escape(to_list(Priority))])]
        end ++
        [" 2>&1"],
    lists:flatten(Parts).

build_create_cmd(Dir, Bin, Params) ->
    Title = maps:get(title, Params, <<"Untitled">>),
    Base = io_lib:format("cd ~s && ~s task create ~s --plain",
                         [shell_escape(Dir), Bin, shell_escape(to_list(Title))]),
    Parts = [Base] ++
        case maps:get(description, Params, undefined) of
            undefined -> [];
            Desc -> [io_lib:format(" --description ~s", [shell_escape(to_list(Desc))])]
        end ++
        case maps:get(priority, Params, undefined) of
            undefined -> [];
            Pri -> [io_lib:format(" --priority ~s", [shell_escape(to_list(Pri))])]
        end ++
        case maps:get(labels, Params, undefined) of
            undefined -> [];
            Labels -> [io_lib:format(" --labels ~s", [shell_escape(to_list(Labels))])]
        end ++
        case maps:get(status, Params, undefined) of
            undefined -> [];
            Status -> [io_lib:format(" --status ~s", [shell_escape(to_list(Status))])]
        end ++
        case maps:get(parent, Params, undefined) of
            undefined -> [];
            Parent -> [io_lib:format(" --parent ~s", [shell_escape(to_list(Parent))])]
        end ++
        [" 2>&1"],
    lists:flatten(Parts).

build_edit_cmd(Dir, Bin, Id, Params) ->
    Base = io_lib:format("cd ~s && ~s task edit ~s --plain",
                         [shell_escape(Dir), Bin, shell_escape(to_list(Id))]),
    Parts = [Base] ++
        case maps:get(status, Params, undefined) of
            undefined -> [];
            Status -> [io_lib:format(" --status ~s", [shell_escape(to_list(Status))])]
        end ++
        case maps:get(assignee, Params, undefined) of
            undefined -> [];
            Assignee -> [io_lib:format(" --assignee ~s", [shell_escape(to_list(Assignee))])]
        end ++
        case maps:get(priority, Params, undefined) of
            undefined -> [];
            Pri -> [io_lib:format(" --priority ~s", [shell_escape(to_list(Pri))])]
        end ++
        case maps:get(title, Params, undefined) of
            undefined -> [];
            Title -> [io_lib:format(" --title ~s", [shell_escape(to_list(Title))])]
        end ++
        case maps:get(description, Params, undefined) of
            undefined -> [];
            Desc -> [io_lib:format(" --description ~s", [shell_escape(to_list(Desc))])]
        end ++
        case maps:get(labels, Params, undefined) of
            undefined -> [];
            Labels -> [io_lib:format(" --label ~s", [shell_escape(to_list(Labels))])]
        end ++
        case maps:get(notes, Params, undefined) of
            undefined -> [];
            Notes -> [io_lib:format(" --append-notes ~s", [shell_escape(to_list(Notes))])]
        end ++
        [" 2>&1"],
    lists:flatten(Parts).

%% Parse "backlog task list --plain" output
%% Format:
%% To Do:
%%   [HIGH] TASK-34 - Diplomacy system (treaties/contracts)
%%   [MEDIUM] TASK-40 - Define 10-turn core loop
parse_list_output(Output) ->
    Lines = binary:split(Output, <<"\n">>, [global]),
    parse_list_lines(Lines, <<"unknown">>, []).

parse_list_lines([], _CurrentStatus, Acc) ->
    lists:reverse(Acc);
parse_list_lines([Line | Rest], CurrentStatus, Acc) ->
    Trimmed = string:trim(Line),
    case Trimmed of
        <<>> ->
            parse_list_lines(Rest, CurrentStatus, Acc);
        _ ->
            case parse_task_line(Trimmed) of
                {ok, Task} ->
                    parse_list_lines(Rest, CurrentStatus,
                                    [Task#{status => CurrentStatus} | Acc]);
                error ->
                    %% Check if it's a status header like "To Do:" or "In Progress:"
                    case binary:last(Trimmed) of
                        $: ->
                            StatusStr = binary:part(Trimmed, 0, byte_size(Trimmed) - 1),
                            parse_list_lines(Rest, StatusStr, Acc);
                        _ ->
                            parse_list_lines(Rest, CurrentStatus, Acc)
                    end
            end
    end.

%% Parse line like: [HIGH] TASK-34 - Diplomacy system (treaties/contracts)
parse_task_line(Line) ->
    case re:run(Line, "\\[(HIGH|MEDIUM|LOW)\\]\\s+(TASK-\\S+)\\s+-\\s+(.+)",
                [{capture, all_but_first, binary}]) of
        {match, [Priority, Id, Title]} ->
            {ok, #{id => Id,
                   title => string:trim(Title),
                   priority => string:lowercase(Priority)}};
        nomatch ->
            error
    end.

%% Parse "backlog task view --plain" output
parse_view_output(Output) ->
    Lines = binary:split(Output, <<"\n">>, [global]),
    parse_view_lines(Lines, #{}, undefined).

parse_view_lines([], Acc, _Section) ->
    Acc;
parse_view_lines([Line | Rest], Acc, Section) ->
    Trimmed = string:trim(Line),
    case Trimmed of
        <<>> ->
            parse_view_lines(Rest, Acc, Section);
        <<"==================================================">> ->
            parse_view_lines(Rest, Acc, Section);
        <<"--------------------------------------------------">> ->
            parse_view_lines(Rest, Acc, Section);
        _ ->
            case parse_view_field(Trimmed) of
                {<<"Status">>, Val} ->
                    Clean = re:replace(Val, "^[^A-Za-z]*", "", [{return, binary}]),
                    parse_view_lines(Rest, Acc#{status => string:trim(Clean)}, Section);
                {<<"Priority">>, Val} ->
                    parse_view_lines(Rest, Acc#{priority => string:lowercase(Val)}, Section);
                {<<"Labels">>, Val} ->
                    Labels = [string:trim(L) || L <- binary:split(Val, <<",">>, [global])],
                    parse_view_lines(Rest, Acc#{labels => Labels}, Section);
                {<<"Dependencies">>, Val} ->
                    Deps = [string:trim(D) || D <- binary:split(Val, <<",">>, [global])],
                    parse_view_lines(Rest, Acc#{dependencies => Deps}, Section);
                {<<"Assignee">>, Val} ->
                    parse_view_lines(Rest, Acc#{assignee => Val}, Section);
                {<<"Parent">>, Val} ->
                    parse_view_lines(Rest, Acc#{parent => Val}, Section);
                {<<"Created">>, Val} ->
                    parse_view_lines(Rest, Acc#{created => Val}, Section);
                {<<"Task">>, TaskInfo} ->
                    parse_view_lines(Rest, maps:merge(Acc, TaskInfo), Section);
                {_Key, _Val} ->
                    parse_view_lines(Rest, Acc, Section);
                section ->
                    NewSection = case Trimmed of
                        <<"Description:">> -> description;
                        <<"Acceptance Criteria:">> -> acceptance_criteria;
                        <<"Implementation Plan:">> -> plan;
                        <<"Implementation Notes:">> -> notes;
                        _ -> Section
                    end,
                    parse_view_lines(Rest, Acc, NewSection);
                text when Section =:= description ->
                    Existing = maps:get(description, Acc, <<>>),
                    New = case Existing of
                        <<>> -> Trimmed;
                        _ -> <<Existing/binary, "\n", Trimmed/binary>>
                    end,
                    parse_view_lines(Rest, Acc#{description => New}, Section);
                text when Section =:= acceptance_criteria ->
                    Existing = maps:get(acceptance_criteria, Acc, []),
                    parse_view_lines(Rest, Acc#{acceptance_criteria => Existing ++ [Trimmed]}, Section);
                text ->
                    parse_view_lines(Rest, Acc, Section)
            end
    end.

parse_view_field(Line) ->
    %% Check for "Task TASK-XX - Title" header
    case re:run(Line, "^Task (TASK-\\S+) - (.+)", [{capture, all_but_first, binary}]) of
        {match, [Id, Title]} ->
            {<<"Task">>, #{id => Id, title => Title}};
        nomatch ->
            %% Check for section headers
            case lists:member(Line, [<<"Description:">>, <<"Acceptance Criteria:">>,
                                      <<"Implementation Plan:">>, <<"Implementation Notes:">>,
                                      <<"Definition of Done:">>]) of
                true -> section;
                false ->
                    %% Check for "Key: Value" pattern
                    case binary:split(Line, <<": ">>) of
                        [Key, Value] when byte_size(Key) < 30 ->
                            {Key, Value};
                        _ ->
                            text
                    end
            end
    end.

%% Parse "backlog search --plain" output
parse_search_output(Output) ->
    Lines = binary:split(Output, <<"\n">>, [global]),
    parse_search_lines(Lines, []).

parse_search_lines([], Acc) ->
    lists:reverse(Acc);
parse_search_lines([Line | Rest], Acc) ->
    Trimmed = string:trim(Line),
    case re:run(Trimmed, "(TASK-\\S+)\\s+-\\s+(.+?)\\s+\\(([^)]+)\\)\\s+\\[(HIGH|MEDIUM|LOW)\\]",
                [{capture, all_but_first, binary}]) of
        {match, [Id, Title, Status, Priority]} ->
            Task = #{id => Id,
                     title => string:trim(Title),
                     status => Status,
                     priority => string:lowercase(Priority)},
            parse_search_lines(Rest, [Task | Acc]);
        nomatch ->
            parse_search_lines(Rest, Acc)
    end.

%% Resolve the backlog binary: bundled submodule first, then system PATH
resolve_backlog_bin() ->
    %% Check bundled backlog-md submodule (TypeScript via bun)
    AppDir = code:lib_dir(backlog_server),
    BundledScript = filename:join([AppDir, "..", "..", "backlog-md", "backlog"]),
    case filelib:is_regular(BundledScript) of
        true ->
            %% The bundled backlog CLI script
            filename:absname(BundledScript);
        false ->
            %% Fall back to system backlog binary
            case os:find_executable("backlog") of
                false ->
                    logger:warning("No backlog binary found — commands will fail"),
                    "backlog";
                Path ->
                    Path
            end
    end.

%% Shell escape a string for safe use in os:cmd
shell_escape(Str) when is_list(Str) ->
    "'" ++ lists:flatmap(fun($') -> "'\\''"; (C) -> [C] end, Str) ++ "'";
shell_escape(Bin) when is_binary(Bin) ->
    shell_escape(binary_to_list(Bin)).

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L;
to_list(A) when is_atom(A) -> atom_to_list(A).
