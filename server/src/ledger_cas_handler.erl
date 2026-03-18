-module(ledger_cas_handler).
-behaviour(cowboy_handler).

%% Compare-and-swap for task status transitions.
%%
%% POST /api/cas/status
%%   Body: {org, project, task_id, from_status, to_status, actor, commit_sha}
%%   200: {"ok": true, "status": <new>}
%%   409: {"error": "conflict", "current_status": <actual>}
%%   422: {"error": "invalid_transition", ...}
%%
%% GET /api/cas/status/:org/:project/:task_id
%%   200: {"status": <cached>, "updated_at": ...}
%%   404: not found
%%
%% POST /api/cas/seed
%%   Body: {org, project, task_id, status}
%%   Used during migration to populate the cache from existing task files.

-export([init/2]).

-define(TRANSITIONS, #{
    <<"open">>        => [<<"in_progress">>, <<"blocked">>, <<"cancelled">>],
    <<"in_progress">> => [<<"in_review">>, <<"blocked">>, <<"cancelled">>],
    <<"in_review">>   => [<<"done">>, <<"in_progress">>, <<"cancelled">>],
    <<"blocked">>     => [<<"open">>, <<"in_progress">>, <<"cancelled">>]
}).

init(Req0, #{action := Action} = State) ->
    case cowboy_req:method(Req0) of
        <<"OPTIONS">> ->
            Req = cowboy_req:reply(204, ledger_util:cors_headers(), <<>>, Req0),
            {ok, Req, State};
        Method ->
            handle(Action, Method, Req0, State)
    end.

%% POST /api/cas/status — compare-and-swap
handle(cas_status, <<"POST">>, Req0, State) ->
    ledger_auth:require_superadmin(Req0, State, fun(_User, Req, S) ->
        {ok, Body, Req1} = cowboy_req:read_body(Req),
        case ledger_util:decode_json(Body) of
            {ok, #{org := Org, project := Proj, task_id := TaskId,
                   from_status := FromStatus, to_status := ToStatus} = Params} ->
                Actor = maps:get(actor, Params, <<"unknown">>),
                CommitSha = maps:get(commit_sha, Params, null),
                do_cas(Org, Proj, TaskId, FromStatus, ToStatus, Actor, CommitSha, Req1, S);
            {ok, _} ->
                ledger_util:json_reply(400, #{error => #{
                    code => <<"bad_request">>,
                    message => <<"Required: org, project, task_id, from_status, to_status">>
                }}, Req1, S);
            {error, _} ->
                ledger_util:json_reply(400, #{error => #{
                    code => <<"bad_request">>, message => <<"Invalid JSON">>
                }}, Req1, S)
        end
    end);

%% GET /api/cas/status/:org/:project/:task_id — read cached status
handle(cas_get, <<"GET">>, Req0, State) ->
    ledger_auth:require_superadmin(Req0, State, fun(_User, Req, S) ->
        Org = cowboy_req:binding(org, Req),
        Proj = cowboy_req:binding(project, Req),
        TaskId = cowboy_req:binding(task_id, Req),
        case ledger_db:one(
            <<"SELECT status, updated_by, commit_sha, updated_at
               FROM status_cache WHERE org = ?1 AND project = ?2 AND task_id = ?3">>,
            [Org, Proj, TaskId]
        ) of
            {ok, {Status, UpdatedBy, Sha, UpdatedAt}} ->
                ledger_util:json_reply(200, #{data => #{
                    task_id => TaskId, status => Status,
                    updated_by => UpdatedBy, commit_sha => Sha,
                    updated_at => UpdatedAt
                }}, Req, S);
            {error, not_found} ->
                ledger_util:json_reply(404, #{error => #{
                    code => <<"not_found">>,
                    message => <<"Task not in status cache">>
                }}, Req, S)
        end
    end);

