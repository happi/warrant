-module(ledger_bootstrap).

%% Bootstrap module — creates the initial superadmin orgs and users on first start.
%%
%% Creates two orgs: "stenmans" and "happihacking", both with is_superadmin=1.
%% Creates an admin user in each org.
%%
%% Bootstrap only runs if neither org exists yet. Safe to call on every startup.
%% Admin tokens are logged once on creation — save them immediately.

-export([run/0]).

run() ->
    case ledger_db:one(
        <<"SELECT COUNT(*) FROM organizations WHERE is_superadmin = 1">>,
        []
    ) of
        {ok, {0}} ->
            logger:info("ledger_bootstrap: no superadmin orgs found, bootstrapping..."),
            bootstrap();
        {ok, {_N}} ->
            logger:info("ledger_bootstrap: superadmin orgs exist, skipping bootstrap"),
            ok
    end.

bootstrap() ->
    Now = ledger_util:now_iso8601(),

    %% Ensure stenmans org exists as superadmin
    StenmansId = ensure_superadmin_org(<<"Stenmans Homelab">>, <<"stenmans">>, Now),
    StenmansToken = ensure_admin_user(StenmansId, <<"erik">>, <<"erik@stenmans.org">>, Now),

    %% Ensure happihacking org exists as superadmin
    HappiId = ensure_superadmin_org(<<"HappiHacking">>, <<"happihacking">>, Now),
    HappiToken = ensure_admin_user(HappiId, <<"happi">>, <<"happi@happihacking.se">>, Now),

    case StenmansToken of
        existing -> ok;
        _ -> logger:notice("~n~n=== BOOTSTRAP: stenmans admin token ===~n  ~s~n~n", [StenmansToken])
    end,
    case HappiToken of
        existing -> ok;
        _ -> logger:notice("~n~n=== BOOTSTRAP: happihacking admin token ===~n  ~s~n~n", [HappiToken])
    end,
    case {StenmansToken, HappiToken} of
        {existing, existing} -> ok;
        _ -> logger:notice("~n=== SAVE THESE TOKENS NOW — they cannot be retrieved later ===~n")
    end,
    ok.

%% Create org if missing, or upgrade existing org to superadmin
ensure_superadmin_org(Name, Slug, Now) ->
    case ledger_db:one(<<"SELECT id, is_superadmin FROM organizations WHERE slug = ?1">>, [Slug]) of
        {ok, {Id, 1}} ->
            logger:info("ledger_bootstrap: org '~s' already superadmin", [Slug]),
            Id;
        {ok, {Id, _}} ->
            %% Exists but not superadmin — upgrade
            ok = ledger_db:exec(<<"UPDATE organizations SET is_superadmin = 1 WHERE id = ?1">>, [Id]),
            logger:info("ledger_bootstrap: upgraded org '~s' to superadmin", [Slug]),
            Id;
        {error, not_found} ->
            Id = ledger_util:uuid(),
            ok = ledger_db:exec(
                <<"INSERT INTO organizations (id, name, slug, is_superadmin, created_at)
                   VALUES (?1, ?2, ?3, 1, ?4)">>,
                [Id, Name, Slug, Now]
            ),
            logger:info("ledger_bootstrap: created org '~s' (superadmin)", [Slug]),
            Id
    end.

%% Create admin user if missing, return token or 'existing'
ensure_admin_user(OrgId, Username, Email, Now) ->
    case ledger_db:one(
        <<"SELECT id FROM users WHERE org_id = ?1 AND username = ?2">>,
        [OrgId, Username]
    ) of
        {ok, _} ->
            logger:info("ledger_bootstrap: user '~s' already exists", [Username]),
            existing;
        {error, not_found} ->
            {RawToken, TokenHash} = ledger_auth:generate_token(),
            ok = ledger_db:exec(
                <<"INSERT INTO users (id, org_id, username, role, email, auth_provider, api_token_hash, created_at)
                   VALUES (?1, ?2, ?3, 'admin', ?4, 'token', ?5, ?6)">>,
                [ledger_util:uuid(), OrgId, Username, Email, TokenHash, Now]
            ),
            logger:info("ledger_bootstrap: created admin user '~s'", [Username]),
            RawToken
    end.
