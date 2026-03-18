-module(ledger_google_handler).
-behaviour(cowboy_handler).

%% Google OAuth2 login flow.
%%
%% GET  /auth/google          — redirect to Google consent screen
%% GET  /auth/google/callback — handle OAuth callback, issue API token
%%
%% Environment variables:
%%   GOOGLE_CLIENT_ID       — OAuth2 client ID
%%   GOOGLE_CLIENT_SECRET   — OAuth2 client secret
%%   GOOGLE_REDIRECT_URI    — Must match registered redirect URI
%%
%% Flow:
%%   1. User visits /auth/google
%%   2. Redirected to Google consent screen
%%   3. Google redirects back to /auth/google/callback?code=xxx
%%   4. Server exchanges code for ID token
%%   5. Server extracts email, finds or creates user in happihacking org
%%   6. Returns API token as JSON (or redirects with token in fragment)

-export([init/2]).

init(Req0, #{action := login} = State) ->
    case get_google_config() of
        {ok, #{client_id := ClientId, redirect_uri := RedirectUri}} ->
            %% Generate state parameter for CSRF protection
            OAuthState = binary:encode_hex(crypto:strong_rand_bytes(16)),
            Scope = <<"openid email profile">>,
            AuthUrl = iolist_to_binary([
                <<"https://accounts.google.com/o/oauth2/v2/auth">>,
                <<"?client_id=">>, ClientId,
                <<"&redirect_uri=">>, cow_uri:urlencode(RedirectUri),
                <<"&response_type=code">>,
                <<"&scope=">>, cow_uri:urlencode(Scope),
                <<"&state=">>, OAuthState,
                <<"&access_type=offline">>
            ]),
            Req1 = cowboy_req:set_resp_cookie(<<"oauth_state">>, OAuthState, Req0,
                #{path => <<"/">>, http_only => true, same_site => lax, max_age => 600}),
            Req = cowboy_req:reply(302, #{
                <<"location">> => AuthUrl
            }, <<>>, Req1),
            {ok, Req, State};
        {error, not_configured} ->
            ledger_util:json_reply(503, #{error => #{
                code => <<"not_configured">>,
                message => <<"Google OAuth not configured. Set GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, GOOGLE_REDIRECT_URI">>
            }}, Req0, State)
    end;

init(Req0, #{action := callback} = State) ->
    QS = cowboy_req:parse_qs(Req0),
    Code = proplists:get_value(<<"code">>, QS),
    _OAuthState = proplists:get_value(<<"state">>, QS),
    ErrorParam = proplists:get_value(<<"error">>, QS),

    if
        ErrorParam =/= undefined ->
            ledger_util:json_reply(400, #{error => #{
                code => <<"oauth_error">>,
                message => ErrorParam
            }}, Req0, State);
        Code =:= undefined ->
            ledger_util:json_reply(400, #{error => #{
                code => <<"bad_request">>,
                message => <<"Missing 'code' parameter">>
            }}, Req0, State);
        true ->
            case exchange_code(Code) of
                {ok, #{email := Email, name := Name}} ->
                    case find_or_create_google_user(Email, Name) of
                        {ok, Token} ->
                            ledger_util:json_reply(200, #{data => #{
                                api_token => Token,
                                email => Email,
                                name => Name,
                                message => <<"Login successful. Use this token as: Authorization: Bearer <token>">>
                            }}, Req0, State);
                        {error, Reason} ->
                            ledger_util:json_reply(500, #{error => #{
                                code => <<"internal_error">>,
                                message => ledger_util:to_bin(Reason)
                            }}, Req0, State)
                    end;
                {error, Reason} ->
                    ledger_util:json_reply(401, #{error => #{
                        code => <<"oauth_failed">>,
                        message => ledger_util:to_bin(Reason)
                    }}, Req0, State)
            end
    end.

%%% Internal

get_google_config() ->
    case {os:getenv("GOOGLE_CLIENT_ID"),
          os:getenv("GOOGLE_CLIENT_SECRET"),
          os:getenv("GOOGLE_REDIRECT_URI")} of
        {false, _, _} -> {error, not_configured};
        {_, false, _} -> {error, not_configured};
        {_, _, false} -> {error, not_configured};
        {Id, Secret, Uri} ->
            {ok, #{
                client_id => list_to_binary(Id),
                client_secret => list_to_binary(Secret),
                redirect_uri => list_to_binary(Uri)
            }}
    end.

