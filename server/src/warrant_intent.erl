-module(warrant_intent).

%% Intent source behaviour and registry.
%%
%% An intent source is a pre-work artifact (task, issue, etc.) from an
%% external system. Plugins implement this behaviour to:
%%
%%   1. Extract references from text (branch names, commit messages, PR body)
%%   2. Fetch full intent source data given a reference
%%   3. Identify their source type
%%
%% The warrant system uses these plugins at merge time to resolve
%% what intent led to a change, without caring where the intent lives.

-export([extract_refs/2, fetch/2, persist/1, get/1]).
-export([plugins/0]).

%% A plugin must export these three functions.
-callback source_type() -> binary().
-callback extract_refs(Text :: binary(), Config :: map()) -> [binary()].
-callback fetch(SourceRef :: binary(), Config :: map()) -> {ok, map()} | {error, term()}.

-type intent_source() :: #{
    id          := binary(),   %% "backlog:HL-131", "github:owner/repo#42"
    source_type := binary(),   %% "backlog", "github"
    source_ref  := binary(),   %% "HL-131", "42"
    title       := binary(),
    body        => binary() | null,
    author      => binary() | null,
    labels      => [binary()],
    metadata    => map(),
    created_at  := binary(),
    updated_at  := binary()
}.
-export_type([intent_source/0]).

%% All registered intent plugins, in extraction priority order.
plugins() ->
    [warrant_intent_backlog, warrant_intent_github].

%% Extract intent references from text using all plugins.
%% Returns [{SourceType, Ref}] — e.g., [{<<"backlog">>, <<"HL-131">>}].
-spec extract_refs(binary(), map()) -> [{binary(), binary()}].
extract_refs(Text, Config) ->
    lists:flatmap(fun(Plugin) ->
        Type = Plugin:source_type(),
        Refs = Plugin:extract_refs(Text, Config),
        [{Type, Ref} || Ref <- Refs]
    end, plugins()).

%% Fetch an intent source from the appropriate plugin.
%% SourceType selects the plugin; SourceRef is passed to fetch/2.
-spec fetch(binary(), binary()) -> {ok, intent_source()} | {error, term()}.
fetch(SourceType, SourceRef) ->
    fetch(SourceType, SourceRef, #{}).

-spec fetch(binary(), binary(), map()) -> {ok, intent_source()} | {error, term()}.
fetch(SourceType, SourceRef, Config) ->
    case find_plugin(SourceType) of
        {ok, Plugin} -> Plugin:fetch(SourceRef, Config);
        error -> {error, {unknown_source_type, SourceType}}
    end.

%% Persist an intent source to the database (upsert).
-spec persist(intent_source()) -> ok | {error, term()}.
persist(#{id := Id, source_type := Type, source_ref := Ref} = Source) ->
    Title = maps:get(title, Source, <<>>),
    Body = maps:get(body, Source, null),
    Author = maps:get(author, Source, null),
    Labels = case maps:get(labels, Source, []) of
        L when is_list(L) -> jsx:encode(L);
        _ -> <<"[]">>
    end,
    Metadata = case maps:get(metadata, Source, #{}) of
        M when is_map(M) -> jsx:encode(M);
        _ -> <<"{}">>
    end,
    CreatedAt = maps:get(created_at, Source, ledger_util:now_iso8601()),
    UpdatedAt = maps:get(updated_at, Source, CreatedAt),
    OrgId = maps:get(org_id, Source, null),
    ProjectId = maps:get(project_id, Source, null),

    ledger_db:exec(
        <<"INSERT INTO intent_sources (id, source_type, source_ref, title, body,
           author, labels, metadata, created_at, updated_at, org_id, project_id)
           VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
           ON CONFLICT(id) DO UPDATE SET
           title = excluded.title, body = excluded.body, author = excluded.author,
           labels = excluded.labels, metadata = excluded.metadata,
           updated_at = excluded.updated_at">>,
        [Id, Type, Ref, Title, Body, Author, Labels, Metadata,
         CreatedAt, UpdatedAt, OrgId, ProjectId]).

%% Get an intent source from the database by ID.
-spec get(binary()) -> {ok, intent_source()} | {error, not_found}.
get(Id) ->
    case ledger_db:one(
        <<"SELECT id, source_type, source_ref, title, body, author,
                  labels, metadata, created_at, updated_at, org_id, project_id
           FROM intent_sources WHERE id = ?1">>, [Id]
    ) of
        {ok, {SId, SType, SRef, STitle, SBody, SAuthor,
              SLabels, SMeta, SCa, SUa, SOrgId, SProjId}} ->
            {ok, #{
                id => SId, source_type => SType, source_ref => SRef,
                title => STitle, body => SBody, author => SAuthor,
                labels => safe_decode(SLabels, []),
                metadata => safe_decode(SMeta, #{}),
                created_at => SCa, updated_at => SUa,
                org_id => SOrgId, project_id => SProjId
            }};
        {error, not_found} ->
            {error, not_found}
    end.

%%% Internal

find_plugin(SourceType) ->
    case lists:search(fun(P) -> P:source_type() =:= SourceType end, plugins()) of
        {value, Plugin} -> {ok, Plugin};
        false -> error
    end.

safe_decode(null, Default) -> Default;
safe_decode(Bin, Default) when is_binary(Bin) ->
    try jsx:decode(Bin, [return_maps]) catch _:_ -> Default end;
safe_decode(_, Default) -> Default.
