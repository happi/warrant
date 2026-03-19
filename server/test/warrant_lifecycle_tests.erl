-module(warrant_lifecycle_tests).
-include_lib("eunit/include/eunit.hrl").

%% Full lifecycle: extract refs → resolve intents → create warrant → query.
%% Uses in-memory DB so no server process needed.

lifecycle_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     [fun create_and_get/0,
      fun for_commit_lookup/0,
      fun list_by_project/0,
      fun missing_warrant_not_found/0,
      fun idempotent_creation/0,
      fun multiple_intents/0]}.

setup() ->
    %% Start required services for DB access
    DataDir = "/tmp/warrant_test_" ++ integer_to_list(erlang:unique_integer([positive])),
    file:make_dir(DataDir),
    {ok, DbPid} = ledger_db:start_link(DataDir),
    {ok, AuditPid} = ledger_audit_srv:start_link(),
    {ok, IdPid} = backlog_id_srv:start_link(DataDir),
    %% Create org and project for tests
    ledger_db:exec(<<"INSERT INTO organizations (id, name, slug, created_at)
                      VALUES ('org1', 'Test Org', 'test-org', '2026-01-01')">>, []),
    ledger_db:exec(<<"INSERT INTO projects (id, org_id, name, slug, prefix, created_at)
                      VALUES ('proj1', 'org1', 'Test', 'test', 'T', '2026-01-01')">>, []),
    {DataDir, DbPid, AuditPid, IdPid}.

teardown({DataDir, DbPid, AuditPid, IdPid}) ->
    gen_server:stop(DbPid),
    gen_server:stop(AuditPid),
    gen_server:stop(IdPid),
    os:cmd("rm -rf " ++ DataDir).

create_and_get() ->
    %% Create a warrant with one intent source
    IntentSources = [#{
        id => <<"backlog:T-1">>,
        source_type => <<"backlog">>,
        source_ref => <<"T-1">>,
        title => <<"Fix login bug">>,
        body => <<"Users cannot log in">>,
        author => <<"tester">>,
        labels => [],
        metadata => #{},
        created_at => <<"2026-01-01T00:00:00Z">>,
        updated_at => <<"2026-01-01T00:00:00Z">>
    }],
    MergeCtx = #{
        commits => [<<"aaa111">>, <<"bbb222">>],
        merge_commit => <<"ccc333">>,
        pr_number => <<"1">>,
        pr_title => <<"Fix login">>,
        repository => <<"test/repo">>,
        target_branch => <<"main">>,
        actor => <<"merger">>,
        reviewers => [<<"reviewer">>],
        approvals => [<<"reviewer">>],
        merged_at => <<"2026-01-01T12:00:00Z">>
    },
    {ok, Warrant} = warrant_object:create(IntentSources, MergeCtx, <<"Fix login bug">>,
        #{org_id => <<"org1">>, project_id => <<"proj1">>}),

    WId = maps:get(warrant_id, Warrant),
    ?assertEqual(64, byte_size(WId)),

    %% Get it back
    {ok, Retrieved} = warrant_object:get(WId),
    ?assertEqual(WId, maps:get(warrant_id, Retrieved)),
    ?assertEqual(<<"Fix login bug">>, maps:get(summary, Retrieved)).

for_commit_lookup() ->
    %% Look up warrant by commit SHA
    {ok, Warrants} = warrant_object:for_commit(<<"aaa111">>),
    ?assert(length(Warrants) >= 1),
    [W | _] = Warrants,
    ?assertEqual(<<"Fix login bug">>, maps:get(summary, W)).

list_by_project() ->
    {ok, Warrants} = warrant_object:list(<<"org1">>, <<"proj1">>, #{}),
    ?assert(length(Warrants) >= 1).

missing_warrant_not_found() ->
    ?assertEqual({error, not_found},
        warrant_object:get(<<"0000000000000000000000000000000000000000000000000000000000000000">>)).

idempotent_creation() ->
    %% Creating the same warrant twice should not error (INSERT OR IGNORE)
    IS = [#{id => <<"backlog:T-2">>, source_type => <<"backlog">>,
            source_ref => <<"T-2">>, title => <<"Dup test">>,
            body => null, author => null, labels => [], metadata => #{},
            created_at => <<"2026-01-01T00:00:00Z">>,
            updated_at => <<"2026-01-01T00:00:00Z">>}],
    MC = #{commits => [<<"ddd444">>], repository => <<"t/r">>,
           target_branch => <<"main">>, actor => <<"a">>,
           merged_at => <<"2026-01-01T00:00:00Z">>},
    {ok, W1} = warrant_object:create(IS, MC, <<"Dup">>, #{}),
    {ok, W2} = warrant_object:create(IS, MC, <<"Dup">>, #{}),
    ?assertEqual(maps:get(warrant_id, W1), maps:get(warrant_id, W2)).

multiple_intents() ->
    IS = [
        #{id => <<"backlog:T-3">>, source_type => <<"backlog">>,
          source_ref => <<"T-3">>, title => <<"Task A">>,
          body => null, author => null, labels => [], metadata => #{},
          created_at => <<"2026-01-01T00:00:00Z">>, updated_at => <<"2026-01-01T00:00:00Z">>},
        #{id => <<"github:t/r#5">>, source_type => <<"github">>,
          source_ref => <<"t/r#5">>, title => <<"Issue 5">>,
          body => null, author => null, labels => [], metadata => #{},
          created_at => <<"2026-01-01T00:00:00Z">>, updated_at => <<"2026-01-01T00:00:00Z">>}
    ],
    MC = #{commits => [<<"eee555">>], repository => <<"t/r">>,
           target_branch => <<"main">>, actor => <<"a">>,
           merged_at => <<"2026-01-02T00:00:00Z">>},
    {ok, W} = warrant_object:create(IS, MC, <<"Multi-intent change">>, #{}),
    ?assertEqual(64, byte_size(maps:get(warrant_id, W))),

    %% Both intent sources should be persisted
    {ok, IS1} = warrant_intent:get(<<"backlog:T-3">>),
    ?assertEqual(<<"Task A">>, maps:get(title, IS1)),
    {ok, IS2} = warrant_intent:get(<<"github:t/r#5">>),
    ?assertEqual(<<"Issue 5">>, maps:get(title, IS2)).
