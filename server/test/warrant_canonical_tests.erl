-module(warrant_canonical_tests).
-include_lib("eunit/include/eunit.hrl").

%% Determinism: same input always produces same output.
determinism_test() ->
    Content = #{summary => <<"Test">>, merge => #{actor => <<"a">>,
        commits => [<<"c1">>], merged_at => <<"2026-01-01T00:00:00Z">>,
        repository => <<"o/r">>, target_branch => <<"main">>}},
    {Id1, Json1} = warrant_canonical:warrant_id(Content),
    {Id2, Json2} = warrant_canonical:warrant_id(Content),
    ?assertEqual(Id1, Id2),
    ?assertEqual(Json1, Json2).

%% ID is 64-char lowercase hex (SHA-256).
id_format_test() ->
    {Id, _} = warrant_canonical:warrant_id(#{summary => <<"x">>,
        merge => #{actor => <<"a">>, commits => [<<"c">>],
        merged_at => <<"t">>, repository => <<"r">>, target_branch => <<"m">>}}),
    ?assertEqual(64, byte_size(Id)),
    ?assertMatch({match, _}, re:run(Id, "^[0-9a-f]{64}$")).

%% Keys are sorted alphabetically.
key_sorting_test() ->
    Json = warrant_canonical:encode(#{z => 1, a => 2, m => 3}),
    %% "a" must appear before "m" which must appear before "z"
    {match, [{APos, _}]} = re:run(Json, "\"a\""),
    {match, [{MPos, _}]} = re:run(Json, "\"m\""),
    {match, [{ZPos, _}]} = re:run(Json, "\"z\""),
    ?assert(APos < MPos),
    ?assert(MPos < ZPos).

%% String arrays are sorted lexicographically.
array_sorting_test() ->
    Json = warrant_canonical:encode(#{items => [<<"c">>, <<"a">>, <<"b">>]}),
    {match, [{APos, _}]} = re:run(Json, "\"a\""),
    {match, [{BPos, _}]} = re:run(Json, "\"b\""),
    {match, [{CPos, _}]} = re:run(Json, "\"c\""),
    ?assert(APos < BPos),
    ?assert(BPos < CPos).

%% Object arrays are sorted by id field.
object_array_sorting_test() ->
    Json = warrant_canonical:encode(#{items => [
        #{id => <<"z">>, name => <<"last">>},
        #{id => <<"a">>, name => <<"first">>}
    ]}),
    {match, [{APos, _}]} = re:run(Json, "\"a\""),
    {match, [{ZPos, _}]} = re:run(Json, "\"z\""),
    ?assert(APos < ZPos).

%% Null, undefined, empty string, empty list are omitted.
omission_test() ->
    Json = warrant_canonical:encode(#{
        keep => <<"yes">>,
        null_val => null,
        undef_val => undefined,
        empty_str => <<>>,
        empty_list => []
    }),
    ?assertMatch(nomatch, re:run(Json, "null_val")),
    ?assertMatch(nomatch, re:run(Json, "undef_val")),
    ?assertMatch(nomatch, re:run(Json, "empty_str")),
    ?assertMatch(nomatch, re:run(Json, "empty_list")),
    ?assertMatch({match, _}, re:run(Json, "keep")).

%% Version field is added automatically.
version_field_test() ->
    Json = warrant_canonical:canonical_json(#{summary => <<"t">>}),
    ?assertMatch({match, _}, re:run(Json, "\"version\":1")).

%% JSON string escaping.
escaping_test() ->
    Json = warrant_canonical:encode(#{msg => <<"line1\nline2\ttab \"quoted\"">>}),
    ?assertMatch({match, _}, re:run(Json, "\\\\n")),
    ?assertMatch({match, _}, re:run(Json, "\\\\t")),
    ?assertMatch({match, _}, re:run(Json, "\\\\\"quoted")).

%% Different content produces different IDs.
different_content_different_id_test() ->
    Base = #{summary => <<"A">>, merge => #{actor => <<"a">>,
        commits => [<<"c">>], merged_at => <<"t">>,
        repository => <<"r">>, target_branch => <<"m">>}},
    {Id1, _} = warrant_canonical:warrant_id(Base),
    {Id2, _} = warrant_canonical:warrant_id(Base#{summary => <<"B">>}),
    ?assertNotEqual(Id1, Id2).

%% Nested maps have sorted keys.
nested_sorting_test() ->
    Json = warrant_canonical:encode(#{outer => #{z => 1, a => 2}}),
    %% Inside the nested object, "a" before "z"
    {match, [{APos, _}]} = re:run(Json, "\"a\""),
    {match, [{ZPos, _}]} = re:run(Json, "\"z\""),
    ?assert(APos < ZPos).

%% Integer encoding.
integer_test() ->
    ?assertEqual(<<"42">>, warrant_canonical:encode(42)),
    ?assertEqual(<<"0">>, warrant_canonical:encode(0)).

%% Boolean encoding.
boolean_test() ->
    ?assertEqual(<<"true">>, warrant_canonical:encode(true)),
    ?assertEqual(<<"false">>, warrant_canonical:encode(false)).
