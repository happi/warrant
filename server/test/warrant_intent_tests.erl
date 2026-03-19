-module(warrant_intent_tests).
-include_lib("eunit/include/eunit.hrl").

%% Backlog plugin extracts PREFIX-NNN patterns.
backlog_extract_basic_test() ->
    Refs = warrant_intent_backlog:extract_refs(<<"Fix HL-131 display">>, #{}),
    ?assertEqual([<<"HL-131">>], Refs).

backlog_extract_multiple_test() ->
    Refs = warrant_intent_backlog:extract_refs(
        <<"HL-131 and SF-7 and AUR-99">>, #{}),
    ?assertEqual([<<"AUR-99">>, <<"HL-131">>, <<"SF-7">>], Refs).

backlog_extract_from_branch_test() ->
    Refs = warrant_intent_backlog:extract_refs(
        <<"task/W-28-publish-vscode-extension">>, #{}),
    ?assertEqual([<<"W-28">>], Refs).

backlog_extract_none_test() ->
    Refs = warrant_intent_backlog:extract_refs(<<"no refs here">>, #{}),
    ?assertEqual([], Refs).

backlog_extract_dedup_test() ->
    Refs = warrant_intent_backlog:extract_refs(
        <<"HL-131: fix HL-131 display for HL-131">>, #{}),
    ?assertEqual([<<"HL-131">>], Refs).

%% GitHub plugin extracts #NNN and owner/repo#NNN patterns.
github_extract_qualified_test() ->
    Refs = warrant_intent_github:extract_refs(
        <<"see happi/warrant#42">>, #{}),
    ?assertEqual([<<"happi/warrant#42">>], Refs).

github_extract_unqualified_with_repo_test() ->
    Refs = warrant_intent_github:extract_refs(
        <<"Fixes #42">>, #{repository => <<"happi/warrant">>}),
    ?assertEqual([<<"happi/warrant#42">>], Refs).

github_extract_unqualified_no_repo_test() ->
    %% Without repository context, unqualified #N refs are ignored
    Refs = warrant_intent_github:extract_refs(<<"Fixes #42">>, #{}),
    ?assertEqual([], Refs).

github_extract_multiple_test() ->
    Refs = warrant_intent_github:extract_refs(
        <<"Fixes #42 and see org/other#7">>,
        #{repository => <<"happi/warrant">>}),
    ?assertEqual([<<"happi/warrant#42">>, <<"org/other#7">>], Refs).

%% Combined extraction via warrant_intent.
combined_extraction_test() ->
    Text = <<"HL-131: fix bug. Closes #42">>,
    Config = #{repository => <<"happi/warrant">>},
    Refs = warrant_intent:extract_refs(Text, Config),
    ?assert(lists:member({<<"backlog">>, <<"HL-131">>}, Refs)),
    ?assert(lists:member({<<"github">>, <<"happi/warrant#42">>}, Refs)).

%% Plugin registry returns both plugins.
plugins_test() ->
    Plugins = warrant_intent:plugins(),
    ?assertEqual(2, length(Plugins)),
    ?assert(lists:member(warrant_intent_backlog, Plugins)),
    ?assert(lists:member(warrant_intent_github, Plugins)).

%% Source type strings are correct.
source_types_test() ->
    ?assertEqual(<<"backlog">>, warrant_intent_backlog:source_type()),
    ?assertEqual(<<"github">>, warrant_intent_github:source_type()).

%% GitHub from_issue_map produces correct intent source.
github_from_issue_map_test() ->
    Issue = #{number => 42, title => <<"Login broken">>,
              body => <<"Users can't log in">>,
              author => <<"happi">>, labels => [<<"bug">>],
              state => <<"open">>},
    IS = warrant_intent_github:from_issue_map(Issue, <<"happi/warrant">>),
    ?assertEqual(<<"github:happi/warrant#42">>, maps:get(id, IS)),
    ?assertEqual(<<"github">>, maps:get(source_type, IS)),
    ?assertEqual(<<"happi/warrant#42">>, maps:get(source_ref, IS)),
    ?assertEqual(<<"Login broken">>, maps:get(title, IS)),
    ?assertEqual(<<"happi">>, maps:get(author, IS)).

%% GitHub from_webhook produces correct intent source.
github_from_webhook_test() ->
    Payload = #{<<"number">> => 7, <<"title">> => <<"Fix CSS">>,
                <<"body">> => <<"Broken layout">>,
                <<"user">> => #{<<"login">> => <<"bob">>},
                <<"labels">> => [#{<<"name">> => <<"frontend">>}],
                <<"state">> => <<"open">>,
                <<"created_at">> => <<"2026-01-01T00:00:00Z">>,
                <<"updated_at">> => <<"2026-01-02T00:00:00Z">>},
    IS = warrant_intent_github:from_webhook(Payload, <<"org/repo">>),
    ?assertEqual(<<"github:org/repo#7">>, maps:get(id, IS)),
    ?assertEqual(<<"Fix CSS">>, maps:get(title, IS)),
    ?assertEqual(<<"bob">>, maps:get(author, IS)),
    ?assertEqual([<<"frontend">>], maps:get(labels, IS)).
