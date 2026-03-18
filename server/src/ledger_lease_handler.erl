-module(ledger_lease_handler).
-behaviour(cowboy_handler).

%% Standalone lease registry for agent coordination.
%% Uses leases_v2 table (org/project scoped, not tied to task CRUD).
%%
%% POST /api/leases/acquire
%%   Body: {org, project, task_id, owner, ttl_seconds}
%%   200: lease acquired/renewed
%%   409: leased by another owner
%%
%% POST /api/leases/release
%%   Body: {org, project, task_id, owner}
%%   204: released
%%   403: not the owner
%%
%% GET /api/leases/:org/:project
%%   200: all active leases for org/project

-export([init/2]).

init(Req0, #{action := Action} = State) ->
    case cowboy_req:method(Req0) of
        <<"OPTIONS">> ->
            Req = cowboy_req:reply(204, ledger_util:cors_headers(), <<>>, Req0),
            {ok, Req, State};
        Method ->
            handle(Action, Method, Req0, State)
    end.

handle(acquire, <<"POST">>, Req0, State) ->
    ledger_auth:require_superadmin(Req0, State, fun(_User, Req, S) ->
        {ok, Body, Req1} = cowboy_req:read_body(Req),
        case ledger_util:decode_json(Body) of
            {ok, #{org := Org, project := Proj, task_id := TaskId,
                   owner := Owner, ttl_seconds := TTL}}
              when is_integer(TTL), TTL > 0 ->
                do_acquire(Org, Proj, TaskId, Owner, TTL, Req1, S);
            {ok, _} ->
                ledger_util:json_reply(400, #{error => #{
                    code => <<"bad_request">>,
                    message => <<"Required: org, project, task_id, owner, ttl_seconds">>
                }}, Req1, S);
            {error, _} ->
                ledger_util:json_reply(400, #{error => #{
                    code => <<"bad_request">>, message => <<"Invalid JSON">>
                }}, Req1, S)
        end
    end);

handle(release, <<"POST">>, Req0, State) ->
    ledger_auth:require_superadmin(Req0, State, fun(_User, Req, S) ->
        {ok, Body, Req1} = cowboy_req:read_body(Req),
        case ledger_util:decode_json(Body) of
            {ok, #{org := Org, project := Proj, task_id := TaskId, owner := Owner}} ->
                do_release(Org, Proj, TaskId, Owner, Req1, S);
            {ok, _} ->
                ledger_util:json_reply(400, #{error => #{
                    code => <<"bad_request">>,
                    message => <<"Required: org, project, task_id, owner">>
                }}, Req1, S);
            {error, _} ->
                ledger_util:json_reply(400, #{error => #{
                    code => <<"bad_request">>, message => <<"Invalid JSON">>
                }}, Req1, S)
        end
    end);

handle(list_leases, <<"GET">>, Req0, State) ->
    ledger_auth:require_superadmin(Req0, State, fun(_User, Req, S) ->
        Org = cowboy_req:binding(org, Req),
        Proj = cowboy_req:binding(project, Req),
        Now = ledger_util:now_iso8601(),
        Rows = ledger_db:q(
            <<"SELECT task_id, owner, acquired_at, expires_at
               FROM leases_v2 WHERE org = ?1 AND project = ?2 AND expires_at > ?3
               ORDER BY task_id">>,
            [Org, Proj, Now]
        ),
        Leases = [#{task_id => T, owner => O, acquired_at => A, expires_at => E}
                  || {T, O, A, E} <- Rows],
        ledger_util:json_reply(200, #{data => Leases}, Req, S)
    end);

handle(_, _, Req0, State) ->
    ledger_util:json_reply(405, #{error => #{
        code => <<"method_not_allowed">>, message => <<"Method not allowed">>
    }}, Req0, State).

%%% Internal

