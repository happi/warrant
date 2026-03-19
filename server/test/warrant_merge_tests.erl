-module(warrant_merge_tests).
-include_lib("eunit/include/eunit.hrl").

%% Extract refs from a typical PR merge event.
extract_refs_basic_test() ->
    Event = #{
        branch => <<"task/HL-131-fix-week">>,
        commits => [<<"abc">>],
        commit_messages => [<<"HL-131: Fix week display">>],
        pr_title => <<"HL-131: Fix week number">>,
        pr_body => <<>>,
        repository => <<"happi/home_display">>,
        target_branch => <<"main">>
    },
    Refs = warrant_merge:extract_all_refs(Event),
    ?assert(lists:member({<<"backlog">>, <<"HL-131">>}, Refs)).

%% Extracts from PR body as well.
extract_refs_from_body_test() ->
    Event = #{
        branch => <<"fix/stuff">>,
        commits => [],
        commit_messages => [],
        pr_title => <<"Fix stuff">>,
        pr_body => <<"Addresses HL-42 and closes #7">>,
        repository => <<"happi/warrant">>,
        target_branch => <<"main">>
    },
    Refs = warrant_merge:extract_all_refs(Event),
    ?assert(lists:member({<<"backlog">>, <<"HL-42">>}, Refs)),
    ?assert(lists:member({<<"github">>, <<"happi/warrant#7">>}, Refs)).

%% No refs found in event with no references.
extract_refs_empty_test() ->
    Event = #{
        branch => <<"chore/update-deps">>,
        commits => [],
        commit_messages => [<<"Update dependencies">>],
        pr_title => <<"Update deps">>,
        pr_body => <<>>,
        repository => <<"happi/warrant">>,
        target_branch => <<"main">>
    },
    Refs = warrant_merge:extract_all_refs(Event),
    ?assertEqual([], Refs).

%% Deduplication: same ref from branch + commit message counted once.
extract_refs_dedup_test() ->
    Event = #{
        branch => <<"task/W-10-tests">>,
        commits => [],
        commit_messages => [<<"W-10: Add tests">>, <<"W-10: More tests">>],
        pr_title => <<"W-10: Add server tests">>,
        pr_body => <<>>,
        repository => <<"happi/warrant">>,
        target_branch => <<"main">>
    },
    Refs = warrant_merge:extract_all_refs(Event),
    BacklogRefs = [R || {<<"backlog">>, R} <- Refs],
    ?assertEqual([<<"W-10">>], BacklogRefs).

%% Resolve intents produces stubs for unresolvable refs.
resolve_stubs_test() ->
    %% This ref won't resolve (no backlog_srv running, no file)
    Refs = [{<<"backlog">>, <<"FAKE-999">>}],
    {ok, Intents} = warrant_merge:resolve_intents(Refs),
    ?assertEqual(1, length(Intents)),
    [Intent] = Intents,
    ?assertEqual(<<"backlog:FAKE-999">>, maps:get(id, Intent)),
    ?assertEqual(<<"(unresolved)">>, maps:get(title, Intent)).

%% Multiple mixed refs resolve to intent sources.
resolve_multiple_stubs_test() ->
    Refs = [{<<"backlog">>, <<"X-1">>}, {<<"github">>, <<"o/r#42">>}],
    {ok, Intents} = warrant_merge:resolve_intents(Refs),
    ?assertEqual(2, length(Intents)),
    Ids = lists:sort([maps:get(id, I) || I <- Intents]),
    ?assertEqual([<<"backlog:X-1">>, <<"github:o/r#42">>], Ids).