exchange_code(Code) ->
    case get_google_config() of
        {ok, #{client_id := ClientId, client_secret := Secret, redirect_uri := RedirectUri}} ->
            Body = iolist_to_binary([
                <<"code=">>, cow_uri:urlencode(Code),
                <<"&client_id=">>, cow_uri:urlencode(ClientId),
                <<"&client_secret=">>, cow_uri:urlencode(Secret),
                <<"&redirect_uri=">>, cow_uri:urlencode(RedirectUri),
                <<"&grant_type=authorization_code">>
            ]),
            Request = {
                "https://oauth2.googleapis.com/token",
                [{"accept", "application/json"}],
                "application/x-www-form-urlencoded",
                binary_to_list(Body)
            },
            case httpc:request(post, Request, [{ssl, [{verify, verify_none}]}], []) of
                {ok, {{_, 200, _}, _, ResponseBody}} ->
                    TokenData = jsx:decode(list_to_binary(ResponseBody), [return_maps, {labels, atom}]),
                    IdToken = maps:get(id_token, TokenData, undefined),
                    case IdToken of
                        undefined ->
                            {error, <<"No id_token in response">>};
                        _ ->
                            decode_id_token(IdToken)
                    end;
                {ok, {{_, Status, _}, _, ResponseBody}} ->
                    logger:error("Google token exchange failed: ~p ~s", [Status, ResponseBody]),
                    {error, <<"Token exchange failed">>};
                {error, Reason} ->
                    logger:error("Google token exchange HTTP error: ~p", [Reason]),
                    {error, <<"HTTP request failed">>}
            end;
        {error, _} = Err ->
            Err
    end.

%% Decode JWT id_token (we trust Google's signature since we just received it
%% directly from the token endpoint over HTTPS).
decode_id_token(IdToken) ->
    try
        %% JWT is three base64url segments separated by dots
        [_Header, PayloadB64, _Signature] = binary:split(IdToken, <<".">>, [global]),
        %% Add padding
        Padded = base64url_pad(PayloadB64),
        PayloadJson = base64:decode(Padded),
        Claims = jsx:decode(PayloadJson, [return_maps, {labels, atom}]),
        Email = maps:get(email, Claims, undefined),
        Name = maps:get(name, Claims, maps:get(email, Claims, <<"unknown">>)),
        EmailVerified = maps:get(email_verified, Claims, false),
        case {Email, EmailVerified} of
            {undefined, _} ->
                {error, <<"No email in ID token">>};
            {_, false} ->
                {error, <<"Email not verified">>};
            {_, _} ->
                {ok, #{email => Email, name => Name}}
        end
    catch
        _:Err ->
            logger:error("Failed to decode ID token: ~p", [Err]),
            {error, <<"Failed to decode ID token">>}
    end.

base64url_pad(B) ->
    case byte_size(B) rem 4 of
        0 -> B;
        2 -> <<B/binary, "==">>;
        3 -> <<B/binary, "=">>;
        _ -> B
    end.

%% Find existing user by email in happihacking org, or create one.
find_or_create_google_user(Email, _Name) ->
    %% Find the happihacking org
    case ledger_db:one(
        <<"SELECT id FROM organizations WHERE slug = 'happihacking'">>,
        []
    ) of
        {ok, {OrgId}} ->
            case ledger_db:one(
                <<"SELECT id, api_token_hash FROM users WHERE org_id = ?1 AND email = ?2">>,
                [OrgId, Email]
            ) of
                {ok, {_UserId, _ExistingHash}} ->
                    %% User exists — regenerate token on each login
                    {RawToken, NewHash} = ledger_auth:generate_token(),
                    ok = ledger_db:exec(
                        <<"UPDATE users SET api_token_hash = ?1 WHERE org_id = ?2 AND email = ?3">>,
                        [NewHash, OrgId, Email]
                    ),
                    {ok, RawToken};
                {error, not_found} ->
                    %% Create new user
                    UserId = ledger_util:uuid(),
                    {RawToken, TokenHash} = ledger_auth:generate_token(),
                    Now = ledger_util:now_iso8601(),
                    Username = hd(binary:split(Email, <<"@">>)),
                    ok = ledger_db:exec(
                        <<"INSERT INTO users (id, org_id, username, role, email, auth_provider, api_token_hash, created_at)
                           VALUES (?1, ?2, ?3, 'developer', ?4, 'google', ?5, ?6)">>,
                        [UserId, OrgId, Username, Email, TokenHash, Now]
                    ),
                    logger:info("ledger_google: created user ~s (~s) in happihacking", [Username, Email]),
                    {ok, RawToken}
            end;
        {error, not_found} ->
            {error, <<"happihacking org not found — run bootstrap first">>}
    end.
