-module(warrant_canonical).

%% Deterministic JSON serialization and content-addressed hashing.
%%
%% The warrant ID is sha256(canonical_json). This module is the single
%% place where that computation happens. The canonical form is defined by:
%%
%%   1. Object keys sorted lexicographically
%%   2. String arrays sorted lexicographically
%%   3. Object arrays sorted by "id" field
%%   4. Compact JSON (no whitespace)
%%   5. Null / undefined / empty-string / empty-list values omitted
%%   6. UTF-8 throughout
%%   7. Schema version field present
%%
%% Same content → same bytes → same hash. Always.

-export([warrant_id/1, canonical_json/1]).
-export([encode/1]).

-define(VERSION, 1).

%% Compute the warrant ID from warrant content.
%% Input: a map with keys like intent_sources, merge, summary.
%% Returns {WarrantId, CanonicalJson} where WarrantId is a 64-char
%% lowercase hex string.
-spec warrant_id(map()) -> {binary(), binary()}.
warrant_id(Content) ->
    Json = canonical_json(Content),
    Hash = crypto:hash(sha256, Json),
    Hex = string:lowercase(binary:encode_hex(Hash)),
    {Hex, Json}.

%% Produce the canonical JSON for a warrant content map.
%% Adds the version field, cleans values, sorts everything.
-spec canonical_json(map()) -> binary().
canonical_json(Content) ->
    Versioned = Content#{version => ?VERSION},
    encode(Versioned).

%% Encode any Erlang term to canonical JSON.
%% Maps become sorted-key objects. Lists become arrays (sorted where
%% elements are all binaries or all maps-with-id).
-spec encode(term()) -> binary().
encode(Map) when is_map(Map) ->
    Pairs = lists:sort(maps:to_list(Map)),
    Cleaned = [{ensure_binary_key(K), V} || {K, V} <- Pairs,
               not is_omitted(V)],
    Inner = lists:join($,,
        [[$", escape(K), $", $:, encode(V)] || {K, V} <- Cleaned]),
    iolist_to_binary([${, Inner, $}]);
encode(List) when is_list(List) ->
    Sorted = sort_array(List),
    Inner = lists:join($,, [encode(V) || V <- Sorted]),
    iolist_to_binary([$[, Inner, $]]);
encode(Bin) when is_binary(Bin) ->
    iolist_to_binary([$", escape(Bin), $"]);
encode(N) when is_integer(N) ->
    integer_to_binary(N);
encode(true) -> <<"true">>;
encode(false) -> <<"false">>;
encode(N) when is_float(N) ->
    float_to_binary(N, [{decimals, 10}, compact]).

%%% Internal

is_omitted(null)      -> true;
is_omitted(undefined) -> true;
is_omitted(<<>>)      -> true;
is_omitted([])        -> true;
is_omitted(_)         -> false.

ensure_binary_key(K) when is_binary(K) -> K;
ensure_binary_key(K) when is_atom(K) -> atom_to_binary(K, utf8);
ensure_binary_key(K) when is_list(K) -> list_to_binary(K).

%% Sort arrays for determinism.
%% - All binaries → lexicographic sort
%% - All maps with an 'id' key → sort by id
%% - Otherwise → sort by canonical JSON representation
sort_array([]) -> [];
sort_array([H | _] = List) when is_binary(H) ->
    lists:sort(List);
sort_array([H | _] = List) when is_map(H) ->
    case maps:is_key(id, H) orelse maps:is_key(<<"id">>, H) of
        true ->
            lists:sort(fun(A, B) ->
                IdA = maps:get(id, A, maps:get(<<"id">>, A, <<>>)),
                IdB = maps:get(id, B, maps:get(<<"id">>, B, <<>>)),
                IdA =< IdB
            end, List);
        false ->
            lists:sort(fun(A, B) -> encode(A) =< encode(B) end, List)
    end;
sort_array(List) ->
    List.

%% JSON string escaping (RFC 8259).
escape(Bin) ->
    escape(Bin, <<>>).

escape(<<>>, Acc) -> Acc;
escape(<<$", Rest/binary>>, Acc) -> escape(Rest, <<Acc/binary, $\\, $">>);
escape(<<$\\, Rest/binary>>, Acc) -> escape(Rest, <<Acc/binary, $\\, $\\>>);
escape(<<$\n, Rest/binary>>, Acc) -> escape(Rest, <<Acc/binary, $\\, $n>>);
escape(<<$\r, Rest/binary>>, Acc) -> escape(Rest, <<Acc/binary, $\\, $r>>);
escape(<<$\t, Rest/binary>>, Acc) -> escape(Rest, <<Acc/binary, $\\, $t>>);
escape(<<C, Rest/binary>>, Acc) when C < 16#20 ->
    Hex = string:lowercase(binary:encode_hex(<<C>>)),
    escape(Rest, <<Acc/binary, "\\u00", Hex/binary>>);
escape(<<C, Rest/binary>>, Acc) ->
    escape(Rest, <<Acc/binary, C>>).
