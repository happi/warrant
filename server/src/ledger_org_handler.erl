-module(ledger_org_handler).
-behaviour(cowboy_handler).

%% HTTP handler for organization, project, and user management.
%% All endpoints require authentication. Org creation requires superadmin.

-export([init/2]).

init(Req0, #{action := Action} = State) ->
    case cowboy_req:method(Req0) of
        <<"OPTIONS">> ->
            Req = cowboy_req:reply(204, ledger_util:cors_headers(), <<>>, Req0),
            {ok, Req, State};
        Method ->
            dispatch(Action, Method, Req0, State)
    end.

%% POST /api/v1/orgs — superadmin only
dispatch(create_org, <<"POST">>, Req0, State) ->
    ledger_auth:require_superadmin(Req0, State, fun(User, Req, S) ->
        handle_create_org(User, Req, S)
    end);

%% GET /api/v1/orgs/:org_slug — authenticated, org-scoped
dispatch(get_org, <<"GET">>, Req0, State) ->
    ledger_auth:require(Req0, State, fun(_User, Req, S) ->
        handle_get_org(Req, S)
    end);

%% POST/GET /api/v1/orgs/:org_slug/projects — authenticated, org-scoped
dispatch(projects, Method, Req0, State) ->
    ledger_auth:require(Req0, State, fun(User, Req, S) ->
        case Method of
            <<"POST">> -> handle_create_project(User, Req, S);
            <<"GET">>  -> handle_list_projects(Req, S);
            _ -> ledger_util:json_reply(405, #{error => #{
                     code => <<"method_not_allowed">>, message => <<"Method not allowed">>
                 }}, Req, S)
        end
    end);

%% POST /api/v1/orgs/:org_slug/users — authenticated, admin role, org-scoped
dispatch(create_user, <<"POST">>, Req0, State) ->
    ledger_auth:require(Req0, State, fun(User, Req, S) ->
        case maps:get(role, User) of
            <<"admin">> -> handle_create_user(Req, S);
            _ -> ledger_util:json_reply(403, #{error => #{
                     code => <<"forbidden">>, message => <<"Admin role required">>
                 }}, Req, S)
        end
    end);

%% POST /api/v1/orgs/:org_slug/users/:username/token — authenticated, admin or self
dispatch(regen_token, <<"POST">>, Req0, State) ->
    ledger_auth:require(Req0, State, fun(User, Req, S) ->
        handle_regen_token(User, Req, S)
    end);

dispatch(_, _, Req0, State) ->
    ledger_util:json_reply(405, #{error => #{
        code => <<"method_not_allowed">>, message => <<"Method not allowed">>
    }}, Req0, State).

%%% Handlers

handle_create_org(_User, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    case ledger_util:decode_json(Body) of
        {ok, #{name := Name, slug := Slug}} ->
            Id = ledger_util:uuid(),
            Now = ledger_util:now_iso8601(),
            case ledger_db:exec(
                <<"INSERT INTO organizations (id, name, slug, is_superadmin, created_at)
                   VALUES (?1, ?2, ?3, 0, ?4)">>,
                [Id, Name, Slug, Now]
            ) of
                ok ->
                    ledger_util:json_reply(201, #{data => #{
                        id => Id, name => Name, slug => Slug, created_at => Now
                    }}, Req1, State);
                {error, _} ->
                    ledger_util:json_reply(409, #{error => #{
                        code => <<"conflict">>, message => <<"Organization slug already exists">>
                    }}, Req1, State)
            end;
        _ ->
            ledger_util:json_reply(400, #{error => #{
                code => <<"bad_request">>, message => <<"Missing 'name' and 'slug' fields">>
            }}, Req1, State)
    end.

handle_get_org(Req0, State) ->
    Slug = cowboy_req:binding(org_slug, Req0),
    case ledger_db:one(
        <<"SELECT id, name, slug, created_at FROM organizations WHERE slug = ?1">>,
        [Slug]
    ) of
        {ok, {Id, Name, S, Ca}} ->
            ledger_util:json_reply(200, #{data => #{
                id => Id, name => Name, slug => S, created_at => Ca
            }}, Req0, State);
        {error, not_found} ->
            ledger_util:json_reply(404, #{error => #{
                code => <<"not_found">>, message => <<"Organization not found">>
            }}, Req0, State)
    end.

