-module(warrant_object).

%% Warrant domain object — the first-class merge-time decision object.
%%
%% A warrant binds intent sources to merged code with authorization.
%% Its ID is the SHA-256 of its canonical content: same inputs → same ID.
%%
%% Create:   warrant_object:create(IntentSources, MergeContext, Summary)
%% Query:    warrant_object:get(WarrantId)
%%           warrant_object:for_commit(CommitSha)
%%           warrant_object:list(OrgId, ProjectId, Opts)

-export([create/3, create/4, get/1, for_commit/1, list/3]).

-type merge_context() :: #{
    commits       := [binary()],
    merge_commit  => binary() | null,
    pr_number     => binary() | null,
    pr_url        => binary() | null,
    pr_title      => binary() | null,
    repository    := binary(),
    target_branch := binary(),
    actor         := binary(),
    reviewers     => [binary()],
    approvals     => [binary()],
    merged_at     := binary()
}.

-type warrant() :: #{
    warrant_id        := binary(),
    summary           := binary(),
    intent_sources    := [map()],
    merge             := merge_context(),
    canonical_content := binary(),
    created_at        := binary(),
    org_id            => binary() | null,
    project_id        => binary() | null,
    metadata          => map()
}.

-export_type([merge_context/0, warrant/0]).

%% Create a warrant from resolved intent sources and merge context.
%% Returns {ok, Warrant} or {error, Reason}.
-spec create([map()], merge_context(), binary()) ->
    {ok, warrant()} | {error, term()}.
create(IntentSources, MergeCtx, Summary) ->
    create(IntentSources, MergeCtx, Summary, #{}).

-spec create([map()], merge_context(), binary(), map()) ->
    {ok, warrant()} | {error, term()}.
create(IntentSources, MergeCtx, Summary, Opts) ->
    %% Validate required merge context fields
    case validate_merge_context(MergeCtx) of
        {error, _} = ValErr -> ValErr;
        ok -> do_create(IntentSources, MergeCtx, Summary, Opts)
    end.

do_create(IntentSources, MergeCtx, Summary, Opts) ->
    %% Build the canonical content map
    IntentRefs = [intent_ref(IS) || IS <- IntentSources],
    MergeMap = merge_context_to_map(MergeCtx),
    CanonicalInput = #{
        intent_sources => IntentRefs,
        merge => MergeMap,
        summary => Summary
    },

    %% Compute content-addressed ID
    {WarrantId, CanonicalJson} = warrant_canonical:warrant_id(CanonicalInput),
    Now = ledger_util:now_iso8601(),
    OrgId = maps:get(org_id, Opts, null),
    ProjectId = maps:get(project_id, Opts, null),

    Warrant = #{
        warrant_id => WarrantId,
        summary => Summary,
        intent_sources => IntentSources,
        merge => MergeCtx,
        canonical_content => CanonicalJson,
        created_at => Now,
        org_id => OrgId,
        project_id => ProjectId,
        metadata => maps:get(metadata, Opts, #{})
    },

    %% Persist
    case persist_warrant(Warrant) of
        ok ->
            %% Persist intent source links
            lists:foreach(fun(IS) ->
                IntentId = maps:get(id, IS),
                %% Ensure intent source exists in DB
                warrant_intent:persist(IS),
                ledger_db:exec(
                    <<"INSERT OR IGNORE INTO warrant_intents
                       (warrant_id, intent_source_id) VALUES (?1, ?2)">>,
                    [WarrantId, IntentId])
            end, IntentSources),

            %% Persist commit links
            Commits = maps:get(commits, MergeCtx, []),
            lists:foreach(fun(Sha) ->
                ledger_db:exec(
                    <<"INSERT OR IGNORE INTO warrant_commits
                       (warrant_id, commit_sha) VALUES (?1, ?2)">>,
                    [WarrantId, Sha])
            end, Commits),

            %% Audit
            case {OrgId, ProjectId} of
                {null, _} -> ok;
                {_, null} -> ok;
                _ ->
                    ledger_audit_srv:log(OrgId, ProjectId, WarrantId,
                        <<"warrant.created">>, maps:get(actor, MergeCtx, <<"system">>),
                        #{summary => Summary,
                          intent_count => length(IntentSources),
                          commit_count => length(Commits)})
            end,

            {ok, Warrant};
        {error, _} = Err ->
            Err
    end.

%% Get a warrant by its content-addressed ID.
-spec get(binary()) -> {ok, warrant()} | {error, not_found}.
get(WarrantId) ->
    case ledger_db:one(
        <<"SELECT warrant_id, summary, canonical_content, merge_commit,
                  merge_actor, merged_at, pr_number, pr_url, pr_title,
                  repository, target_branch, reviewers, approvals,
                  metadata, created_at, org_id, project_id
           FROM warrants WHERE warrant_id = ?1">>, [WarrantId]
    ) of
        {ok, Row} ->
            {ok, row_to_warrant(Row)};
        {error, not_found} ->
            {error, not_found}
    end.

