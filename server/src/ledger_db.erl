-module(ledger_db).
-behaviour(gen_server).

%% SQLite storage layer for the Change Ledger.
%% Manages a single connection, runs migrations on startup,
%% and provides query helpers.
%%
%% exec/1,2 — execute SQL (INSERT/UPDATE/DELETE), returns ok
%% q/2,3    — query SQL, returns list of row tuples
%% one/2,3  — query SQL, returns {ok, Row} or {error, not_found}

-export([start_link/1]).
-export([exec/1, exec/2, q/2, q/3, one/2, one/3]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

-record(state, {db :: esqlite3:esqlite3()}).

%%% Public API

start_link(DataDir) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [DataDir], []).

exec(SQL) -> exec(SQL, []).
exec(SQL, Params) ->
    gen_server:call(?MODULE, {exec, SQL, Params}).

q(SQL, Params) -> q(SQL, Params, infinity).
q(SQL, Params, Timeout) ->
    gen_server:call(?MODULE, {q, SQL, Params}, Timeout).

one(SQL, Params) -> one(SQL, Params, infinity).
one(SQL, Params, Timeout) ->
    gen_server:call(?MODULE, {one, SQL, Params}, Timeout).

%%% gen_server callbacks

init([DataDir]) ->
    DbPath = filename:join(DataDir, "ledger.db"),
    logger:info("ledger_db: opening ~s", [DbPath]),
    {ok, Db} = esqlite3:open(DbPath),
    ok = esqlite3:exec(Db, <<"PRAGMA journal_mode=WAL;">>),
    ok = esqlite3:exec(Db, <<"PRAGMA foreign_keys=ON;">>),
    ok = run_migrations(Db),
    {ok, #state{db = Db}}.

handle_call({exec, SQL, []}, _From, #state{db = Db} = State) ->
    Result = esqlite3:exec(Db, SQL),
    {reply, Result, State};
handle_call({exec, SQL, Params}, _From, #state{db = Db} = State) ->
    %% esqlite3 has no exec/3 with params — use q/3 which returns [] for non-SELECT
    case esqlite3:q(Db, SQL, Params) of
        [] -> {reply, ok, State};
        {error, _} = Err -> {reply, Err, State};
        _Rows -> {reply, ok, State}  %% Some pragmas return rows
    end;

handle_call({q, SQL, Params}, _From, #state{db = Db} = State) ->
    case esqlite3:q(Db, SQL, Params) of
        Rows when is_list(Rows) ->
            %% Convert inner lists to tuples for ergonomic pattern matching
            Tuples = [list_to_tuple(R) || R <- Rows, is_list(R)],
            {reply, Tuples, State};
        {error, _} = Err ->
            {reply, Err, State}
    end;

handle_call({one, SQL, Params}, _From, #state{db = Db} = State) ->
    case esqlite3:q(Db, SQL, Params) of
        [Row] when is_list(Row) -> {reply, {ok, list_to_tuple(Row)}, State};
        [] -> {reply, {error, not_found}, State};
        [Row | _] when is_list(Row) -> {reply, {ok, list_to_tuple(Row)}, State};
        {error, _} = Err -> {reply, {error, Err}, State}
    end.

handle_cast(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, #state{db = Db}) ->
    esqlite3:close(Db),
    ok.

%%% Migrations

run_migrations(Db) ->
    ok = esqlite3:exec(Db, <<"
        CREATE TABLE IF NOT EXISTS schema_version (
            version INTEGER PRIMARY KEY,
            applied_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
    ">>),

    CurrentVersion = case esqlite3:q(Db, <<"SELECT MAX(version) FROM schema_version">>) of
        [[undefined]] -> 0;
        [[V]] when is_integer(V) -> V;
        [] -> 0
    end,

    Migrations = migrations(),
    lists:foreach(fun({Version, SQL}) ->
        case Version > CurrentVersion of
            true ->
                logger:info("ledger_db: applying migration ~p", [Version]),
                ok = esqlite3:exec(Db, SQL),
                [] = esqlite3:q(Db,
                    <<"INSERT INTO schema_version (version) VALUES (?1)">>,
                    [Version]
                );
            false ->
                ok
        end
    end, Migrations),
    ok.

migrations() ->
    [
        {1, <<"

            CREATE TABLE organizations (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                slug TEXT NOT NULL UNIQUE,
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
            );

            CREATE TABLE users (
                id TEXT PRIMARY KEY,
                org_id TEXT NOT NULL REFERENCES organizations(id),
                username TEXT NOT NULL,
                role TEXT NOT NULL DEFAULT 'developer',
                api_token_hash TEXT UNIQUE,
                created_at TEXT NOT NULL DEFAULT (datetime('now')),
                UNIQUE(org_id, username)
            );

            CREATE TABLE projects (
                id TEXT PRIMARY KEY,
                org_id TEXT NOT NULL REFERENCES organizations(id),
                name TEXT NOT NULL,
                slug TEXT NOT NULL,
                prefix TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (datetime('now')),
                UNIQUE(org_id, slug),
                UNIQUE(org_id, prefix)
            );

            CREATE TABLE tasks (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL REFERENCES projects(id),
                org_id TEXT NOT NULL REFERENCES organizations(id),
                title TEXT NOT NULL,
                intent TEXT,
                status TEXT NOT NULL DEFAULT 'open',
                priority TEXT,
                created_by TEXT,
                assigned_to TEXT,
                created_at TEXT NOT NULL DEFAULT (datetime('now')),
                updated_at TEXT NOT NULL DEFAULT (datetime('now'))
            );

            CREATE INDEX idx_tasks_org_project_status
                ON tasks(org_id, project_id, status);

            CREATE TABLE task_labels (
                task_id TEXT NOT NULL REFERENCES tasks(id),
                label TEXT NOT NULL,
                PRIMARY KEY (task_id, label)
            );

            CREATE TABLE leases (
                task_id TEXT PRIMARY KEY REFERENCES tasks(id),
                owner TEXT NOT NULL,
                acquired_at TEXT NOT NULL DEFAULT (datetime('now')),
                expires_at TEXT NOT NULL
            );

            CREATE TABLE artifact_links (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                task_id TEXT NOT NULL REFERENCES tasks(id),
                kind TEXT NOT NULL,
                ref TEXT NOT NULL,
                url TEXT,
                created_at TEXT NOT NULL DEFAULT (datetime('now')),
                created_by TEXT,
                UNIQUE(task_id, kind, ref)
            );

            CREATE TABLE audit_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                org_id TEXT NOT NULL,
                project_id TEXT,
                task_id TEXT,
                event_type TEXT NOT NULL,
                actor TEXT NOT NULL,
                detail TEXT,
                timestamp TEXT NOT NULL DEFAULT (datetime('now'))
            );

            CREATE INDEX idx_audit_org_task
                ON audit_events(org_id, task_id);
            CREATE INDEX idx_audit_org_time
                ON audit_events(org_id, timestamp);
        ">>},

        {2, <<"
            ALTER TABLE organizations ADD COLUMN is_superadmin INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE users ADD COLUMN email TEXT;
            ALTER TABLE users ADD COLUMN auth_provider TEXT NOT NULL DEFAULT 'token';
        ">>},

        {3, <<"
            CREATE TABLE status_cache (
                org TEXT NOT NULL,
                project TEXT NOT NULL,
                task_id TEXT NOT NULL,
                status TEXT NOT NULL,
                updated_by TEXT,
                commit_sha TEXT,
                updated_at TEXT NOT NULL DEFAULT (datetime('now')),
                PRIMARY KEY (org, project, task_id)
            );

            CREATE TABLE hash_chain (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                org TEXT NOT NULL,
                project TEXT NOT NULL,
                commit_sha TEXT NOT NULL,
                parent_sha TEXT,
                summary TEXT,
                actor TEXT NOT NULL,
                timestamp TEXT NOT NULL,
                prev_chain_hash TEXT,
                chain_hash TEXT NOT NULL
            );
            CREATE INDEX idx_hash_chain_org_project
                ON hash_chain(org, project);

            CREATE TABLE leases_v2 (
                org TEXT NOT NULL,
                project TEXT NOT NULL,
                task_id TEXT NOT NULL,
                owner TEXT NOT NULL,
                acquired_at TEXT NOT NULL DEFAULT (datetime('now')),
                expires_at TEXT NOT NULL,
                PRIMARY KEY (org, project, task_id)
            );
        ">>}
    ].
