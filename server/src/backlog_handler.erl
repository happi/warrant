-module(backlog_handler).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, #{action := health} = State) ->
    json_reply(200, #{status => <<"ok">>}, Req0, State);
init(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"OPTIONS">> -> preflight(Req0, State);
        _ -> route(Req0, State)
    end.

route(Req0, #{action := list} = State) ->
    case cowboy_req:method(Req0) of
        <<"GET">> -> handle_list(Req0, State);
        <<"POST">> -> handle_create(Req0, State);
        _ -> method_not_allowed(Req0, State)
    end;
route(Req0, #{action := task} = State) ->
    case cowboy_req:method(Req0) of
        <<"GET">> -> handle_view(Req0, State);
        <<"PUT">> -> handle_edit(Req0, State);
        _ -> method_not_allowed(Req0, State)
    end;
route(Req0, #{action := search} = State) ->
    case cowboy_req:method(Req0) of
        <<"GET">> -> handle_search(Req0, State);
        _ -> method_not_allowed(Req0, State)
    end.

%% CORS preflight
preflight(Req0, State) ->
    Req = cowboy_req:reply(204, cors_headers(), <<>>, Req0),
    {ok, Req, State}.

%% GET /api/backlog/tasks?status=...&assignee=...&priority=...
handle_list(Req0, State) ->
    QS = cowboy_req:parse_qs(Req0),
    Opts = maps:from_list([{binary_to_atom(K, utf8), V} || {K, V} <- QS,
                            lists:member(K, [<<"status">>, <<"assignee">>, <<"priority">>])]),
    case backlog_srv:list_tasks(Opts) of
        {ok, Tasks} -> json_reply(200, #{tasks => Tasks}, Req0, State);
        {error, Reason} -> json_reply(500, #{error => to_bin(Reason)}, Req0, State)
    end.

%% GET /api/backlog/tasks/:id
handle_view(Req0, State) ->
    Id = cowboy_req:binding(id, Req0),
    case backlog_srv:view_task(Id) of
        {ok, Task} -> json_reply(200, Task, Req0, State);
        {error, Reason} -> json_reply(500, #{error => to_bin(Reason)}, Req0, State)
    end.

%% GET /api/backlog/search?q=...
handle_search(Req0, State) ->
    QS = cowboy_req:parse_qs(Req0),
    Query = proplists:get_value(<<"q">>, QS, <<"">>),
    case backlog_srv:search_tasks(Query) of
        {ok, Results} -> json_reply(200, #{results => Results}, Req0, State);
        {error, Reason} -> json_reply(500, #{error => to_bin(Reason)}, Req0, State)
    end.

%% POST /api/backlog/tasks  {title, description, priority, labels, status, parent}
handle_create(Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    case decode_json(Body) of
        {ok, Params} ->
            case backlog_srv:create_task(Params) of
                {ok, Result} -> json_reply(201, Result, Req1, State);
                {error, Reason} -> json_reply(500, #{error => to_bin(Reason)}, Req1, State)
            end;
        {error, _} ->
            json_reply(400, #{error => <<"Invalid JSON body">>}, Req1, State)
    end.

%% PUT /api/backlog/tasks/:id  {status, assignee, priority, notes, title, description, labels}
handle_edit(Req0, State) ->
    Id = cowboy_req:binding(id, Req0),
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    case decode_json(Body) of
        {ok, Params} ->
            case backlog_srv:edit_task(Id, Params) of
                {ok, Result} -> json_reply(200, Result, Req1, State);
                {error, Reason} -> json_reply(500, #{error => to_bin(Reason)}, Req1, State)
            end;
        {error, _} ->
            json_reply(400, #{error => <<"Invalid JSON body">>}, Req1, State)
    end.

method_not_allowed(Req0, State) ->
    json_reply(405, #{error => <<"Method not allowed">>}, Req0, State).

%% Safe JSON decoding — returns {ok, Map} | {error, badarg}
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
      <<"access-control-allow-methods">> => <<"GET, POST, PUT, OPTIONS">>,
      <<"access-control-allow-headers">> => <<"content-type">>,
      <<"access-control-max-age">> => <<"86400">>}.

json_reply(Status, Data, Req0, State) ->
    Body = jsx:encode(Data),
    Headers = (cors_headers())#{<<"content-type">> => <<"application/json">>},
    Req = cowboy_req:reply(Status, Headers, Body, Req0),
    {ok, Req, State}.

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(T) -> list_to_binary(io_lib:format("~p", [T])).
