-module(ledger_task_handler).
-behaviour(cowboy_handler).

%% HTTP handler for task CRUD, status transitions, links, leases, and traces.
%% All endpoints require authentication via ledger_auth:require/3.

-export([init/2]).

init(Req0, #{action := Action} = State) ->
    case cowboy_req:method(Req0) of
        <<"OPTIONS">> ->
            Req = cowboy_req:reply(204, ledger_util:cors_headers(), <<>>, Req0),
            {ok, Req, State};
        Method ->
            ledger_auth:require(Req0, State, fun(User, Req, S) ->
                ProjectSlug = cowboy_req:binding(project_slug, Req),
                OrgSlug = cowboy_req:binding(org_slug, Req),
                case resolve_org_project(OrgSlug, ProjectSlug) of
                    {ok, OrgId, ProjectId} ->
                        Actor = maps:get(username, User, <<"anonymous">>),
                        handle(Action, Method, OrgId, ProjectId, Actor, Req, S);
                    {error, not_found} ->
                        ledger_util:json_reply(404, #{error => #{
                            code => <<"not_found">>,
                            message => <<"Organization or project not found">>
                        }}, Req, S)
                end
            end)
    end.

%% POST /api/v1/orgs/:org/projects/:proj/tasks
handle(tasks, <<"POST">>, OrgId, ProjectId, Actor, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    case ledger_util:decode_json(Body) of
        {ok, Params} ->
            case ledger_task_srv:create(OrgId, ProjectId, Params, Actor) of
                {ok, Task} ->
                    ledger_util:json_reply(201, #{data => Task}, Req1, State);
                {error, project_not_found} ->
                    ledger_util:json_reply(404, #{error => #{
                        code => <<"not_found">>, message => <<"Project not found">>
                    }}, Req1, State)
            end;
        {error, _} ->
            ledger_util:json_reply(400, #{error => #{
                code => <<"bad_request">>, message => <<"Invalid JSON body">>
            }}, Req1, State)
    end;

%% GET /api/v1/orgs/:org/projects/:proj/tasks
handle(tasks, <<"GET">>, OrgId, ProjectId, _Actor, Req0, State) ->
    QS = cowboy_req:parse_qs(Req0),
    Filters = maps:from_list([{binary_to_atom(K, utf8), V} || {K, V} <- QS,
        lists:member(K, [<<"status">>, <<"assigned_to">>, <<"label">>,
                         <<"limit">>, <<"offset">>])]),
    Filters2 = convert_int(limit, convert_int(offset, Filters)),
    {ok, Tasks} = ledger_task_srv:list(OrgId, ProjectId, Filters2),
    ledger_util:json_reply(200, #{data => Tasks}, Req0, State);

%% GET /api/v1/orgs/:org/projects/:proj/tasks/:id
handle(task, <<"GET">>, OrgId, ProjectId, _Actor, Req0, State) ->
    TaskId = cowboy_req:binding(task_id, Req0),
    case ledger_task_srv:get(OrgId, ProjectId, TaskId) of
        {ok, Task} ->
            ledger_util:json_reply(200, #{data => Task}, Req0, State);
        {error, not_found} ->
            ledger_util:json_reply(404, #{error => #{
                code => <<"not_found">>, message => <<"Task not found">>
            }}, Req0, State)
    end;

%% PATCH /api/v1/orgs/:org/projects/:proj/tasks/:id
handle(task, <<"PATCH">>, OrgId, ProjectId, _Actor, Req0, State) ->
    TaskId = cowboy_req:binding(task_id, Req0),
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    case ledger_util:decode_json(Body) of
        {ok, Fields} ->
            case ledger_task_srv:update_fields(OrgId, ProjectId, TaskId, Fields) of
                {ok, Result} ->
                    ledger_util:json_reply(200, #{data => Result}, Req1, State);
                {error, not_found} ->
                    ledger_util:json_reply(404, #{error => #{
                        code => <<"not_found">>, message => <<"Task not found">>
                    }}, Req1, State)
            end;
        {error, _} ->
            ledger_util:json_reply(400, #{error => #{
                code => <<"bad_request">>, message => <<"Invalid JSON body">>
            }}, Req1, State)
    end;

