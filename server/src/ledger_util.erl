-module(ledger_util).

%% Shared utilities for the Change Ledger.

-export([uuid/0, now_iso8601/0, json_reply/4, cors_headers/0,
         decode_json/1, to_bin/1]).

uuid() ->
    Hex = binary:encode_hex(crypto:strong_rand_bytes(16)),
    <<A:8/binary, B:4/binary, C:4/binary, D:4/binary, E:12/binary>> = Hex,
    LowerA = string:lowercase(A),
    LowerB = string:lowercase(B),
    LowerC = string:lowercase(C),
    LowerD = string:lowercase(D),
    LowerE = string:lowercase(E),
    <<LowerA/binary, $-, LowerB/binary, $-, LowerC/binary, $-,
      LowerD/binary, $-, LowerE/binary>>.

now_iso8601() ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:universal_time(),
    iolist_to_binary(io_lib:format(
        "~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ",
        [Y, Mo, D, H, Mi, S]
    )).

cors_headers() ->
    #{<<"access-control-allow-origin">> => <<"*">>,
      <<"access-control-allow-methods">> => <<"GET, POST, PATCH, DELETE, OPTIONS">>,
      <<"access-control-allow-headers">> => <<"content-type, authorization">>,
      <<"access-control-max-age">> => <<"86400">>}.

json_reply(Status, Data, Req0, State) ->
    Body = jsx:encode(sanitize(Data)),
    Headers = (cors_headers())#{<<"content-type">> => <<"application/json">>},
    Req = cowboy_req:reply(Status, Headers, Body, Req0),
    {ok, Req, State}.

%% Convert `undefined` atoms to `null` for JSON encoding
sanitize(undefined) -> null;
sanitize(M) when is_map(M) ->
    maps:map(fun(_K, V) -> sanitize(V) end, M);
sanitize(L) when is_list(L) ->
    [sanitize(E) || E <- L];
sanitize(V) -> V.

decode_json(<<>>) ->
    {error, empty};
decode_json(Body) ->
    try
        {ok, jsx:decode(Body, [return_maps, {labels, atom}])}
    catch
        error:badarg -> {error, badarg}
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(T) -> list_to_binary(io_lib:format("~p", [T])).
