-module(warrant_merge).

%% Merge-time warrant creation flow.
%%
%% Given a PR/merge event, this module:
%%   1. Extracts intent references from branch, commits, PR body
%%   2. Resolves each reference through the appropriate plugin
%%   3. Builds a MergeContext from the event metadata
%%   4. Creates the warrant (content-addressed)
%%
%% Entry points:
%%   from_pr/1          — from a PR merge event map
%%   from_merge_event/1 — from a webhook merge payload
%%   extract_all_refs/1 — just the reference extraction step

-export([from_pr/1, from_pr/2]).
-export([extract_all_refs/1, extract_all_refs/2]).
-export([resolve_intents/1, resolve_intents/2]).

%% Create a warrant from a PR merge event.
%%
%% Input map keys:
%%   branch         : binary  — source branch name
%%   commits        : [binary] — commit SHAs included in the merge
%%   commit_messages: [binary] — commit message subjects
%%   merge_commit   : binary | null — the merge commit SHA
%%   pr_number      : binary | null
%%   pr_url         : binary | null
%%   pr_title       : binary | null
%%   pr_body        : binary | null
%%   repository     : binary  — "owner/repo"
%%   target_branch  : binary  — "main"
%%   actor          : binary  — who merged
%%   reviewers      : [binary]
%%   approvals      : [binary]
%%   merged_at      : binary  — ISO 8601
%%
%% Returns {ok, Warrant} | {error, Reason}.
-spec from_pr(map()) -> {ok, map()} | {error, term()}.
from_pr(Event) ->
    from_pr(Event, #{}).

-spec from_pr(map(), map()) -> {ok, map()} | {error, term()}.
from_pr(Event, Opts) ->
    %% 1. Collect all text to search for references
    AllRefs = extract_all_refs(Event, Opts),

    %% 2. Resolve intent sources
    {ok, IntentSources} = resolve_intents(AllRefs, Opts),

    %% 3. Build merge context
    MergeCtx = build_merge_context(Event),

    %% 4. Derive summary
    Summary = derive_summary(Event, IntentSources),

    %% 5. Create warrant
    CreateOpts = maps:with([org_id, project_id, metadata], Opts),
    warrant_object:create(IntentSources, MergeCtx, Summary, CreateOpts).

%% Extract all intent references from a merge event.
%% Returns [{SourceType, SourceRef}].
-spec extract_all_refs(map()) -> [{binary(), binary()}].
extract_all_refs(Event) ->
    extract_all_refs(Event, #{}).

-spec extract_all_refs(map(), map()) -> [{binary(), binary()}].
extract_all_refs(Event, Opts) ->
    %% Gather text from all relevant fields
    Texts = [
        maps:get(branch, Event, <<>>),
        maps:get(pr_title, Event, <<>>),
        maps:get(pr_body, Event, <<>>)
        | maps:get(commit_messages, Event, [])
    ],
    %% Join for extraction (plugins do their own regex)
    Combined = iolist_to_binary(lists:join(<<" ">>, [T || T <- Texts, T =/= null])),

    %% Pass repository context so plugins can resolve unqualified refs
    Config = #{repository => maps:get(repository, Event, <<>>)},
    MergedConfig = maps:merge(Config, Opts),

    %% Extract through all plugins
    AllRefs = warrant_intent:extract_refs(Combined, MergedConfig),

    %% Deduplicate
    lists:usort(AllRefs).

%% Resolve a list of {SourceType, SourceRef} pairs into intent sources.
%% Skips refs that can't be resolved (logs warning instead of failing).
-spec resolve_intents([{binary(), binary()}]) -> {ok, [map()]}.
resolve_intents(Refs) ->
    resolve_intents(Refs, #{}).

-spec resolve_intents([{binary(), binary()}], map()) -> {ok, [map()]}.
resolve_intents(Refs, _Config) ->
    Results = lists:filtermap(fun({SourceType, SourceRef}) ->
        case warrant_intent:fetch(SourceType, SourceRef) of
            {ok, IntentSource} ->
                {true, IntentSource};
            {error, Reason} ->
                logger:warning("Could not resolve intent ~s:~s — ~p",
                              [SourceType, SourceRef, Reason]),
                %% Create a minimal stub so the warrant still records the reference
                {true, #{
                    id => <<SourceType/binary, ":", SourceRef/binary>>,
                    source_type => SourceType,
                    source_ref => SourceRef,
                    title => <<"(unresolved)">>,
                    body => null,
                    author => null,
                    labels => [],
                    metadata => #{resolved => false},
                    created_at => ledger_util:now_iso8601(),
                    updated_at => ledger_util:now_iso8601()
                }}
        end
    end, Refs),
    {ok, Results}.

%%% Internal

build_merge_context(Event) ->
    #{
        commits => maps:get(commits, Event, []),
        merge_commit => maps:get(merge_commit, Event, null),
        pr_number => to_binary_or_null(maps:get(pr_number, Event, null)),
        pr_url => maps:get(pr_url, Event, null),
        pr_title => maps:get(pr_title, Event, null),
        repository => maps:get(repository, Event, <<>>),
        target_branch => maps:get(target_branch, Event, <<"main">>),
        actor => maps:get(actor, Event, <<"unknown">>),
        reviewers => maps:get(reviewers, Event, []),
        approvals => maps:get(approvals, Event, []),
        merged_at => maps:get(merged_at, Event, ledger_util:now_iso8601())
    }.

%% PR title if available, else first intent source title, else generic.
derive_summary(Event, IntentSources) ->
    case maps:get(pr_title, Event, null) of
        null ->
            case IntentSources of
                [#{title := T} | _] when T =/= <<>>, T =/= <<"(unresolved)">> -> T;
                _ -> <<"Merged change">>
            end;
        Title -> Title
    end.

to_binary_or_null(null) -> null;
to_binary_or_null(V) when is_binary(V) -> V;
to_binary_or_null(V) when is_integer(V) -> integer_to_binary(V);
to_binary_or_null(V) when is_list(V) -> list_to_binary(V);
to_binary_or_null(_) -> null.