%% POST /api/v1/orgs/:org/projects/:proj/tasks/:id/status
handle(task_status, <<"POST">>, OrgId, ProjectId, _Actor, Req0, State) ->
    TaskId = cowboy_req:binding(task_id, Req0),
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    case ledger_util:decode_json(Body) of
        {ok, #{status := NewStatus, expected_status := ExpectedStatus}} ->
            case ledger_task_srv:update_status(OrgId, ProjectId, TaskId, NewStatus, ExpectedStatus) of
                {ok, Result} ->
                    ledger_util:json_reply(200, #{data => Result}, Req1, State);
                {error, {conflict, Actual, Expected}} ->
                    ledger_util:json_reply(409, #{error => #{
                        code => <<"conflict">>,
                        message => iolist_to_binary([
                            <<"Expected status '">>, Expected,
                            <<"' but found '">>, Actual, <<"'">>
                        ])
                    }}, Req1, State);
                {error, {invalid_transition, From, To}} ->
                    ledger_util:json_reply(422, #{error => #{
                        code => <<"invalid_transition">>,
                        message => iolist_to_binary([
                            <<"Cannot transition from '">>, From,
                            <<"' to '">>, To, <<"'">>
                        ])
                    }}, Req1, State);
                {error, not_found} ->
                    ledger_util:json_reply(404, #{error => #{
                        code => <<"not_found">>, message => <<"Task not found">>
                    }}, Req1, State)
            end;
        {ok, _} ->
            ledger_util:json_reply(400, #{error => #{
                code => <<"bad_request">>,
                message => <<"Missing 'status' and 'expected_status' fields">>
            }}, Req1, State);
        {error, _} ->
            ledger_util:json_reply(400, #{error => #{
                code => <<"bad_request">>, message => <<"Invalid JSON body">>
            }}, Req1, State)
    end;

%% POST /api/v1/orgs/:org/projects/:proj/tasks/:id/links
handle(task_links, <<"POST">>, OrgId, _ProjectId, Actor, Req0, State) ->
    TaskId = cowboy_req:binding(task_id, Req0),
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    case ledger_util:decode_json(Body) of
        {ok, #{kind := Kind, ref := Ref} = Link}
          when Kind =:= <<"branch">>; Kind =:= <<"commit">>; Kind =:= <<"pr">> ->
            case ledger_task_srv:add_link(OrgId, TaskId, Link, Actor) of
                {ok, Result} ->
                    ledger_util:json_reply(201, #{data => Result}, Req1, State);
                {error, _} ->
                    ledger_util:json_reply(409, #{error => #{
                        code => <<"conflict">>,
                        message => iolist_to_binary([
                            <<"Link already exists: ">>, Kind, <<" ">>, Ref
                        ])
                    }}, Req1, State)
            end;
        {ok, _} ->
            ledger_util:json_reply(400, #{error => #{
                code => <<"bad_request">>,
                message => <<"Missing 'kind' (branch|commit|pr) and 'ref' fields">>
            }}, Req1, State);
        {error, _} ->
            ledger_util:json_reply(400, #{error => #{
                code => <<"bad_request">>, message => <<"Invalid JSON body">>
            }}, Req1, State)
    end;

%% GET /api/v1/orgs/:org/projects/:proj/tasks/:id/links
handle(task_links, <<"GET">>, OrgId, ProjectId, _Actor, Req0, State) ->
    TaskId = cowboy_req:binding(task_id, Req0),
    {ok, Links} = ledger_task_srv:get_links(OrgId, ProjectId, TaskId),
    ledger_util:json_reply(200, #{data => Links}, Req0, State);

%% GET /api/v1/orgs/:org/projects/:proj/tasks/:id/trace
handle(task_trace, <<"GET">>, OrgId, ProjectId, _Actor, Req0, State) ->
    TaskId = cowboy_req:binding(task_id, Req0),
    case ledger_task_srv:get_trace(OrgId, ProjectId, TaskId) of
        {ok, Trace} ->
            ledger_util:json_reply(200, #{data => Trace}, Req0, State);
        {error, not_found} ->
            ledger_util:json_reply(404, #{error => #{
                code => <<"not_found">>, message => <<"Task not found">>
            }}, Req0, State)
    end;