%% POST /api/cas/seed — seed status cache (migration helper)
handle(cas_seed, <<"POST">>, Req0, State) ->
    ledger_auth:require_superadmin(Req0, State, fun(_User, Req, S) ->
        {ok, Body, Req1} = cowboy_req:read_body(Req),
        case ledger_util:decode_json(Body) of
            {ok, #{org := Org, project := Proj, task_id := TaskId, status := Status}} ->
                Now = ledger_util:now_iso8601(),
                ok = ledger_db:exec(
                    <<"INSERT INTO status_cache (org, project, task_id, status, updated_at)
                       VALUES (?1, ?2, ?3, ?4, ?5)
                       ON CONFLICT(org, project, task_id) DO UPDATE SET status = ?4, updated_at = ?5">>,
                    [Org, Proj, TaskId, Status, Now]
                ),
                ledger_util:json_reply(200, #{ok => true}, Req1, S);
            _ ->
                ledger_util:json_reply(400, #{error => #{
                    code => <<"bad_request">>,
                    message => <<"Required: org, project, task_id, status">>
                }}, Req1, S)
        end
    end);

handle(_, _, Req0, State) ->
    ledger_util:json_reply(405, #{error => #{
        code => <<"method_not_allowed">>, message => <<"Method not allowed">>
    }}, Req0, State).

%%% Internal

do_cas(Org, Proj, TaskId, FromStatus, ToStatus, Actor, CommitSha, Req, State) ->
    %% First validate the transition is legal
    case is_valid_transition(FromStatus, ToStatus) of
        false ->
            ledger_util:json_reply(422, #{error => #{
                code => <<"invalid_transition">>,
                message => iolist_to_binary([
                    <<"Cannot transition from '">>, FromStatus,
                    <<"' to '">>, ToStatus, <<"'">>
                ])
            }}, Req, State);
        true ->
            Now = ledger_util:now_iso8601(),
            %% Check current status in cache
            case ledger_db:one(
                <<"SELECT status FROM status_cache
                   WHERE org = ?1 AND project = ?2 AND task_id = ?3">>,
                [Org, Proj, TaskId]
            ) of
                {ok, {CurrentStatus}} ->
                    case CurrentStatus of
                        FromStatus ->
                            %% CAS succeeds — update
                            ok = ledger_db:exec(
                                <<"UPDATE status_cache
                                   SET status = ?1, updated_by = ?2, commit_sha = ?3, updated_at = ?4
                                   WHERE org = ?5 AND project = ?6 AND task_id = ?7">>,
                                [ToStatus, Actor, CommitSha, Now, Org, Proj, TaskId]
                            ),
                            ledger_util:json_reply(200, #{
                                ok => true,
                                status => ToStatus,
                                previous_status => FromStatus
                            }, Req, State);
                        _ ->
                            %% CAS fails — conflict
                            ledger_util:json_reply(409, #{error => #{
                                code => <<"conflict">>,
                                current_status => CurrentStatus,
                                message => iolist_to_binary([
                                    <<"Expected '">>, FromStatus,
                                    <<"' but found '">>, CurrentStatus, <<"'">>
                                ])
                            }}, Req, State)
                    end;
                {error, not_found} ->
                    %% Task not in cache yet — this is the first status transition.
                    %% Accept it if from_status is "open" (assumed initial state).
                    case FromStatus of
                        <<"open">> ->
                            ok = ledger_db:exec(
                                <<"INSERT INTO status_cache
                                   (org, project, task_id, status, updated_by, commit_sha, updated_at)
                                   VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)">>,
                                [Org, Proj, TaskId, ToStatus, Actor, CommitSha, Now]
                            ),
                            ledger_util:json_reply(200, #{
                                ok => true,
                                status => ToStatus,
                                previous_status => FromStatus
                            }, Req, State);
                        _ ->
                            %% Task not in cache and from_status is not "open" —
                            %% seed it first
                            ledger_util:json_reply(409, #{error => #{
                                code => <<"not_cached">>,
                                message => <<"Task not in status cache. Seed it first with POST /api/cas/seed">>
                            }}, Req, State)
                    end
            end
    end.

is_valid_transition(From, To) ->
    case maps:get(From, ?TRANSITIONS, undefined) of
        undefined -> false;
        Allowed -> lists:member(To, Allowed)
    end.
