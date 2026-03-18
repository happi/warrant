-module(ledger_auth).

%% Authentication and authorization for the Change Ledger.
%%
%% Three auth paths:
%%   1. API token (Bearer cl_xxx) — for agents, CI, scripts
%%   2. Google OAuth (happihacking org) — for human login
%%   3. Bootstrap token (env var) — for initial setup only
%%
%% Middleware: require/3 wraps handler dispatch with auth checks.

-export([generate_token/0, hash_token/1]).
-export([require/3, require_superadmin/3]).
-export([authenticate/1]).

%%% Token generation

generate_token() ->
    HexPart = string:lowercase(binary:encode_hex(crypto:strong_rand_bytes(16))),
    Raw = iolist_to_binary([<<"cl_">>, HexPart]),
    Hash = hash_token(Raw),
    {Raw, Hash}.

hash_token(Token) ->
    string:lowercase(binary:encode_hex(crypto:hash(sha256, Token))).

%%% Middleware — call from handler init/2

%% require/3: authenticate, verify org membership, call handler on success.
%% HandlerFun receives (User, Req, State).
require(Req0, State, HandlerFun) ->
    case authenticate(Req0) of
        {ok, User} ->
            OrgSlug = cowboy_req:binding(org_slug, Req0),
            case check_org_access(User, OrgSlug) of
                ok ->
                    HandlerFun(User, Req0, State);
                {error, forbidden} ->
                    ledger_util:json_reply(403, #{error => #{
                        code => <<"forbidden">>,
                        message => <<"You do not have access to this organization">>
                    }}, Req0, State);
                {error, org_not_found} ->
                    ledger_util:json_reply(404, #{error => #{
                        code => <<"not_found">>,
                        message => <<"Organization not found">>
                    }}, Req0, State)
            end;
        {error, Reason} ->
            auth_error(Reason, Req0, State)
    end.

%% require_superadmin/3: authenticate and verify user belongs to a superadmin org.
require_superadmin(Req0, State, HandlerFun) ->
    case authenticate(Req0) of
        {ok, #{org_id := OrgId} = User} ->
            case is_superadmin_org(OrgId) of
                true ->
                    HandlerFun(User, Req0, State);
                false ->
                    ledger_util:json_reply(403, #{error => #{
                        code => <<"forbidden">>,
                        message => <<"Superadmin access required">>
                    }}, Req0, State)
            end;
        {error, Reason} ->
            auth_error(Reason, Req0, State)
    end.

%%% Authentication — returns {ok, User} or {error, Reason}

authenticate(Req) ->
    case cowboy_req:header(<<"authorization">>, Req) of
        undefined ->
            {error, missing_token};
        <<"Bearer ", Token/binary>> ->
            lookup_by_token(string:trim(Token));
        _ ->
            {error, invalid_header}
    end.

%%% Internal

lookup_by_token(RawToken) ->
    Hash = hash_token(RawToken),
    case ledger_db:one(
        <<"SELECT u.id, u.org_id, u.username, u.role, u.email
           FROM users u WHERE u.api_token_hash = ?1">>,
        [Hash]
    ) of
        {ok, {Id, OrgId, Username, Role, Email}} ->
            {ok, #{id => Id, org_id => OrgId, username => Username,
                   role => Role, email => Email}};
        {error, not_found} ->
            {error, invalid_token}
    end.

check_org_access(#{org_id := UserOrgId}, OrgSlug) ->
    case OrgSlug of
        undefined ->
            %% No org in URL (e.g., POST /api/v1/orgs) — allow, caller checks superadmin
            ok;
        _ ->
            case ledger_db:one(
                <<"SELECT id FROM organizations WHERE slug = ?1">>,
                [OrgSlug]
            ) of
                {ok, {OrgId}} when OrgId =:= UserOrgId -> ok;
                {ok, _} ->
                    %% User is in a different org — check if their org is superadmin
                    case is_superadmin_org(UserOrgId) of
                        true -> ok;  %% Superadmin orgs can access any org
                        false -> {error, forbidden}
                    end;
                {error, not_found} -> {error, org_not_found}
            end
    end.

is_superadmin_org(OrgId) ->
    case ledger_db:one(
        <<"SELECT is_superadmin FROM organizations WHERE id = ?1">>,
        [OrgId]
    ) of
        {ok, {1}} -> true;
        _ -> false
    end.

auth_error(missing_token, Req, State) ->
    ledger_util:json_reply(401, #{error => #{
        code => <<"unauthorized">>,
        message => <<"Missing Authorization header. Use: Bearer <token>">>
    }}, Req, State);
auth_error(invalid_token, Req, State) ->
    ledger_util:json_reply(401, #{error => #{
        code => <<"unauthorized">>,
        message => <<"Invalid or expired API token">>
    }}, Req, State);
auth_error(invalid_header, Req, State) ->
    ledger_util:json_reply(401, #{error => #{
        code => <<"unauthorized">>,
        message => <<"Invalid Authorization header format. Use: Bearer <token>">>
    }}, Req, State).
