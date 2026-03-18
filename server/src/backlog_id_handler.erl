-module(backlog_id_handler).
-behaviour(cowboy_handler).

%% HTTP handler for the centralized ID counter service.
%% POST /api/id/next   — get next ID for a prefix
%% GET  /api/id/counters — list all counters
%% POST /api/id/sync   — set counter (monotonic)

-export([init/2]).

init(Req0, #{action := id_next} = State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> -> handle_next(Req0, State);
        <<"OPTIONS">> -> preflight(Req0, State);
        _ -> method_not_allowed(Req0, State)
    end;
init(Req0, #{action := id_counters} = State) ->
    case cowboy_req:method(Req0) of
        <<"GET">> -> handle_counters(Req0, State);
        <<"OPTIONS">> -> preflight(Req0, State);
        _ -> method_not_allowed(Req0, State)
    end;
init(Req0, #{action := id_sync} = State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> -> handle_sync(Req0, State);
        <<"OPTIONS">> -> preflight(Req0, State);
        _ -> method_not_allowed(Req0, State)
    end.

%% POST /api/id/next  {"prefix":"sf"} -> {"id":"SF-393","number":393}
handle_next(Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    case decode_json(Body) of
        {ok, #{prefix := Prefix}} when is_binary(Prefix), byte_size(Prefix) > 0 ->
            {ok, Result} = backlog_id_srv:next_id(Prefix),
            json_reply(200, Result, Req1, State);
        {ok, _} ->
            json_reply(400, #{error => <<"Missing or empty 'prefix' field">>}, Req1, State);
        {error, _} ->
            json_reply(400, #{error => <<"Invalid JSON body">>}, Req1, State)
    end.

%% GET /api/id/counters -> {"counters":{"sf":392,...}}
handle_counters(Req0, State) ->
    {ok, Counters} = backlog_id_srv:get_counters(),
    json_reply(200, #{counters => Counters}, Req0, State).

%% POST /api/id/sync  {"prefix":"sf","value":400} -> {"ok":true}
handle_sync(Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    case decode_json(Body) of
        {ok, #{prefix := Prefix, value := Value}} when is_binary(Prefix), is_integer(Value) ->
            case backlog_id_srv:sync(Prefix, Value) of
                ok ->
                    json_reply(200, #{ok => true}, Req1, State);
                {error, Reason} ->
                    json_reply(409, #{error => Reason}, Req1, State)
            end;
        {ok, _} ->
            json_reply(400, #{error => <<"Missing 'prefix' (string) and 'value' (integer) fields">>}, Req1, State);
        {error, _} ->
            json_reply(400, #{error => <<"Invalid JSON body">>}, Req1, State)
    end.

preflight(Req0, State) ->
    Req = cowboy_req:reply(204, cors_headers(), <<>>, Req0),
    {ok, Req, State}.

method_not_allowed(Req0, State) ->
    json_reply(405, #{error => <<"Method not allowed">>}, Req0, State).

decode_json(<<>>) ->
    {error, empty};
decode_json(Body) ->
    try
        {ok, jsx:decode(Body, [return_maps, {labels, atom}])}
    catch
        error:badarg -> {error, badarg}
    end.

cors_headers() ->
    #{<<"access-control-allow-origin">> => <<"*">>,
      <<"access-control-allow-methods">> => <<"GET, POST, OPTIONS">>,
      <<"access-control-allow-headers">> => <<"content-type">>,
      <<"access-control-max-age">> => <<"86400">>}.

json_reply(Status, Data, Req0, State) ->
    Body = jsx:encode(Data),
    Headers = (cors_headers())#{<<"content-type">> => <<"application/json">>},
    Req = cowboy_req:reply(Status, Headers, Body, Req0),
    {ok, Req, State}.
