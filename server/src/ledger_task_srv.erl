-module(ledger_task_srv).
-behaviour(gen_server).

%% Task registry with state machine.
%% All task CRUD and status transitions go through this module.

-export([start_link/0]).
-export([create/4, get/3, list/3, update_status/5, update_fields/4]).
-export([add_link/4, get_links/3, get_trace/3]).
-export([acquire_lease/5, release_lease/4]).
-export([init/1, handle_call/3, handle_cast/2]).

%%% Valid status transitions
-define(TRANSITIONS, #{
    <<"open">>        => [<<"in_progress">>, <<"blocked">>, <<"cancelled">>],
    <<"in_progress">> => [<<"in_review">>, <<"blocked">>, <<"cancelled">>],
    <<"in_review">>   => [<<"done">>, <<"in_progress">>, <<"cancelled">>],
    <<"blocked">>     => [<<"open">>, <<"in_progress">>, <<"cancelled">>]
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Create a new task. Returns {ok, Task} or {error, Reason}.
create(OrgId, ProjectId, Params, Actor) ->
    gen_server:call(?MODULE, {create, OrgId, ProjectId, Params, Actor}).

%% Get a single task by ID, scoped to org+project.
get(OrgId, ProjectId, TaskId) ->
    gen_server:call(?MODULE, {get, OrgId, ProjectId, TaskId}).

%% List tasks with filters.
list(OrgId, ProjectId, Filters) ->
    gen_server:call(?MODULE, {list, OrgId, ProjectId, Filters}, 30000).

%% Update task status with expected-state guard.
update_status(OrgId, ProjectId, TaskId, NewStatus, ExpectedStatus) ->
    gen_server:call(?MODULE, {update_status, OrgId, ProjectId, TaskId, NewStatus, ExpectedStatus}).

%% Update task fields (title, intent, priority, assigned_to, labels).
update_fields(OrgId, ProjectId, TaskId, Fields) ->
    gen_server:call(?MODULE, {update_fields, OrgId, ProjectId, TaskId, Fields}).

%% Artifact links
add_link(OrgId, TaskId, Link, Actor) ->
    gen_server:call(?MODULE, {add_link, OrgId, TaskId, Link, Actor}).

get_links(OrgId, _ProjectId, TaskId) ->
    gen_server:call(?MODULE, {get_links, OrgId, TaskId}).

get_trace(OrgId, ProjectId, TaskId) ->
    gen_server:call(?MODULE, {get_trace, OrgId, ProjectId, TaskId}).

%% Leases
acquire_lease(OrgId, ProjectId, TaskId, Owner, TTL) ->
    gen_server:call(?MODULE, {acquire_lease, OrgId, ProjectId, TaskId, Owner, TTL}).

release_lease(OrgId, ProjectId, TaskId, Owner) ->
    gen_server:call(?MODULE, {release_lease, OrgId, ProjectId, TaskId, Owner}).

%%% gen_server callbacks

init([]) ->
    {ok, #{}}.

handle_call({create, OrgId, ProjectId, Params, Actor}, _From, State) ->
    %% Look up the project prefix
    case ledger_db:one(
        <<"SELECT prefix FROM projects WHERE id = ?1 AND org_id = ?2">>,
        [ProjectId, OrgId]
    ) of
        {ok, {Prefix}} ->
            %% Allocate ID via the existing counter service
            {ok, #{id := TaskId}} = backlog_id_srv:next_id(Prefix),
            Title = maps:get(title, Params, <<"Untitled">>),
            Intent = maps:get(intent, Params, null),
            Priority = maps:get(priority, Params, null),
            Labels = maps:get(labels, Params, []),
            Now = ledger_util:now_iso8601(),

            ok = ledger_db:exec(
                <<"INSERT INTO tasks (id, project_id, org_id, title, intent, status, priority, created_by, created_at, updated_at)
                   VALUES (?1, ?2, ?3, ?4, ?5, 'open', ?6, ?7, ?8, ?8)">>,
                [TaskId, ProjectId, OrgId, Title, Intent, Priority, Actor, Now]
            ),

            %% Insert labels
            lists:foreach(fun(Label) ->
                ledger_db:exec(
                    <<"INSERT INTO task_labels (task_id, label) VALUES (?1, ?2)">>,
                    [TaskId, Label]
                )
            end, Labels),

            %% Audit
            ledger_audit_srv:log(OrgId, ProjectId, TaskId, <<"task.created">>, Actor,
                                 #{title => Title, intent => Intent, status => <<"open">>}),

            Task = #{
                id => TaskId,
                title => Title,
                intent => Intent,
                status => <<"open">>,
                priority => Priority,
                labels => Labels,
                created_by => Actor,
                assigned_to => null,
                created_at => Now,
                updated_at => Now,
                lease => null,
                links => []
            },
            {reply, {ok, Task}, State};
        {error, not_found} ->
            {reply, {error, project_not_found}, State}
    end;

handle_call({get, OrgId, ProjectId, TaskId}, _From, State) ->
    case load_task(OrgId, ProjectId, TaskId) of
        {ok, Task} -> {reply, {ok, Task}, State};
        Error -> {reply, Error, State}
    end;

handle_call({list, OrgId, ProjectId, Filters}, _From, State) ->
    {SQL, Params} = build_list_query(OrgId, ProjectId, Filters),
    Rows = ledger_db:q(SQL, Params),
    Tasks = [row_to_task_summary(R) || R <- Rows],
    %% Attach labels to each task
    TasksWithLabels = lists:map(fun(#{id := TId} = T) ->
        Labels = ledger_db:q(
            <<"SELECT label FROM task_labels WHERE task_id = ?1">>, [TId]
        ),
        T#{labels => [L || {L} <- Labels]}
    end, Tasks),
    {reply, {ok, TasksWithLabels}, State};

handle_call({update_status, OrgId, _ProjectId, TaskId, NewStatus, ExpectedStatus}, _From, State) ->
    case ledger_db:one(
        <<"SELECT status FROM tasks WHERE id = ?1 AND org_id = ?2">>,
        [TaskId, OrgId]
    ) of
        {ok, {CurrentStatus}} ->
            case CurrentStatus of
                ExpectedStatus ->
                    case is_valid_transition(CurrentStatus, NewStatus) of
                        true ->
                            Now = ledger_util:now_iso8601(),
                            ok = ledger_db:exec(
                                <<"UPDATE tasks SET status = ?1, updated_at = ?2 WHERE id = ?3">>,
                                [NewStatus, Now, TaskId]
                            ),
                            ledger_audit_srv:log(OrgId, null, TaskId, <<"task.status">>, <<"system">>,
                                                 #{from => CurrentStatus, to => NewStatus}),
                            {reply, {ok, #{id => TaskId, status => NewStatus,
                                          previous_status => CurrentStatus, updated_at => Now}}, State};
                        false ->
                            {reply, {error, {invalid_transition, CurrentStatus, NewStatus}}, State}
                    end;
                _ ->
                    {reply, {error, {conflict, CurrentStatus, ExpectedStatus}}, State}
            end;
        {error, not_found} ->
            {reply, {error, not_found}, State}
    end;

handle_call({update_fields, OrgId, _ProjectId, TaskId, Fields}, _From, State) ->
    case ledger_db:one(
        <<"SELECT id FROM tasks WHERE id = ?1 AND org_id = ?2">>,
        [TaskId, OrgId]
    ) of
        {ok, _} ->
            Now = ledger_util:now_iso8601(),
            %% Build dynamic UPDATE
            Updatable = [title, intent, priority, assigned_to],
            {Sets, Params} = lists:foldl(fun(Field, {SAcc, PAcc}) ->
                case maps:get(Field, Fields, undefined) of
                    undefined -> {SAcc, PAcc};
                    Value ->
                        N = length(PAcc) + 1,
                        Col = atom_to_binary(Field, utf8),
                        Set = <<Col/binary, " = ?", (integer_to_binary(N))/binary>>,
                        {[Set | SAcc], PAcc ++ [Value]}
                end
            end, {[], []}, Updatable),
            case Sets of
                [] -> {reply, {ok, #{id => TaskId}}, State};
                _ ->
                    N2 = length(Params) + 1,
                    N3 = N2 + 1,
                    SetClause = iolist_to_binary(lists:join(<<", ">>, lists:reverse(Sets))),
                    SQL = <<"UPDATE tasks SET ", SetClause/binary,
                            ", updated_at = ?", (integer_to_binary(N2))/binary,
                            " WHERE id = ?", (integer_to_binary(N3))/binary>>,
                    ok = ledger_db:exec(SQL, Params ++ [Now, TaskId]),

                    %% Handle labels separately
                    case maps:get(labels, Fields, undefined) of
                        undefined -> ok;
                        NewLabels ->
                            ledger_db:exec(<<"DELETE FROM task_labels WHERE task_id = ?1">>, [TaskId]),
                            lists:foreach(fun(L) ->
                                ledger_db:exec(
                                    <<"INSERT INTO task_labels (task_id, label) VALUES (?1, ?2)">>,
                                    [TaskId, L])
                            end, NewLabels)
                    end,

                    ledger_audit_srv:log(OrgId, null, TaskId, <<"task.updated">>, <<"system">>,
                                         #{fields => maps:keys(Fields)}),
                    {reply, {ok, #{id => TaskId, updated_at => Now}}, State}
            end;
        {error, not_found} ->
            {reply, {error, not_found}, State}
    end;

handle_call({add_link, OrgId, TaskId, Link, Actor}, _From, State) ->
    Kind = maps:get(kind, Link),
    Ref = maps:get(ref, Link),
    Url = maps:get(url, Link, null),
    Now = ledger_util:now_iso8601(),
    case ledger_db:exec(
        <<"INSERT INTO artifact_links (task_id, kind, ref, url, created_at, created_by)
           VALUES (?1, ?2, ?3, ?4, ?5, ?6)">>,
        [TaskId, Kind, Ref, Url, Now, Actor]
    ) of
        ok ->
            %% Get the inserted row ID
            [{LastId}] = ledger_db:q(<<"SELECT last_insert_rowid()">>, []),
            ledger_audit_srv:log(OrgId, null, TaskId, <<"link.added">>, Actor,
                                 #{kind => Kind, ref => Ref}),
            {reply, {ok, #{id => LastId, task_id => TaskId, kind => Kind,
                          ref => Ref, url => Url, created_at => Now}}, State};
        {error, _} = Err ->
            {reply, Err, State}
    end;

handle_call({get_links, _OrgId, TaskId}, _From, State) ->
    Rows = ledger_db:q(
        <<"SELECT id, task_id, kind, ref, url, created_at FROM artifact_links WHERE task_id = ?1">>,
        [TaskId]
    ),
    Links = [#{id => Id, task_id => TId, kind => K, ref => R,
               url => U, created_at => Ca}
             || {Id, TId, K, R, U, Ca} <- Rows],
    {reply, {ok, Links}, State};

handle_call({get_trace, OrgId, ProjectId, TaskId}, _From, State) ->
    case load_task(OrgId, ProjectId, TaskId) of
        {ok, Task} ->
            %% Get links grouped by kind
            Links = ledger_db:q(
                <<"SELECT kind, ref, url FROM artifact_links WHERE task_id = ?1 ORDER BY kind, id">>,
                [TaskId]
            ),
            GroupedLinks = group_links(Links),

            %% Get audit events
            {ok, AuditEvents} = ledger_audit_srv:list(OrgId, #{task_id => TaskId}),

            Trace = #{
                task => maps:without([lease, links, labels], Task),
                links => GroupedLinks,
                audit => AuditEvents
            },
            {reply, {ok, Trace}, State};
        Error ->
            {reply, Error, State}
    end;

handle_call({acquire_lease, OrgId, _ProjectId, TaskId, Owner, TTL}, _From, State) ->
    Now = ledger_util:now_iso8601(),
    %% Calculate expiry
    {{Y,Mo,D},{H,Mi,S}} = calendar:universal_time(),
    ExpirySecs = calendar:datetime_to_gregorian_seconds({{Y,Mo,D},{H,Mi,S}}) + TTL,
    ExpiryDT = calendar:gregorian_seconds_to_datetime(ExpirySecs),
    ExpiresAt = format_datetime(ExpiryDT),

    %% Check existing lease
    case ledger_db:one(
        <<"SELECT owner, expires_at FROM leases WHERE task_id = ?1">>,
        [TaskId]
    ) of
        {ok, {ExistingOwner, ExpiresAtOld}} ->
            case ExistingOwner of
                Owner ->
                    %% Same owner — renew
                    ok = ledger_db:exec(
                        <<"UPDATE leases SET acquired_at = ?1, expires_at = ?2 WHERE task_id = ?3">>,
                        [Now, ExpiresAt, TaskId]
                    ),
                    ledger_audit_srv:log(OrgId, null, TaskId, <<"lease.renewed">>, Owner,
                                         #{expires_at => ExpiresAt}),
                    {reply, {ok, #{task_id => TaskId, owner => Owner,
                                  acquired_at => Now, expires_at => ExpiresAt}}, State};
                _ ->
                    %% Check if expired
                    case ExpiresAtOld < Now of
                        true ->
                            %% Expired — replace
                            ok = ledger_db:exec(
                                <<"UPDATE leases SET owner = ?1, acquired_at = ?2, expires_at = ?3 WHERE task_id = ?4">>,
                                [Owner, Now, ExpiresAt, TaskId]
                            ),
                            ledger_audit_srv:log(OrgId, null, TaskId, <<"lease.expired">>, ExistingOwner, #{}),
                            ledger_audit_srv:log(OrgId, null, TaskId, <<"lease.acquired">>, Owner,
                                                 #{expires_at => ExpiresAt}),
                            {reply, {ok, #{task_id => TaskId, owner => Owner,
                                          acquired_at => Now, expires_at => ExpiresAt}}, State};
                        false ->
                            {reply, {error, {conflict, ExistingOwner}}, State}
                    end
            end;
        {error, not_found} ->
            %% No existing lease
            ok = ledger_db:exec(
                <<"INSERT INTO leases (task_id, owner, acquired_at, expires_at) VALUES (?1, ?2, ?3, ?4)">>,
                [TaskId, Owner, Now, ExpiresAt]
            ),
            ledger_audit_srv:log(OrgId, null, TaskId, <<"lease.acquired">>, Owner,
                                 #{expires_at => ExpiresAt}),
            {reply, {ok, #{task_id => TaskId, owner => Owner,
                          acquired_at => Now, expires_at => ExpiresAt}}, State}
    end;

handle_call({release_lease, OrgId, _ProjectId, TaskId, Owner}, _From, State) ->
    case ledger_db:one(
        <<"SELECT owner FROM leases WHERE task_id = ?1">>,
        [TaskId]
    ) of
        {ok, {ExistingOwner}} ->
            case ExistingOwner of
                Owner ->
                    ok = ledger_db:exec(
                        <<"DELETE FROM leases WHERE task_id = ?1">>,
                        [TaskId]
                    ),
                    ledger_audit_srv:log(OrgId, null, TaskId, <<"lease.released">>, Owner, #{}),
                    {reply, ok, State};
                _ ->
                    {reply, {error, forbidden}, State}
            end;
        {error, not_found} ->
            {reply, {error, not_found}, State}
    end.

handle_cast(_Msg, State) ->
    {noreply, State}.

%%% Internal

load_task(OrgId, _ProjectId, TaskId) ->
    case ledger_db:one(
        <<"SELECT id, project_id, org_id, title, intent, status, priority,
                  created_by, assigned_to, created_at, updated_at
           FROM tasks WHERE id = ?1 AND org_id = ?2">>,
        [TaskId, OrgId]
    ) of
        {ok, Row} ->
            Task = row_to_task(Row),
            %% Attach labels
            Labels = ledger_db:q(
                <<"SELECT label FROM task_labels WHERE task_id = ?1">>, [TaskId]
            ),
            %% Attach lease
            Lease = case ledger_db:one(
                <<"SELECT owner, acquired_at, expires_at FROM leases WHERE task_id = ?1">>,
                [TaskId]
            ) of
                {ok, {LOwner, LAcq, LExp}} ->
                    #{owner => LOwner, acquired_at => LAcq, expires_at => LExp};
                {error, not_found} ->
                    null
            end,
            %% Attach links
            LinkRows = ledger_db:q(
                <<"SELECT id, kind, ref, url, created_at FROM artifact_links WHERE task_id = ?1">>,
                [TaskId]
            ),
            Links = [#{id => LId, kind => LK, ref => LR, url => LU, created_at => LCa}
                     || {LId, LK, LR, LU, LCa} <- LinkRows],
            {ok, Task#{
                labels => [L || {L} <- Labels],
                lease => Lease,
                links => Links
            }};
        {error, not_found} ->
            {error, not_found}
    end.

row_to_task({Id, _ProjId, _OrgId, Title, Intent, Status, Priority,
             CreatedBy, AssignedTo, CreatedAt, UpdatedAt}) ->
    #{
        id => Id,
        title => Title,
        intent => Intent,
        status => Status,
        priority => Priority,
        created_by => CreatedBy,
        assigned_to => AssignedTo,
        created_at => CreatedAt,
        updated_at => UpdatedAt
    }.

row_to_task_summary({Id, Title, Status, Priority, AssignedTo, UpdatedAt}) ->
    #{
        id => Id,
        title => Title,
        status => Status,
        priority => Priority,
        assigned_to => AssignedTo,
        updated_at => UpdatedAt
    }.

build_list_query(OrgId, ProjectId, Filters) ->
    Base = <<"SELECT id, title, status, priority, assigned_to, updated_at
             FROM tasks WHERE org_id = ?1 AND project_id = ?2">>,
    {Clauses, Params0} = {[], [OrgId, ProjectId]},
    {C1, P1} = case maps:get(status, Filters, undefined) of
        undefined -> {Clauses, Params0};
        S -> {[<<" AND status = ?", (integer_to_binary(length(Params0) + 1))/binary>> | Clauses],
              Params0 ++ [S]}
    end,
    {C2, P2} = case maps:get(assigned_to, Filters, undefined) of
        undefined -> {C1, P1};
        A -> {[<<" AND assigned_to = ?", (integer_to_binary(length(P1) + 1))/binary>> | C1],
              P1 ++ [A]}
    end,
    {C3, P3} = case maps:get(label, Filters, undefined) of
        undefined -> {C2, P2};
        L ->
            N = length(P2) + 1,
            {[<<" AND id IN (SELECT task_id FROM task_labels WHERE label = ?",
                 (integer_to_binary(N))/binary, ")">>,
              C2], P2 ++ [L]}  %% NOTE: prepend, then reverse later
    end,
    Limit = maps:get(limit, Filters, 100),
    OffsetVal = maps:get(offset, Filters, 0),
    LN = length(P3) + 1,
    ON = LN + 1,
    FinalSQL = iolist_to_binary([
        Base,
        lists:reverse(C3),
        <<" ORDER BY updated_at DESC">>,
        <<" LIMIT ?", (integer_to_binary(LN))/binary>>,
        <<" OFFSET ?", (integer_to_binary(ON))/binary>>
    ]),
    {FinalSQL, P3 ++ [Limit, OffsetVal]}.

is_valid_transition(From, To) ->
    case maps:get(From, ?TRANSITIONS, undefined) of
        undefined -> false;
        Allowed -> lists:member(To, Allowed)
    end.

group_links(Rows) ->
    lists:foldl(fun({Kind, Ref, Url}, Acc) ->
        Key = case Kind of
            <<"branch">> -> branches;
            <<"commit">> -> commits;
            <<"pr">> -> prs;
            _ -> other
        end,
        Entry = case Url of
            null -> Ref;
            _ -> #{ref => Ref, url => Url}
        end,
        Existing = maps:get(Key, Acc, []),
        Acc#{Key => Existing ++ [Entry]}
    end, #{branches => [], commits => [], prs => []}, Rows).

format_datetime({{Y,Mo,D},{H,Mi,S}}) ->
    iolist_to_binary(io_lib:format(
        "~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ",
        [Y, Mo, D, H, Mi, S]
    )).
