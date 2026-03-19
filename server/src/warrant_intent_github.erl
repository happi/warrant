-module(warrant_intent_github).
-behaviour(warrant_intent).

%% GitHub Issues intent source plugin.
%%
%% Extracts issue references like #42 or owner/repo#42 from text.
%% Fetches issue metadata from GitHub API or accepts pre-fetched
%% webhook/API data.

-export([source_type/0, extract_refs/2, fetch/2]).
-export([from_webhook/2, from_issue_map/2]).

source_type() -> <<"github">>.

%% Extract GitHub issue references from text.
%% Matches:  #42  owner/repo#42  Fixes #42  Closes #42
%% Does NOT match bare numbers or SHA fragments.
extract_refs(Text, Config) ->
    Repo = maps:get(repository, Config, <<>>),
    %% Match qualified refs: owner/repo#NNN
    QualifiedRefs = case re:run(Text, "([a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+)#([0-9]+)",
                                [global, {capture, all_but_first, binary}]) of
        {match, QMatches} ->
            [{<<R/binary, "#", N/binary>>, N} || [R, N] <- QMatches];
        nomatch -> []
    end,
    %% Match unqualified refs: #NNN (not preceded by alphanumeric)
    %% These are scoped to the Config repository.
    UnqualifiedRefs = case re:run(Text, "(?:^|[^a-zA-Z0-9_/])#([0-9]+)",
                                  [global, {capture, all_but_first, binary}]) of
        {match, UMatches} ->
            case Repo of
                <<>> -> [];
                _ -> [{<<Repo/binary, "#", N/binary>>, N} || [N] <- UMatches]
            end;
        nomatch -> []
    end,
    %% Deduplicate by full ref, return the full refs
    AllRefs = QualifiedRefs ++ UnqualifiedRefs,
    FullRefs = lists:usort([Full || {Full, _} <- AllRefs]),
    FullRefs.

%% Fetch an issue from GitHub API.
%% Ref format: "owner/repo#42"
fetch(FullRef, Config) ->
    case parse_ref(FullRef) of
        {ok, Owner, Repo, Number} ->
            fetch_from_api(Owner, Repo, Number, Config);
        error ->
            {error, {bad_ref, FullRef}}
    end.

%% Create an intent source from a GitHub webhook issue payload.
from_webhook(IssuePayload, Repository) ->
    Number = to_binary(maps:get(<<"number">>, IssuePayload, <<>>)),
    Repo = to_binary(Repository),
    FullRef = <<Repo/binary, "#", Number/binary>>,
    Id = <<"github:", FullRef/binary>>,
    Title = to_binary(maps:get(<<"title">>, IssuePayload, <<>>)),
    Body = maps:get(<<"body">>, IssuePayload, null),
    Author = case maps:get(<<"user">>, IssuePayload, #{}) of
        #{<<"login">> := Login} -> to_binary(Login);
        _ -> null
    end,
    Labels = [to_binary(maps:get(<<"name">>, L, <<>>))
              || L <- maps:get(<<"labels">>, IssuePayload, []),
                 is_map(L)],
    CreatedAt = to_binary(maps:get(<<"created_at">>, IssuePayload,
        ledger_util:now_iso8601())),
    UpdatedAt = to_binary(maps:get(<<"updated_at">>, IssuePayload, CreatedAt)),
    #{
        id => Id,
        source_type => <<"github">>,
        source_ref => FullRef,
        title => Title,
        body => Body,
        author => Author,
        labels => Labels,
        metadata => #{
            state => maps:get(<<"state">>, IssuePayload, null),
            html_url => maps:get(<<"html_url">>, IssuePayload, null)
        },
        created_at => CreatedAt,
        updated_at => UpdatedAt
    }.

%% Create an intent source from a pre-fetched issue map.
%% Useful for API responses or test fixtures.
from_issue_map(#{number := Number, title := Title} = Issue, Repository) ->
    Repo = to_binary(Repository),
    NumBin = to_binary(Number),
    FullRef = <<Repo/binary, "#", NumBin/binary>>,
    #{
        id => <<"github:", FullRef/binary>>,
        source_type => <<"github">>,
        source_ref => FullRef,
        title => to_binary(Title),
        body => maps:get(body, Issue, null),
        author => maps:get(author, Issue, null),
        labels => maps:get(labels, Issue, []),
        metadata => maps:with([state, html_url, milestone], Issue),
        created_at => maps:get(created_at, Issue, ledger_util:now_iso8601()),
        updated_at => maps:get(updated_at, Issue,
            maps:get(created_at, Issue, ledger_util:now_iso8601()))
    }.

%%% Internal

parse_ref(FullRef) ->
    case re:run(FullRef, "^([^/]+)/([^#]+)#([0-9]+)$",
                [{capture, all_but_first, binary}]) of
        {match, [Owner, Repo, Number]} -> {ok, Owner, Repo, Number};
        nomatch -> error
    end.

fetch_from_api(Owner, Repo, Number, Config) ->
    Token = maps:get(github_token, Config,
        to_binary(os:getenv("GITHUB_TOKEN", ""))),
    Url = iolist_to_binary([
        "https://api.github.com/repos/", Owner, "/", Repo, "/issues/", Number
    ]),
    case http_get(Url, Token) of
        {ok, 200, RespBody} ->
            case jsx:decode(RespBody, [return_maps]) of
                IssueData when is_map(IssueData) ->
                    {ok, from_webhook(IssueData, <<Owner/binary, "/", Repo/binary>>)};
                _ ->
                    {error, bad_response}
            end;
        {ok, 404, _} ->
            {error, not_found};
        {ok, Status, _} ->
            {error, {http_error, Status}};
        {error, _} = Err ->
            Err
    end.

http_get(Url, Token) ->
    Headers = [
        {"Accept", "application/vnd.github.v3+json"},
        {"User-Agent", "warrant/1.0"}
    ] ++ case Token of
        <<>> -> [];
        _ -> [{"Authorization", "Bearer " ++ binary_to_list(Token)}]
    end,
    case httpc:request(get,
        {binary_to_list(Url), Headers},
        [{timeout, 10000}],
        [{body_format, binary}]
    ) of
        {ok, {{_, Status, _}, _, Body}} ->
            {ok, Status, Body};
        {error, Reason} ->
            {error, Reason}
    end.

to_binary(V) when is_binary(V) -> V;
to_binary(V) when is_list(V) -> list_to_binary(V);
to_binary(V) when is_integer(V) -> integer_to_binary(V);
to_binary(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_binary(_) -> <<>>.