%% POST /api/v1/orgs/:org/projects/:proj/tasks/:id/lease
handle(task_lease, <<"POST">>, OrgId, ProjectId, _Actor, Req0, State) ->
    TaskId = cowboy_req:binding(task_id, Req0),
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    case ledger_util:decode_json(Body) of
        {ok, #{owner := Owner, ttl_seconds := TTL}} when is_integer(TTL), TTL > 0 ->
            case ledger_task_srv:acquire_lease(OrgId, ProjectId, TaskId, Owner, TTL) of
                {ok, Lease} ->
                    ledger_util:json_reply(200, #{data => Lease}, Req1, State);
                {error, {conflict, ExistingOwner}} ->
                    ledger_util:json_reply(409, #{error => #{
                        code => <<"conflict">>,
                        message => iolist_to_binary([
                            <<"Task is leased by '">>, ExistingOwner, <<"'">>
                        ])
                    }}, Req1, State)
            end;
        {ok, _} ->
            ledger_util:json_reply(400, #{error => #{
                code => <<"bad_request">>,
                message => <<"Missing 'owner' (string) and 'ttl_seconds' (positive integer)">>
            }}, Req1, State);
        {error, _} ->
            ledger_util:json_reply(400, #{error => #{
                code => <<"bad_request">>, message => <<"Invalid JSON body">>
            }}, Req1, State)
    end;

%% DELETE /api/v1/orgs/:org/projects/:proj/tasks/:id/lease
handle(task_lease, <<"DELETE">>, OrgId, ProjectId, _Actor, Req0, State) ->
    TaskId = cowboy_req:binding(task_id, Req0),
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    case ledger_util:decode_json(Body) of
        {ok, #{owner := Owner}} ->
            case ledger_task_srv:release_lease(OrgId, ProjectId, TaskId, Owner) of
                ok ->
                    Req2 = cowboy_req:reply(204, ledger_util:cors_headers(), <<>>, Req1),
                    {ok, Req2, State};
                {error, forbidden} ->
                    ledger_util:json_reply(403, #{error => #{
                        code => <<"forbidden">>,
                        message => <<"You are not the lease owner">>
                    }}, Req1, State);
                {error, not_found} ->
                    ledger_util:json_reply(404, #{error => #{
                        code => <<"not_found">>, message => <<"No active lease">>
                    }}, Req1, State)
            end;
        _ ->
            ledger_util:json_reply(400, #{error => #{
                code => <<"bad_request">>, message => <<"Missing 'owner' field">>
            }}, Req1, State)
    end;

%% GET /api/v1/orgs/:org/projects/:proj/audit
handle(audit, <<"GET">>, OrgId, _ProjectId, _Actor, Req0, State) ->
    QS = cowboy_req:parse_qs(Req0),
    Filters = maps:from_list([{binary_to_atom(K, utf8), V} || {K, V} <- QS,
        lists:member(K, [<<"task_id">>, <<"since">>, <<"until">>,
                         <<"limit">>, <<"offset">>])]),
    Filters2 = convert_int(limit, convert_int(offset, Filters)),
    {ok, Events} = ledger_audit_srv:list(OrgId, Filters2),
    ledger_util:json_reply(200, #{data => Events}, Req0, State);

handle(_, _, _, _, _, Req0, State) ->
    ledger_util:json_reply(405, #{error => #{
        code => <<"method_not_allowed">>, message => <<"Method not allowed">>
    }}, Req0, State).

%%% Internal

resolve_org_project(OrgSlug, ProjectSlug) ->
    case ledger_db:one(
        <<"SELECT o.id, p.id FROM organizations o
           JOIN projects p ON p.org_id = o.id
           WHERE o.slug = ?1 AND p.slug = ?2">>,
        [OrgSlug, ProjectSlug]
    ) of
        {ok, {OrgId, ProjectId}} -> {ok, OrgId, ProjectId};
        {error, not_found} -> {error, not_found}
    end.

convert_int(Key, Map) ->
    case maps:get(Key, Map, undefined) of
        undefined -> Map;
        V when is_binary(V) ->
            try Map#{Key := binary_to_integer(V)}
            catch _:_ -> Map
            end;
        _ -> Map
    end.