do_acquire(Org, Proj, TaskId, Owner, TTL, Req, State) ->
    Now = ledger_util:now_iso8601(),
    ExpiresAt = compute_expiry(TTL),

    case ledger_db:one(
        <<"SELECT owner, expires_at FROM leases_v2
           WHERE org = ?1 AND project = ?2 AND task_id = ?3">>,
        [Org, Proj, TaskId]
    ) of
        {ok, {ExistingOwner, ExpiresAtOld}} ->
            case ExistingOwner of
                Owner ->
                    %% Same owner — renew
                    ok = ledger_db:exec(
                        <<"UPDATE leases_v2 SET acquired_at = ?1, expires_at = ?2
                           WHERE org = ?3 AND project = ?4 AND task_id = ?5">>,
                        [Now, ExpiresAt, Org, Proj, TaskId]
                    ),
                    ledger_util:json_reply(200, #{data => #{
                        task_id => TaskId, owner => Owner,
                        acquired_at => Now, expires_at => ExpiresAt
                    }}, Req, State);
                _ ->
                    %% Different owner — check if expired
                    case ExpiresAtOld < Now of
                        true ->
                            %% Expired — replace
                            ok = ledger_db:exec(
                                <<"UPDATE leases_v2
                                   SET owner = ?1, acquired_at = ?2, expires_at = ?3
                                   WHERE org = ?4 AND project = ?5 AND task_id = ?6">>,
                                [Owner, Now, ExpiresAt, Org, Proj, TaskId]
                            ),
                            ledger_util:json_reply(200, #{data => #{
                                task_id => TaskId, owner => Owner,
                                acquired_at => Now, expires_at => ExpiresAt
                            }}, Req, State);
                        false ->
                            %% Active lease by another owner — conflict
                            ledger_util:json_reply(409, #{error => #{
                                code => <<"conflict">>,
                                current_owner => ExistingOwner,
                                expires_at => ExpiresAtOld,
                                message => iolist_to_binary([
                                    <<"Leased by '">>, ExistingOwner, <<"'">>
                                ])
                            }}, Req, State)
                    end
            end;
        {error, not_found} ->
            %% No existing lease
            ok = ledger_db:exec(
                <<"INSERT INTO leases_v2 (org, project, task_id, owner, acquired_at, expires_at)
                   VALUES (?1, ?2, ?3, ?4, ?5, ?6)">>,
                [Org, Proj, TaskId, Owner, Now, ExpiresAt]
            ),
            ledger_util:json_reply(200, #{data => #{
                task_id => TaskId, owner => Owner,
                acquired_at => Now, expires_at => ExpiresAt
            }}, Req, State)
    end.

do_release(Org, Proj, TaskId, Owner, Req, State) ->
    case ledger_db:one(
        <<"SELECT owner FROM leases_v2
           WHERE org = ?1 AND project = ?2 AND task_id = ?3">>,
        [Org, Proj, TaskId]
    ) of
        {ok, {ExistingOwner}} ->
            case ExistingOwner of
                Owner ->
                    ok = ledger_db:exec(
                        <<"DELETE FROM leases_v2
                           WHERE org = ?1 AND project = ?2 AND task_id = ?3">>,
                        [Org, Proj, TaskId]
                    ),
                    Req1 = cowboy_req:reply(204, ledger_util:cors_headers(), <<>>, Req),
                    {ok, Req1, State};
                _ ->
                    ledger_util:json_reply(403, #{error => #{
                        code => <<"forbidden">>,
                        message => <<"Not the lease owner">>
                    }}, Req, State)
            end;
        {error, not_found} ->
            ledger_util:json_reply(404, #{error => #{
                code => <<"not_found">>,
                message => <<"No active lease">>
            }}, Req, State)
    end.

compute_expiry(TTLSeconds) ->
    {{Y,Mo,D},{H,Mi,S}} = calendar:universal_time(),
    Secs = calendar:datetime_to_gregorian_seconds({{Y,Mo,D},{H,Mi,S}}) + TTLSeconds,
    ExpiryDT = calendar:gregorian_seconds_to_datetime(Secs),
    {{EY,EMo,ED},{EH,EMi,ES}} = ExpiryDT,
    iolist_to_binary(io_lib:format(
        "~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ",
        [EY, EMo, ED, EH, EMi, ES]
    )).