%% Find the warrant(s) that include a given commit.
-spec for_commit(binary()) -> {ok, [warrant()]}.
for_commit(CommitSha) ->
    Rows = ledger_db:q(
        <<"SELECT w.warrant_id, w.summary, w.canonical_content, w.merge_commit,
                  w.merge_actor, w.merged_at, w.pr_number, w.pr_url, w.pr_title,
                  w.repository, w.target_branch, w.reviewers, w.approvals,
                  w.metadata, w.created_at, w.org_id, w.project_id
           FROM warrants w
           JOIN warrant_commits wc ON wc.warrant_id = w.warrant_id
           WHERE wc.commit_sha = ?1">>, [CommitSha]),
    {ok, [row_to_warrant(R) || R <- Rows]}.

%% List warrants for an org/project.
-spec list(binary(), binary(), map()) -> {ok, [warrant()]}.
list(OrgId, ProjectId, Opts) ->
    Limit = maps:get(limit, Opts, 50),
    Offset = maps:get(offset, Opts, 0),
    Rows = ledger_db:q(
        <<"SELECT warrant_id, summary, canonical_content, merge_commit,
                  merge_actor, merged_at, pr_number, pr_url, pr_title,
                  repository, target_branch, reviewers, approvals,
                  metadata, created_at, org_id, project_id
           FROM warrants
           WHERE org_id = ?1 AND project_id = ?2
           ORDER BY created_at DESC
           LIMIT ?3 OFFSET ?4">>,
        [OrgId, ProjectId, Limit, Offset]),
    {ok, [row_to_warrant(R) || R <- Rows]}.

%%% Internal

validate_merge_context(#{actor := _, repository := _, target_branch := _,
                         merged_at := _, commits := Commits})
        when is_list(Commits) ->
    ok;
validate_merge_context(_) ->
    {error, {missing_fields, [actor, repository, target_branch, merged_at, commits]}}.

%% Extract only the fields used in canonical content from an intent source.
intent_ref(#{id := Id, source_type := Type, source_ref := Ref, title := Title}) ->
    #{id => Id, source_type => Type, source_ref => Ref, title => Title};
intent_ref(#{id := Id, source_type := Type, source_ref := Ref}) ->
    #{id => Id, source_type => Type, source_ref => Ref, title => <<>>}.

%% Convert merge context to the canonical map (only serializable fields).
merge_context_to_map(Ctx) ->
    Base = #{
        actor => maps:get(actor, Ctx),
        commits => lists:sort(maps:get(commits, Ctx, [])),
        merged_at => maps:get(merged_at, Ctx),
        repository => maps:get(repository, Ctx),
        target_branch => maps:get(target_branch, Ctx)
    },
    Optional = [
        {pr_number, maps:get(pr_number, Ctx, null)},
        {pr_title, maps:get(pr_title, Ctx, null)},
        {pr_url, maps:get(pr_url, Ctx, null)},
        {merge_commit, maps:get(merge_commit, Ctx, null)},
        {reviewers, lists:sort(maps:get(reviewers, Ctx, []))},
        {approvals, lists:sort(maps:get(approvals, Ctx, []))}
    ],
    lists:foldl(fun
        ({_K, null}, Acc) -> Acc;
        ({_K, []}, Acc) -> Acc;
        ({K, V}, Acc) -> Acc#{K => V}
    end, Base, Optional).

persist_warrant(#{warrant_id := WId, summary := Summary,
                  canonical_content := CanonicalJson, merge := Merge,
                  created_at := CreatedAt} = W) ->
    MergeCommit = maps:get(merge_commit, Merge, null),
    MergeActor = maps:get(actor, Merge, null),
    MergedAt = maps:get(merged_at, Merge, null),
    PrNumber = maps:get(pr_number, Merge, null),
    PrUrl = maps:get(pr_url, Merge, null),
    PrTitle = maps:get(pr_title, Merge, null),
    Repository = maps:get(repository, Merge, null),
    TargetBranch = maps:get(target_branch, Merge, null),
    Reviewers = case maps:get(reviewers, Merge, []) of
        [] -> null;
        R -> jsx:encode(R)
    end,
    Approvals = case maps:get(approvals, Merge, []) of
        [] -> null;
        A -> jsx:encode(A)
    end,
    Metadata = case maps:get(metadata, W, #{}) of
        M when map_size(M) =:= 0 -> null;
        M -> jsx:encode(M)
    end,
    OrgId = maps:get(org_id, W, null),
    ProjectId = maps:get(project_id, W, null),

    ledger_db:exec(
        <<"INSERT OR IGNORE INTO warrants
           (warrant_id, summary, canonical_content, merge_commit, merge_actor,
            merged_at, pr_number, pr_url, pr_title, repository, target_branch,
            reviewers, approvals, metadata, created_at, org_id, project_id)
           VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17)">>,
        [WId, Summary, CanonicalJson, MergeCommit, MergeActor, MergedAt,
         PrNumber, PrUrl, PrTitle, Repository, TargetBranch,
         Reviewers, Approvals, Metadata, CreatedAt, OrgId, ProjectId]).

row_to_warrant({WId, Summary, Canonical, MergeCommit, MergeActor, MergedAt,
                PrNumber, PrUrl, PrTitle, Repo, Branch,
                Reviewers, Approvals, Meta, CreatedAt, OrgId, ProjId}) ->
    #{
        warrant_id => WId,
        summary => Summary,
        canonical_content => Canonical,
        merge => #{
            merge_commit => MergeCommit,
            actor => MergeActor,
            merged_at => MergedAt,
            pr_number => PrNumber,
            pr_url => PrUrl,
            pr_title => PrTitle,
            repository => Repo,
            target_branch => Branch,
            reviewers => safe_decode(Reviewers, []),
            approvals => safe_decode(Approvals, [])
        },
        metadata => safe_decode(Meta, #{}),
        created_at => CreatedAt,
        org_id => OrgId,
        project_id => ProjId
    }.

safe_decode(null, Default) -> Default;
safe_decode(Bin, Default) when is_binary(Bin) ->
    try jsx:decode(Bin, [return_maps]) catch _:_ -> Default end;
safe_decode(_, Default) -> Default.
