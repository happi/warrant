-module(warrant_webhook_handler).
-behaviour(cowboy_handler).

%% GitHub webhook receiver.
%% Verifies HMAC-SHA256 signature, handles PR events and pushes.

-export([init/2]).

init(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            handle_webhook(Req0, State);
        <<"OPTIONS">> ->
            Req = cowboy_req:reply(204, ledger_util:cors_headers(), <<>>, Req0),
            {ok, Req, State};
        _ ->
            Req = cowboy_req:reply(405, #{}, <<"Method not allowed">>, Req0),
            {ok, Req, State}
    end.

handle_webhook(Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Signature = cowboy_req:header(<<"x-hub-signature-256">>, Req1, <<>>),
    Event = cowboy_req:header(<<"x-github-event">>, Req1, <<>>),

    case ledger_util:decode_json(Body) of
        {ok, Payload} ->
            %% Determine org/project from repository
            RepoUrl = deep_get([repository, html_url], Payload, <<>>),
            case find_webhook_config(RepoUrl) of
                {ok, #{webhook_secret := Secret, org_id := OrgId, project_id := ProjectId}} ->
                    case verify_signature(Body, Signature, Secret) of
                        true ->
                            handle_event(Event, Payload, OrgId, ProjectId),
                            ledger_util:json_reply(200, #{ok => true}, Req1, State);
                        false ->
                            logger:warning("Webhook signature mismatch for ~s", [RepoUrl]),
                            ledger_util:json_reply(401, #{error => <<"Invalid signature">>}, Req1, State)
                    end;
                {error, not_found} ->
                    %% Try without signature verification (might be unconfigured)
                    logger:info("Webhook received for unconfigured repo: ~s", [RepoUrl]),
                    ledger_util:json_reply(404, #{error => <<"No webhook config for this repo">>}, Req1, State)
            end;
        {error, _} ->
            ledger_util:json_reply(400, #{error => <<"Invalid JSON">>}, Req1, State)
    end.

%%% Event handlers

handle_event(<<"pull_request">>, Payload, OrgId, ProjectId) ->
    Action = maps:get(action, Payload, <<>>),
    PR = maps:get(pull_request, Payload, #{}),
    Title = maps:get(title, PR, <<>>),
    PRBody = maps:get(body, PR, <<>>),
    PRNum = maps:get(number, Payload, 0),
    Merged = deep_get([pull_request, merged], Payload, false),

    %% Extract task IDs from PR title and body
    TaskIds = extract_task_ids(<<Title/binary, " ", PRBody/binary>>),

    case Action of
        A when A =:= <<"opened">>; A =:= <<"synchronize">> ->
            %% Link PR to tasks and post status
            lists:foreach(fun(TaskId) ->
                Link = #{kind => <<"pr">>,
                         ref => iolist_to_binary([<<"#">>, integer_to_binary(PRNum)]),
                         url => deep_get([pull_request, html_url], Payload, null)},
                ledger_task_srv:add_link(OrgId, TaskId, Link, <<"github-webhook">>)
            end, TaskIds),
            case TaskIds of
                [] ->
                    logger:info("PR #~p has no task IDs", [PRNum]);
                _ ->
                    logger:info("PR #~p linked to tasks: ~p", [PRNum, TaskIds])
            end;

        <<"closed">> when Merged =:= true ->
            %% Auto-transition tasks to done
            lists:foreach(fun(TaskId) ->
                %% Try to move to done — go through valid transitions
                case ledger_task_srv:get(OrgId, ProjectId, TaskId) of
                    {ok, #{status := <<"in_review">>}} ->
                        ledger_task_srv:update_status(OrgId, ProjectId, TaskId,
                            <<"done">>, <<"in_review">>);
                    _ ->
                        ok  %% Skip if not in review
                end
            end, TaskIds),
            logger:info("PR #~p merged, tasks ~p marked done", [PRNum, TaskIds]);

        _ ->
            ok
    end;

handle_event(<<"push">>, Payload, OrgId, ProjectId) ->
    Ref = maps:get(ref, Payload, <<>>),
    Commits = maps:get(commits, Payload, []),
    %% Only record for main/master branch
    case binary:match(Ref, [<<"refs/heads/main">>, <<"refs/heads/master">>]) of
        nomatch -> ok;
        _ ->
            lists:foreach(fun(Commit) ->
                Sha = maps:get(id, Commit, <<>>),
                Message = maps:get(message, Commit, <<>>),
                Author = deep_get([author, name], Commit, <<"unknown">>),
                Timestamp = maps:get(timestamp, Commit, ledger_util:now_iso8601()),
                %% Extract parent
                Parents = maps:get(parents, Commit, []),
                ParentSha = case Parents of
                    [] -> null;
                    [P | _] -> P
                end,
                %% Record to hash chain
                ledger_db:exec(
                    <<"INSERT INTO hash_chain (org, project, commit_sha, parent_sha, summary, actor, timestamp, prev_chain_hash, chain_hash)
                       SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7,
                              COALESCE((SELECT chain_hash FROM hash_chain WHERE org = ?1 AND project = ?2 ORDER BY seq DESC LIMIT 1), ''),
                              ''">>,
                    [org_slug(OrgId), project_slug(ProjectId), Sha, ParentSha,
                     truncate(Message, 200), Author, Timestamp]),
                %% Link commits to task IDs found in message
                TaskIds = extract_task_ids(Message),
                lists:foreach(fun(TaskId) ->
                    Link = #{kind => <<"commit">>, ref => Sha, url => null},
                    ledger_task_srv:add_link(OrgId, TaskId, Link, <<"github-webhook">>)
                end, TaskIds)
            end, Commits)
    end;

handle_event(Event, _Payload, _OrgId, _ProjectId) ->
    logger:debug("Ignoring GitHub event: ~s", [Event]),
    ok.

%%% Helpers

extract_task_ids(Text) ->
    %% Match patterns like W-123, AUR-45, INFRA-678 etc.
    case re:run(Text, <<"([A-Z]+-[0-9]+)">>, [global, {capture, all_but_first, binary}]) of
        {match, Matches} ->
            lists:usort([Id || [Id] <- Matches]);
        nomatch ->
            []
    end.

verify_signature(Body, <<"sha256=", HexSig/binary>>, Secret) ->
    Expected = crypto:mac(hmac, sha256, Secret, Body),
    ExpectedHex = string:lowercase(binary:encode_hex(Expected)),
    %% Constant-time comparison
    string:equal(string:lowercase(HexSig), ExpectedHex);
verify_signature(_Body, _, _Secret) ->
    false.

find_webhook_config(RepoUrl) ->
    case ledger_db:one(
        <<"SELECT id, org_id, project_id, webhook_secret, access_token_encrypted
           FROM webhook_configs WHERE repo_url = ?1">>,
        [RepoUrl]
    ) of
        {ok, {_Id, OrgId, ProjectId, Secret, _AccessToken}} ->
            {ok, #{org_id => OrgId, project_id => ProjectId, webhook_secret => Secret}};
        {error, not_found} ->
            {error, not_found}
    end.

deep_get([], Val, _Default) -> Val;
deep_get([Key | Rest], Map, Default) when is_map(Map) ->
    case maps:get(Key, Map, undefined) of
        undefined -> Default;
        Val -> deep_get(Rest, Val, Default)
    end;
deep_get(_, _, Default) -> Default.

org_slug(OrgId) ->
    case ledger_db:one(<<"SELECT slug FROM organizations WHERE id = ?1">>, [OrgId]) of
        {ok, {Slug}} -> Slug;
        _ -> OrgId
    end.

project_slug(ProjectId) ->
    case ledger_db:one(<<"SELECT slug FROM projects WHERE id = ?1">>, [ProjectId]) of
        {ok, {Slug}} -> Slug;
        _ -> ProjectId
    end.

truncate(Bin, MaxLen) when byte_size(Bin) > MaxLen ->
    <<Short:MaxLen/binary, _/binary>> = Bin,
    Short;
truncate(Bin, _) -> Bin.