handle_create_project(_User, Req0, State) ->
    OrgSlug = cowboy_req:binding(org_slug, Req0),
    case resolve_org(OrgSlug) of
        {ok, OrgId} ->
            {ok, Body, Req1} = cowboy_req:read_body(Req0),
            case ledger_util:decode_json(Body) of
                {ok, #{name := Name, slug := Slug, prefix := Prefix}} ->
                    Id = ledger_util:uuid(),
                    Now = ledger_util:now_iso8601(),
                    case ledger_db:exec(
                        <<"INSERT INTO projects (id, org_id, name, slug, prefix, created_at)
                           VALUES (?1, ?2, ?3, ?4, ?5, ?6)">>,
                        [Id, OrgId, Name, Slug, string:lowercase(Prefix), Now]
                    ) of
                        ok ->
                            ledger_util:json_reply(201, #{data => #{
                                id => Id, name => Name, slug => Slug,
                                prefix => string:uppercase(Prefix), created_at => Now
                            }}, Req1, State);
                        {error, _} ->
                            ledger_util:json_reply(409, #{error => #{
                                code => <<"conflict">>,
                                message => <<"Project slug or prefix already exists in this org">>
                            }}, Req1, State)
                    end;
                _ ->
                    ledger_util:json_reply(400, #{error => #{
                        code => <<"bad_request">>,
                        message => <<"Missing 'name', 'slug', and 'prefix' fields">>
                    }}, Req1, State)
            end;
        {error, not_found} ->
            ledger_util:json_reply(404, #{error => #{
                code => <<"not_found">>, message => <<"Organization not found">>
            }}, Req0, State)
    end.

handle_list_projects(Req0, State) ->
    OrgSlug = cowboy_req:binding(org_slug, Req0),
    case resolve_org(OrgSlug) of
        {ok, OrgId} ->
            Rows = ledger_db:q(
                <<"SELECT id, name, slug, prefix, created_at FROM projects WHERE org_id = ?1 ORDER BY name">>,
                [OrgId]
            ),
            Projects = [#{id => Id, name => N, slug => S,
                          prefix => string:uppercase(P), created_at => Ca}
                        || {Id, N, S, P, Ca} <- Rows],
            ledger_util:json_reply(200, #{data => Projects}, Req0, State);
        {error, not_found} ->
            ledger_util:json_reply(404, #{error => #{
                code => <<"not_found">>, message => <<"Organization not found">>
            }}, Req0, State)
    end.

handle_create_user(Req0, State) ->
    OrgSlug = cowboy_req:binding(org_slug, Req0),
    case resolve_org(OrgSlug) of
        {ok, OrgId} ->
            {ok, Body, Req1} = cowboy_req:read_body(Req0),
            case ledger_util:decode_json(Body) of
                {ok, #{username := Username} = UserParams} ->
                    Role = maps:get(role, UserParams, <<"developer">>),
                    Email = maps:get(email, UserParams, null),
                    Id = ledger_util:uuid(),
                    {RawToken, TokenHash} = ledger_auth:generate_token(),
                    Now = ledger_util:now_iso8601(),
                    case ledger_db:exec(
                        <<"INSERT INTO users (id, org_id, username, role, email, auth_provider, api_token_hash, created_at)
                           VALUES (?1, ?2, ?3, ?4, ?5, 'token', ?6, ?7)">>,
                        [Id, OrgId, Username, Role, Email, TokenHash, Now]
                    ) of
                        ok ->
                            ledger_util:json_reply(201, #{data => #{
                                id => Id, username => Username, role => Role,
                                api_token => RawToken, created_at => Now
                            }}, Req1, State);
                        {error, _} ->
                            ledger_util:json_reply(409, #{error => #{
                                code => <<"conflict">>,
                                message => <<"Username already exists in this org">>
                            }}, Req1, State)
                    end;
                _ ->
                    ledger_util:json_reply(400, #{error => #{
                        code => <<"bad_request">>,
                        message => <<"Missing 'username' field">>
                    }}, Req1, State)
            end;
        {error, not_found} ->
            ledger_util:json_reply(404, #{error => #{
                code => <<"not_found">>, message => <<"Organization not found">>
            }}, Req0, State)
    end.

handle_regen_token(#{role := Role, username := AuthUsername}, Req0, State) ->
    OrgSlug = cowboy_req:binding(org_slug, Req0),
    TargetUsername = cowboy_req:binding(username, Req0),
    %% Only admin or self can regenerate
    case Role =:= <<"admin">> orelse AuthUsername =:= TargetUsername of
        true ->
            case resolve_org(OrgSlug) of
                {ok, OrgId} ->
                    {RawToken, NewHash} = ledger_auth:generate_token(),
                    case ledger_db:exec(
                        <<"UPDATE users SET api_token_hash = ?1 WHERE org_id = ?2 AND username = ?3">>,
                        [NewHash, OrgId, TargetUsername]
                    ) of
                        ok ->
                            ledger_util:json_reply(200, #{data => #{
                                username => TargetUsername,
                                api_token => RawToken
                            }}, Req0, State);
                        {error, _} ->
                            ledger_util:json_reply(404, #{error => #{
                                code => <<"not_found">>, message => <<"User not found">>
                            }}, Req0, State)
                    end;
                {error, not_found} ->
                    ledger_util:json_reply(404, #{error => #{
                        code => <<"not_found">>, message => <<"Organization not found">>
                    }}, Req0, State)
            end;
        false ->
            ledger_util:json_reply(403, #{error => #{
                code => <<"forbidden">>, message => <<"Admin role or self required">>
            }}, Req0, State)
    end.

%%% Internal

resolve_org(Slug) ->
    case ledger_db:one(
        <<"SELECT id FROM organizations WHERE slug = ?1">>,
        [Slug]
    ) of
        {ok, {Id}} -> {ok, Id};
        {error, not_found} -> {error, not_found}
    end.
