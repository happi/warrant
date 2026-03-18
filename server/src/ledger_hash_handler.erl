-module(ledger_hash_handler).
-behaviour(cowboy_handler).

%% Append-only hash chain for compliance notarization.
%%
%% POST /api/ledger/record
%%   Body: {org, project, commit_sha, parent_sha, summary, actor, timestamp}
%%   201: {seq, chain_hash}
%%
%% GET /api/ledger/chain/:org/:project
%%   200: [{seq, commit_sha, chain_hash, timestamp, ...}, ...]
%%
%% GET /api/ledger/verify/:org/:project
%%   200: {valid: true, length: N} or {valid: false, break_at: seq}

-export([init/2]).

init(Req0, #{action := Action} = State) ->
    case cowboy_req:method(Req0) of
        <<"OPTIONS">> ->
            Req = cowboy_req:reply(204, ledger_util:cors_headers(), <<>>, Req0),
            {ok, Req, State};
        Method ->
            handle(Action, Method, Req0, State)
    end.

%% POST /api/ledger/record — append to hash chain
handle(record, <<"POST">>, Req0, State) ->
    ledger_auth:require_superadmin(Req0, State, fun(_User, Req, S) ->
        {ok, Body, Req1} = cowboy_req:read_body(Req),
        case ledger_util:decode_json(Body) of
            {ok, #{org := Org, project := Proj, commit_sha := CommitSha,
                   actor := Actor, timestamp := Ts} = Params} ->
                ParentSha = maps:get(parent_sha, Params, null),
                Summary = maps:get(summary, Params, null),
                append_to_chain(Org, Proj, CommitSha, ParentSha, Summary, Actor, Ts, Req1, S);
            {ok, _} ->
                ledger_util:json_reply(400, #{error => #{
                    code => <<"bad_request">>,
                    message => <<"Required: org, project, commit_sha, actor, timestamp">>
                }}, Req1, S);
            {error, _} ->
                ledger_util:json_reply(400, #{error => #{
                    code => <<"bad_request">>, message => <<"Invalid JSON">>
                }}, Req1, S)
        end
    end);

%% GET /api/ledger/chain/:org/:project — read the chain
handle(chain, <<"GET">>, Req0, State) ->
    ledger_auth:require_superadmin(Req0, State, fun(_User, Req, S) ->
        Org = cowboy_req:binding(org, Req),
        Proj = cowboy_req:binding(project, Req),
        QS = cowboy_req:parse_qs(Req),
        Limit = qs_int(<<"limit">>, QS, 100),
        Offset = qs_int(<<"offset">>, QS, 0),
        Rows = ledger_db:q(
            <<"SELECT seq, commit_sha, parent_sha, summary, actor, timestamp,
                      prev_chain_hash, chain_hash
               FROM hash_chain WHERE org = ?1 AND project = ?2
               ORDER BY seq ASC LIMIT ?3 OFFSET ?4">>,
            [Org, Proj, Limit, Offset]
        ),
        Entries = [#{seq => Seq, commit_sha => Sha, parent_sha => PSha,
                     summary => Sum, actor => Act, timestamp => T,
                     prev_chain_hash => Prev, chain_hash => Hash}
                   || {Seq, Sha, PSha, Sum, Act, T, Prev, Hash} <- Rows],
        ledger_util:json_reply(200, #{data => Entries}, Req, S)
    end);

%% GET /api/ledger/verify/:org/:project — verify chain integrity
handle(verify, <<"GET">>, Req0, State) ->
    ledger_auth:require_superadmin(Req0, State, fun(_User, Req, S) ->
        Org = cowboy_req:binding(org, Req),
        Proj = cowboy_req:binding(project, Req),
        Rows = ledger_db:q(
            <<"SELECT seq, commit_sha, timestamp, prev_chain_hash, chain_hash
               FROM hash_chain WHERE org = ?1 AND project = ?2
               ORDER BY seq ASC">>,
            [Org, Proj]
        ),
        case verify_chain(Rows) of
            {ok, Length} ->
                ledger_util:json_reply(200, #{data => #{
                    valid => true, length => Length
                }}, Req, S);
            {error, BreakSeq} ->
                ledger_util:json_reply(200, #{data => #{
                    valid => false, break_at => BreakSeq
                }}, Req, S)
        end
    end);

handle(_, _, Req0, State) ->
    ledger_util:json_reply(405, #{error => #{
        code => <<"method_not_allowed">>, message => <<"Method not allowed">>
    }}, Req0, State).

%%% Internal

append_to_chain(Org, Proj, CommitSha, ParentSha, Summary, Actor, Ts, Req, State) ->
    %% Get the previous chain hash (last entry for this org/project)
    PrevChainHash = case ledger_db:one(
        <<"SELECT chain_hash FROM hash_chain
           WHERE org = ?1 AND project = ?2
           ORDER BY seq DESC LIMIT 1">>,
        [Org, Proj]
    ) of
        {ok, {Hash}} -> Hash;
        {error, not_found} -> <<"genesis">>
    end,

    %% Compute the new chain hash: SHA-256(prev_chain_hash | commit_sha | timestamp)
    ChainInput = <<PrevChainHash/binary, "|", CommitSha/binary, "|", Ts/binary>>,
    ChainHash = string:lowercase(binary:encode_hex(crypto:hash(sha256, ChainInput))),

    ok = ledger_db:exec(
        <<"INSERT INTO hash_chain
           (org, project, commit_sha, parent_sha, summary, actor, timestamp,
            prev_chain_hash, chain_hash)
           VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)">>,
        [Org, Proj, CommitSha, ParentSha, Summary, Actor, Ts,
         PrevChainHash, ChainHash]
    ),

    %% Get the seq of the just-inserted row
    [{Seq}] = ledger_db:q(<<"SELECT last_insert_rowid()">>, []),

    ledger_util:json_reply(201, #{data => #{
        seq => Seq,
        chain_hash => ChainHash,
        prev_chain_hash => PrevChainHash
    }}, Req, State).

verify_chain(Rows) ->
    verify_chain(Rows, <<"genesis">>, 0).

verify_chain([], _ExpectedPrev, Count) ->
    {ok, Count};
verify_chain([{Seq, CommitSha, Ts, PrevChainHash, ChainHash} | Rest], ExpectedPrev, Count) ->
    case PrevChainHash of
        ExpectedPrev ->
            %% Recompute the chain hash
            ChainInput = <<PrevChainHash/binary, "|", CommitSha/binary, "|", Ts/binary>>,
            Recomputed = string:lowercase(binary:encode_hex(crypto:hash(sha256, ChainInput))),
            case Recomputed of
                ChainHash ->
                    verify_chain(Rest, ChainHash, Count + 1);
                _ ->
                    {error, Seq}
            end;
        _ ->
            {error, Seq}
    end.

qs_int(Key, QS, Default) ->
    case proplists:get_value(Key, QS) of
        undefined -> Default;
        V -> try binary_to_integer(V) catch _:_ -> Default end
    end.
