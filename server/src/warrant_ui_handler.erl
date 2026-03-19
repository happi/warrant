-module(warrant_ui_handler).
-behaviour(cowboy_handler).

%% Single Cowboy handler for all UI routes.
%% Dispatches by #{page => atom()} from route opts.

-export([init/2]).

init(Req0, #{page := Page} = State) ->
    User = authenticate_cookie(Req0),
    %% Handle login POST specially
    ActualPage = case {Page, cowboy_req:method(Req0)} of
        {login, <<"POST">>} -> login_post;
        _ -> Page
    end,
    try
        {ok, Req} = render(ActualPage, User, Req0),
        {ok, Req, State}
    catch
        throw:{redirect, Location} ->
            Req1 = cowboy_req:reply(302, #{<<"location">> => Location}, <<>>, Req0),
            {ok, Req1, State};
        Class:Reason:Stack ->
            logger:error("UI error ~p:~p ~p", [Class, Reason, Stack]),
            Body = warrant_html:page(<<"Error">>, nav_items(User),
                [<<"<div class=\"section\"><h1>Something went wrong</h1>",
                   "<p>">>, warrant_html:h(iolist_to_binary(io_lib:format("~p", [Reason]))),
                 <<"</p></div>">>]),
            warrant_html:html_reply(500, Body, Req0)
    end.

%%% Auth — read token from cookie

authenticate_cookie(Req) ->
    Cookies = cowboy_req:parse_cookies(Req),
    case lists:keyfind(<<"warrant_token">>, 1, Cookies) of
        {_, Token} ->
            case ledger_auth:authenticate_token(Token) of
                {ok, User} -> User;
                _ -> undefined
            end;
        false ->
            undefined
    end.

nav_items(undefined) ->
    [{<<"/login">>, <<"Login">>}];
nav_items(#{username := Username}) ->
    [{<<"/admin">>, <<"Admin">>},
     {<<"/logout">>, Username}].

%%% Page rendering

%% Home page
render(home, undefined, Req) ->
    Body = warrant_html:page(<<"Warrant">>, nav_items(undefined),
        [<<"<div class=\"landing\">
<h1>Every change needs a warrant.</h1>
<p>Traceability for teams that ship. Task tracking, audit trails, and compliance &mdash; built into your git workflow.</p>
<div class=\"cta\">">>,
         warrant_html:button(<<"Login">>, <<"onclick=\"location='/login'\"">>),
         warrant_html:button(<<"Learn More">>, <<"onclick=\"location='https://github.com/happi/warrant'\"">>, <<"secondary">>),
         <<"</div>
</div>">>]),
    warrant_html:html_reply(200, Body, Req);

render(home, User, Req) ->
    #{org_id := OrgId} = User,
    %% Get user's org
    {ok, {_, OrgName, OrgSlug, _}} = ledger_db:one(
        <<"SELECT id, name, slug, created_at FROM organizations WHERE id = ?1">>, [OrgId]),
    %% Get projects in user's org
    Projects = ledger_db:q(
        <<"SELECT id, name, slug, prefix, created_at FROM projects WHERE org_id = ?1 ORDER BY name">>,
        [OrgId]),
    %% Also get superadmin orgs if user is superadmin
    AllOrgs = case ledger_db:one(<<"SELECT is_superadmin FROM organizations WHERE id = ?1">>, [OrgId]) of
        {ok, {1}} ->
            ledger_db:q(<<"SELECT id, name, slug FROM organizations ORDER BY name">>, []);
        _ ->
            [{OrgId, OrgName, OrgSlug}]
    end,
    Body = warrant_html:page(<<"Dashboard">>, nav_items(User),
        [<<"<h1>Dashboard</h1>">>,
         render_org_projects(AllOrgs, OrgId, Projects, OrgSlug)]),
    warrant_html:html_reply(200, Body, Req);

%% Login page
render(login, _User, Req) ->
    Body = warrant_html:page(<<"Login">>, [{<<"/login">>, <<"Login">>}],
        [<<"<div class=\"section\" style=\"max-width:400px;margin:2rem auto\">
<h2>Login</h2>
<form method=\"POST\" action=\"/login\">">>,
         warrant_html:form_field(<<"API Token">>, <<"token">>, <<"password">>),
         <<"<p style=\"font-size:0.8rem;color:#64748b;margin-bottom:1rem\">
Enter your API token (starts with cl_)</p>">>,
         warrant_html:button(<<"Login">>, <<"type=\"submit\"">>),
         <<"</form>">>,
         case os:getenv("GOOGLE_CLIENT_ID") of
             false -> <<>>;
             _ ->
                 [<<"<hr style=\"margin:1.5rem 0\">
<a href=\"/auth/google\" class=\"btn btn-secondary\" style=\"width:100%;justify-content:center;text-decoration:none;display:inline-flex\">Login with Google</a>">>]
         end,
         <<"</div>">>]),
    warrant_html:html_reply(200, Body, Req);

%% Login POST handler
render(login_post, _User, Req0) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Params = cow_qs:parse_qs(Body),
    Token = proplists:get_value(<<"token">>, Params, <<>>),
    case ledger_auth:authenticate_token(Token) of
        {ok, _} ->
            Req2 = cowboy_req:set_resp_cookie(<<"warrant_token">>, Token, Req1,
                #{path => <<"/">>, http_only => true, same_site => lax,
                  max_age => 86400 * 30}),
            Req3 = cowboy_req:reply(302, #{<<"location">> => <<"/">>}, <<>>, Req2),
            {ok, Req3};
        {error, _} ->
            ErrorBody = warrant_html:page(<<"Login">>, [{<<"/login">>, <<"Login">>}],
                [warrant_html:flash(<<"error">>, <<"Invalid token">>),
                 <<"<div class=\"section\" style=\"max-width:400px;margin:2rem auto\">
<h2>Login</h2>
<form method=\"POST\" action=\"/login\">">>,
                 warrant_html:form_field(<<"API Token">>, <<"token">>, <<"password">>),
                 warrant_html:button(<<"Login">>, <<"type=\"submit\"">>),
                 <<"</form></div>">>]),
            warrant_html:html_reply(401, ErrorBody, Req1)
    end;

%% Logout
render(logout, _User, Req0) ->
    Req1 = cowboy_req:set_resp_cookie(<<"warrant_token">>, <<>>, Req0,
        #{path => <<"/">>, http_only => true, max_age => 0}),
    Req2 = cowboy_req:reply(302, #{<<"location">> => <<"/">>}, <<>>, Req1),
    {ok, Req2};

%% Kanban Board
render(board, User, Req) ->
    require_auth(User),
    Org = cowboy_req:binding(org, Req),
    Project = cowboy_req:binding(project, Req),
    {OrgId, ProjectId} = resolve_org_project(Org, Project),
    %% Get all tasks
    {ok, Tasks} = ledger_task_srv:list(OrgId, ProjectId, #{}),
    %% Group by status
    Columns = [
        {<<"open">>, <<"Open">>},
        {<<"in_progress">>, <<"In Progress">>},
        {<<"in_review">>, <<"In Review">>},
        {<<"done">>, <<"Done">>},
        {<<"blocked">>, <<"Blocked">>}
    ],
    Body = warrant_html:page(
        iolist_to_binary([<<"Board — ">>, Project]),
        nav_items(User),
        [warrant_html:breadcrumbs([
            {<<"/">>, <<"Home">>},
            {iolist_to_binary([<<"/admin/orgs/">>, Org]), Org},
            {iolist_to_binary([<<"/board/">>, Org, <<"/">>, Project]), Project}
         ]),
         <<"<div style=\"display:flex;justify-content:space-between;align-items:center;margin-bottom:1rem\">
<h1>">>, warrant_html:h(Project), <<" Board</h1>
<button class=\"btn btn-primary btn-sm\" onclick=\"document.getElementById('new-task-form').style.display='block'\">+ New Task</button>
</div>">>,
         render_new_task_form(Org, Project),
         <<"<div class=\"board\" id=\"board\">">>,
         [render_column(S, Label, Tasks, Org, Project) || {S, Label} <- Columns],
         <<"</div>">>]),
    warrant_html:html_reply(200, Body, Req);

%% Task Detail
render(task_detail, User, Req) ->
    require_auth(User),
    Org = cowboy_req:binding(org, Req),
    Project = cowboy_req:binding(project, Req),
    TaskId = cowboy_req:binding(task_id, Req),
    {OrgId, ProjectId} = resolve_org_project(Org, Project),
    case ledger_task_srv:get(OrgId, ProjectId, TaskId) of
        {ok, Task} ->
            {ok, Trace} = ledger_task_srv:get_trace(OrgId, ProjectId, TaskId),
            Body = warrant_html:page(
                iolist_to_binary([TaskId, <<" - ">>, maps:get(title, Task)]),
                nav_items(User),
                [warrant_html:breadcrumbs([
                    {<<"/">>, <<"Home">>},
                    {iolist_to_binary([<<"/board/">>, Org, <<"/">>, Project]), Project},
                    {iolist_to_binary([<<"/tasks/">>, Org, <<"/">>, Project, <<"/">>, TaskId]), TaskId}
                 ]),
                 render_task_detail(Task, Trace, Org, Project)]),
            warrant_html:html_reply(200, Body, Req);
        {error, not_found} ->
            not_found(User, Req)
    end;

%% Trace View
render(trace, User, Req) ->
    require_auth(User),
    Org = cowboy_req:binding(org, Req),
    Project = cowboy_req:binding(project, Req),
    TaskId = cowboy_req:binding(task_id, Req),
    {OrgId, ProjectId} = resolve_org_project(Org, Project),
    case ledger_task_srv:get_trace(OrgId, ProjectId, TaskId) of
        {ok, #{task := Task, links := Links, audit := Audit}} ->
            Body = warrant_html:page(
                iolist_to_binary([<<"Trace — ">>, TaskId]),
                nav_items(User),
                [warrant_html:breadcrumbs([
                    {<<"/">>, <<"Home">>},
                    {iolist_to_binary([<<"/board/">>, Org, <<"/">>, Project]), Project},
                    {iolist_to_binary([<<"/tasks/">>, Org, <<"/">>, Project, <<"/">>, TaskId]), TaskId},
                    {iolist_to_binary([<<"/trace/">>, Org, <<"/">>, Project, <<"/">>, TaskId]), <<"Trace">>}
                 ]),
                 <<"<h1>Trace: ">>, warrant_html:h(TaskId), <<"</h1>">>,
                 render_trace_view(Task, Links, Audit)]),
            warrant_html:html_reply(200, Body, Req);
        {error, not_found} ->
            not_found(User, Req)
    end;

%% Admin — list orgs
render(admin, User, Req) ->
    require_auth(User),
    #{org_id := OrgId} = User,
    IsSuperadmin = case ledger_db:one(
        <<"SELECT is_superadmin FROM organizations WHERE id = ?1">>, [OrgId]) of
        {ok, {1}} -> true;
        _ -> false
    end,
    Orgs = case IsSuperadmin of
        true ->
            ledger_db:q(<<"SELECT id, name, slug, is_superadmin, created_at
                           FROM organizations ORDER BY name">>, []);
        false ->
            ledger_db:q(<<"SELECT id, name, slug, is_superadmin, created_at
                           FROM organizations WHERE id = ?1">>, [OrgId])
    end,
    Body = warrant_html:page(<<"Admin">>, nav_items(User),
        [<<"<h1>Administration</h1>">>,
         case IsSuperadmin of
             true ->
                 [<<"<div class=\"section\">
<h2>Organizations</h2>">>,
                  warrant_html:table(
                      [<<"Name">>, <<"Slug">>, <<"Superadmin">>, <<"Created">>, <<>>],
                      [[
                          [<<"<a href=\"/admin/orgs/">>, warrant_html:h(Slug), <<"\">">>,
                           warrant_html:h(Name), <<"</a>">>],
                          warrant_html:h(Slug),
                          case SA of 1 -> <<"Yes">>; _ -> <<>> end,
                          warrant_html:h(Ca),
                          [<<"<a href=\"/admin/orgs/">>, warrant_html:h(Slug), <<"\">Manage</a>">>]
                      ] || {_Id, Name, Slug, SA, Ca} <- Orgs]),
                  <<"<div class=\"inline-form\" id=\"create-org-form\">
<h3>Create Organization</h3>
<form hx-post=\"/api/v1/orgs\" hx-target=\"body\" hx-swap=\"outerHTML\"
      hx-headers='{\"Authorization\":\"Bearer ">>, get_cookie_token(Req), <<"\",\"Content-Type\":\"application/json\"}'
      hx-ext=\"json-enc\">">>,
                  warrant_html:form_field(<<"Name">>, <<"name">>, <<"text">>),
                  warrant_html:form_field(<<"Slug">>, <<"slug">>, <<"text">>),
                  warrant_html:button(<<"Create Organization">>, <<"type=\"submit\"">>),
                  <<"</form></div></div>">>];
             false ->
                 [<<"<div class=\"section\">
<h2>Your Organization</h2>">>,
                  [[<<"<a href=\"/admin/orgs/">>, warrant_html:h(Slug),
                    <<"\" class=\"project-card\" style=\"display:block;margin-bottom:0.5rem\">
<h3>">>, warrant_html:h(Name), <<"</h3>
<span class=\"prefix\">">>, warrant_html:h(Slug), <<"</span>
</a>">>] || {_Id, Name, Slug, _, _} <- Orgs],
                  <<"</div>">>]
         end]),
    warrant_html:html_reply(200, Body, Req);

%% Admin Org Detail
render(admin_org, User, Req) ->
    require_auth(User),
    OrgSlug = cowboy_req:binding(org_slug, Req),
    check_org_access(User, OrgSlug),
    case ledger_db:one(
        <<"SELECT id, name, slug, created_at FROM organizations WHERE slug = ?1">>,
        [OrgSlug]) of
        {ok, {OrgId, OrgName, _, Ca}} ->
            Projects = ledger_db:q(
                <<"SELECT id, name, slug, prefix, created_at FROM projects WHERE org_id = ?1 ORDER BY name">>,
                [OrgId]),
            Users = ledger_db:q(
                <<"SELECT id, username, role, email, auth_provider, created_at
                   FROM users WHERE org_id = ?1 ORDER BY username">>,
                [OrgId]),
            Body = warrant_html:page(
                iolist_to_binary([OrgName, <<" — Admin">>]),
                nav_items(User),
                [warrant_html:breadcrumbs([
                    {<<"/admin">>, <<"Admin">>},
                    {iolist_to_binary([<<"/admin/orgs/">>, OrgSlug]), OrgName}
                 ]),
                 <<"<h1>">>, warrant_html:h(OrgName), <<"</h1>
<p style=\"color:#64748b;margin-bottom:1.5rem\">Created: ">>, warrant_html:h(Ca), <<"</p>">>,

                 %% Projects section
                 <<"<div class=\"section\">
<h2>Projects</h2>">>,
                 case Projects of
                     [] -> <<"<p class=\"empty\">No projects yet.</p>">>;
                     _ ->
                         warrant_html:table(
                             [<<"Name">>, <<"Slug">>, <<"Prefix">>, <<"Created">>, <<>>],
                             [[
                                 warrant_html:h(N),
                                 warrant_html:h(S),
                                 [<<"<code>">>, warrant_html:h(string:uppercase(P)), <<"</code>">>],
                                 warrant_html:h(PCa),
                                 [<<"<a href=\"/board/">>, warrant_html:h(OrgSlug), <<"/">>,
                                  warrant_html:h(S), <<"\">Board</a> | ">>,
                                  <<"<a href=\"/admin/orgs/">>, warrant_html:h(OrgSlug),
                                  <<"/projects/">>, warrant_html:h(S), <<"\">Settings</a>">>]
                             ] || {_PId, N, S, P, PCa} <- Projects])
                 end,
                 <<"<div class=\"inline-form\">
<h3>Create Project</h3>
<form method=\"POST\" action=\"/admin/orgs/">>, warrant_html:h(OrgSlug), <<"/projects/create\">">>,
                 warrant_html:form_field(<<"Name">>, <<"name">>, <<"text">>),
                 warrant_html:form_field(<<"Slug">>, <<"slug">>, <<"text">>),
                 warrant_html:form_field(<<"Prefix">>, <<"prefix">>, <<"text">>),
                 warrant_html:button(<<"Create Project">>, <<"type=\"submit\"">>),
                 <<"</form></div></div>">>,

                 %% Users section
                 <<"<div class=\"section\">
<h2>Users</h2>">>,
                 case Users of
                     [] -> <<"<p class=\"empty\">No users.</p>">>;
                     _ ->
                         warrant_html:table(
                             [<<"Username">>, <<"Role">>, <<"Email">>, <<"Auth">>, <<"Created">>, <<>>],
                             [[
                                 warrant_html:h(UName),
                                 warrant_html:h(URole),
                                 case UEmail of null -> <<"-">>; _ -> warrant_html:h(UEmail) end,
                                 warrant_html:h(UAuth),
                                 warrant_html:h(UCa),
                                 [<<"<form method=\"POST\" action=\"/admin/orgs/">>,
                                  warrant_html:h(OrgSlug), <<"/users/">>,
                                  warrant_html:h(UName), <<"/token\" style=\"display:inline\">">>,
                                  <<"<button class=\"btn btn-sm btn-secondary\" type=\"submit\"",
                                    " onclick=\"return confirm('Regenerate token for ">>,
                                  warrant_html:h(UName), <<"?')\">Regen Token</button></form>">>]
                             ] || {_UId, UName, URole, UEmail, UAuth, UCa} <- Users])
                 end,
                 <<"<div class=\"inline-form\">
<h3>Create User</h3>
<form method=\"POST\" action=\"/admin/orgs/">>, warrant_html:h(OrgSlug), <<"/users/create\">">>,
                 warrant_html:form_field(<<"Username">>, <<"username">>, <<"text">>),
                 <<"<div class=\"field\">
<label for=\"role\">Role</label>
<select id=\"role\" name=\"role\">
<option value=\"developer\">Developer</option>
<option value=\"admin\">Admin</option>
</select></div>">>,
                 warrant_html:form_field(<<"Email (optional)">>, <<"email">>, <<"email">>),
                 warrant_html:button(<<"Create User">>, <<"type=\"submit\"">>),
                 <<"</form></div></div>">>]),
            warrant_html:html_reply(200, Body, Req);
        {error, not_found} ->
            not_found(User, Req)
    end;

%% Admin Users — token regen POST
render(admin_users, User, Req0) ->
    require_auth(User),
    OrgSlug = cowboy_req:binding(org_slug, Req0),
    check_org_access(User, OrgSlug),
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            %% This handles user creation and token regen
            throw({redirect, iolist_to_binary([<<"/admin/orgs/">>, OrgSlug])});
        _ ->
            throw({redirect, iolist_to_binary([<<"/admin/orgs/">>, OrgSlug])})
    end;

%% Admin Project Detail
render(admin_project, User, Req) ->
    require_auth(User),
    OrgSlug = cowboy_req:binding(org_slug, Req),
    ProjectSlug = cowboy_req:binding(project_slug, Req),
    check_org_access(User, OrgSlug),
    case resolve_org_project(OrgSlug, ProjectSlug) of
        {OrgId, ProjectId} ->
            {ok, {_, PName, _, Prefix, PCa}} = ledger_db:one(
                <<"SELECT id, name, slug, prefix, created_at FROM projects WHERE id = ?1">>,
                [ProjectId]),
            %% Get task counts by status
            Counts = ledger_db:q(
                <<"SELECT status, COUNT(*) FROM tasks WHERE org_id = ?1 AND project_id = ?2 GROUP BY status">>,
                [OrgId, ProjectId]),
            %% Get webhook config if exists
            WebhookConfig = case ledger_db:one(
                <<"SELECT id, provider, repo_url, created_at FROM webhook_configs
                   WHERE org_id = ?1 AND project_id = ?2">>,
                [OrgId, ProjectId]) of
                {ok, Row} -> {ok, Row};
                {error, not_found} -> none
            end,
            Body = warrant_html:page(
                iolist_to_binary([PName, <<" — Settings">>]),
                nav_items(User),
                [warrant_html:breadcrumbs([
                    {<<"/admin">>, <<"Admin">>},
                    {iolist_to_binary([<<"/admin/orgs/">>, OrgSlug]), OrgSlug},
                    {iolist_to_binary([<<"/admin/orgs/">>, OrgSlug, <<"/projects/">>, ProjectSlug]), PName}
                 ]),
                 <<"<h1>">>, warrant_html:h(PName), <<"</h1>">>,

                 <<"<div class=\"section\">
<h2>Project Info</h2>
<div class=\"detail-grid\">
<span class=\"detail-label\">Prefix</span><span><code>">>, warrant_html:h(string:uppercase(Prefix)), <<"</code></span>
<span class=\"detail-label\">Created</span><span>">>, warrant_html:h(PCa), <<"</span>
</div>
</div>">>,

                 <<"<div class=\"section\">
<h2>Task Summary</h2>">>,
                 case Counts of
                     [] -> <<"<p class=\"empty\">No tasks yet.</p>">>;
                     _ ->
                         warrant_html:table(
                             [<<"Status">>, <<"Count">>],
                             [[warrant_html:badge(S), warrant_html:h(C)] || {S, C} <- Counts])
                 end,
                 <<"<p style=\"margin-top:1rem\"><a href=\"/board/">>,
                 warrant_html:h(OrgSlug), <<"/">>, warrant_html:h(ProjectSlug),
                 <<"\">Open Board</a></p></div>">>,

                 %% Webhook section
                 <<"<div class=\"section\">
<h2>GitHub Webhook</h2>">>,
                 case WebhookConfig of
                     none ->
                         [<<"<p>No webhook configured.</p>
<form method=\"POST\" action=\"/admin/orgs/">>, warrant_html:h(OrgSlug),
                          <<"/projects/">>, warrant_html:h(ProjectSlug), <<"/webhook\">">>,
                          warrant_html:form_field(<<"Repository URL">>, <<"repo_url">>, <<"text">>),
                          warrant_html:button(<<"Setup Webhook">>, <<"type=\"submit\"">>),
                          <<"</form>">>];
                     {ok, {_WId, WProvider, WRepo, WCa}} ->
                         [<<"<div class=\"detail-grid\">
<span class=\"detail-label\">Provider</span><span>">>, warrant_html:h(WProvider), <<"</span>
<span class=\"detail-label\">Repository</span><span>">>, warrant_html:h(WRepo), <<"</span>
<span class=\"detail-label\">Webhook URL</span>
<span class=\"token-display\">/webhooks/github</span>
<span class=\"detail-label\">Created</span><span>">>, warrant_html:h(WCa), <<"</span>
</div>">>]
                 end,
                 <<"</div>">>]),
            warrant_html:html_reply(200, Body, Req);
        error ->
            not_found(User, Req)
    end;

%% Form action handlers
render(create_project_action, User, Req0) ->
    require_auth(User),
    OrgSlug = cowboy_req:binding(org_slug, Req0),
    check_org_access(User, OrgSlug),
    {ok, FormBody, _Req1} = cowboy_req:read_body(Req0),
    Params = cow_qs:parse_qs(FormBody),
    Name = proplists:get_value(<<"name">>, Params, <<>>),
    Slug = proplists:get_value(<<"slug">>, Params, <<>>),
    Prefix = proplists:get_value(<<"prefix">>, Params, <<>>),
    case resolve_org(OrgSlug) of
        {ok, OrgId} ->
            Id = ledger_util:uuid(),
            Now = ledger_util:now_iso8601(),
            ledger_db:exec(
                <<"INSERT INTO projects (id, org_id, name, slug, prefix, created_at)
                   VALUES (?1, ?2, ?3, ?4, ?5, ?6)">>,
                [Id, OrgId, Name, Slug, string:lowercase(Prefix), Now]),
            throw({redirect, iolist_to_binary([<<"/admin/orgs/">>, OrgSlug])});
        _ ->
            throw({redirect, <<"/admin">>})
    end;

render(create_user_action, User, Req0) ->
    require_auth(User),
    OrgSlug = cowboy_req:binding(org_slug, Req0),
    check_org_access(User, OrgSlug),
    {ok, FormBody, _Req1} = cowboy_req:read_body(Req0),
    Params = cow_qs:parse_qs(FormBody),
    Username = proplists:get_value(<<"username">>, Params, <<>>),
    Role = proplists:get_value(<<"role">>, Params, <<"developer">>),
    Email = case proplists:get_value(<<"email">>, Params, <<>>) of
        <<>> -> null;
        E -> E
    end,
    case resolve_org(OrgSlug) of
        {ok, OrgId} ->
            Id = ledger_util:uuid(),
            {RawToken, TokenHash} = ledger_auth:generate_token(),
            Now = ledger_util:now_iso8601(),
            ledger_db:exec(
                <<"INSERT INTO users (id, org_id, username, role, email, auth_provider, api_token_hash, created_at)
                   VALUES (?1, ?2, ?3, ?4, ?5, 'token', ?6, ?7)">>,
                [Id, OrgId, Username, Role, Email, TokenHash, Now]),
            %% Show token flash — redirect with token in query param
            throw({redirect, iolist_to_binary([<<"/admin/orgs/">>, OrgSlug,
                <<"?flash=User created. Token: ">>, RawToken])});
        _ ->
            throw({redirect, <<"/admin">>})
    end;

render(regen_token_action, User, Req0) ->
    require_auth(User),
    OrgSlug = cowboy_req:binding(org_slug, Req0),
    Username = cowboy_req:binding(username, Req0),
    check_org_access(User, OrgSlug),
    case resolve_org(OrgSlug) of
        {ok, OrgId} ->
            {RawToken, NewHash} = ledger_auth:generate_token(),
            ledger_db:exec(
                <<"UPDATE users SET api_token_hash = ?1 WHERE org_id = ?2 AND username = ?3">>,
                [NewHash, OrgId, Username]),
            throw({redirect, iolist_to_binary([<<"/admin/orgs/">>, OrgSlug,
                <<"?flash=New token for ">>, Username, <<": ">>, RawToken])});
        _ ->
            throw({redirect, <<"/admin">>})
    end;

%% Create task from board form
render(create_task_action, User, Req0) ->
    require_auth(User),
    Org = cowboy_req:binding(org, Req0),
    Project = cowboy_req:binding(project, Req0),
    {ok, FormBody, _Req1} = cowboy_req:read_body(Req0),
    Params = cow_qs:parse_qs(FormBody),
    Title = proplists:get_value(<<"title">>, Params, <<>>),
    Intent = case proplists:get_value(<<"intent">>, Params, <<>>) of
        <<>> -> null;
        I -> I
    end,
    Priority = case proplists:get_value(<<"priority">>, Params, <<>>) of
        <<>> -> null;
        P -> P
    end,
    LabelsStr = proplists:get_value(<<"labels">>, Params, <<>>),
    Labels = case LabelsStr of
        <<>> -> [];
        _ -> [string:trim(L) || L <- binary:split(LabelsStr, <<",">>, [global]), L =/= <<>>]
    end,
    case resolve_org_project(Org, Project) of
        {OrgId, ProjectId} ->
            Actor = maps:get(username, User, <<"ui">>),
            ledger_task_srv:create(OrgId, ProjectId,
                #{title => Title, intent => Intent, priority => Priority, labels => Labels},
                Actor),
            throw({redirect, iolist_to_binary([<<"/board/">>, Org, <<"/">>, Project])});
        error ->
            throw({redirect, <<"/">>})
    end;

%% Status transition from task detail form
render(task_status_action, User, Req0) ->
    require_auth(User),
    Org = cowboy_req:binding(org, Req0),
    Project = cowboy_req:binding(project, Req0),
    TaskId = cowboy_req:binding(task_id, Req0),
    {ok, FormBody, _Req1} = cowboy_req:read_body(Req0),
    Params = cow_qs:parse_qs(FormBody),
    NewStatus = proplists:get_value(<<"status">>, Params, <<>>),
    ExpectedStatus = proplists:get_value(<<"expected_status">>, Params, <<>>),
    case resolve_org_project(Org, Project) of
        {OrgId, ProjectId} ->
            ledger_task_srv:update_status(OrgId, ProjectId, TaskId, NewStatus, ExpectedStatus),
            throw({redirect, iolist_to_binary([<<"/tasks/">>, Org, <<"/">>, Project, <<"/">>, TaskId])});
        error ->
            throw({redirect, <<"/">>})
    end;

render(setup_webhook_action, User, Req0) ->
    require_auth(User),
    OrgSlug = cowboy_req:binding(org_slug, Req0),
    ProjectSlug = cowboy_req:binding(project_slug, Req0),
    check_org_access(User, OrgSlug),
    {ok, FormBody, _Req1} = cowboy_req:read_body(Req0),
    Params = cow_qs:parse_qs(FormBody),
    RepoUrl = proplists:get_value(<<"repo_url">>, Params, <<>>),
    case resolve_org_project(OrgSlug, ProjectSlug) of
        {OrgId, ProjectId} ->
            Id = ledger_util:uuid(),
            Secret = binary:encode_hex(crypto:strong_rand_bytes(32)),
            Now = ledger_util:now_iso8601(),
            ledger_db:exec(
                <<"INSERT OR REPLACE INTO webhook_configs (id, org_id, project_id, provider, repo_url, webhook_secret, created_at)
                   VALUES (?1, ?2, ?3, 'github', ?4, ?5, ?6)">>,
                [Id, OrgId, ProjectId, RepoUrl, Secret, Now]),
            throw({redirect, iolist_to_binary([<<"/admin/orgs/">>, OrgSlug,
                <<"/projects/">>, ProjectSlug,
                <<"?flash=Webhook configured. Secret: ">>, Secret])});
        error ->
            throw({redirect, iolist_to_binary([<<"/admin/orgs/">>, OrgSlug])})
    end;

render(Page, User, Req) ->
    logger:warning("Unknown UI page: ~p", [Page]),
    not_found(User, Req).

%%% Rendering helpers

render_org_projects(AllOrgs, _UserOrgId, _DirectProjects, _UserOrgSlug) ->
    lists:map(fun({OrgId, OrgName, OrgSlug}) ->
        Projects = ledger_db:q(
            <<"SELECT id, name, slug, prefix FROM projects WHERE org_id = ?1 ORDER BY name">>,
            [OrgId]),
        [<<"<div class=\"section\">
<h2>">>, warrant_html:h(OrgName), <<"</h2>
<div class=\"grid grid-3\">">>,
         case Projects of
             [] -> [<<"<p class=\"empty\">No projects. <a href=\"/admin/orgs/">>,
                    warrant_html:h(OrgSlug), <<"\">Create one</a></p>">>];
             _ ->
                 [[<<"<a href=\"/board/">>, warrant_html:h(OrgSlug), <<"/">>,
                   warrant_html:h(S), <<"\" class=\"project-card\">
<h3>">>, warrant_html:h(N), <<"</h3>
<span class=\"prefix\">">>, warrant_html:h(string:uppercase(P)), <<"</span>
</a>">>] || {_, N, S, P} <- Projects]
         end,
         <<"</div></div>">>]
    end, AllOrgs).

render_column(Status, Label, Tasks, Org, Project) ->
    Filtered = [T || #{status := S} = T <- Tasks, S =:= Status],
    Count = length(Filtered),
    [<<"<div class=\"column\">
<div class=\"column-header\">">>,
     warrant_html:h(Label),
     <<"<span class=\"column-count\">">>, integer_to_binary(Count), <<"</span>
</div>">>,
     [warrant_html:card(T#{org => Org, project => Project}) || T <- Filtered],
     <<"</div>">>].

render_new_task_form(Org, Project) ->
    [<<"<div id=\"new-task-form\" class=\"section\" style=\"display:none;margin-bottom:1rem\">
<h3>New Task</h3>
<form method=\"POST\" action=\"/board/">>, warrant_html:h(Org), <<"/">>,
     warrant_html:h(Project), <<"/tasks\">">>,
     warrant_html:form_field(<<"Title">>, <<"title">>, <<"text">>),
     <<"<div class=\"field\">
<label for=\"intent\">Intent</label>
<textarea id=\"intent\" name=\"intent\" placeholder=\"Why does this task matter?\"></textarea>
</div>
<div class=\"field\">
<label for=\"priority\">Priority</label>
<select id=\"priority\" name=\"priority\">
<option value=\"medium\">Medium</option>
<option value=\"low\">Low</option>
<option value=\"high\">High</option>
<option value=\"critical\">Critical</option>
</select></div>">>,
     warrant_html:form_field(<<"Labels (comma-separated)">>, <<"labels">>, <<"text">>),
     warrant_html:button(<<"Create Task">>, <<"type=\"submit\"">>),
     <<"  ">>,
     warrant_html:button(<<"Cancel">>, <<"type=\"button\" onclick=\"this.closest('#new-task-form').style.display='none'\"">>, <<"secondary">>),
     <<"</form></div>">>].

render_task_detail(Task, Trace, Org, Project) ->
    #{id := Id, title := Title, status := Status, priority := Priority,
      intent := Intent, created_by := CreatedBy, assigned_to := AssignedTo,
      created_at := CreatedAt, updated_at := UpdatedAt} = Task,
    Labels = maps:get(labels, Task, []),
    Lease = maps:get(lease, Task, null),
    Links = maps:get(links, Trace, #{}),
    Audit = maps:get(audit, Trace, []),

    [<<"<div style=\"display:flex;gap:1.5rem;align-items:flex-start\">
<div style=\"flex:1\">">>,

     %% Main detail
     <<"<div class=\"section\">
<div style=\"display:flex;justify-content:space-between;align-items:center;margin-bottom:1rem\">
<h1>">>, warrant_html:h(Id), <<": ">>, warrant_html:h(Title), <<"</h1>">>,
     warrant_html:badge(Status),
     <<"</div>

<div class=\"detail-grid\">
<span class=\"detail-label\">Priority</span><span>">>, warrant_html:priority_badge(Priority), <<"</span>
<span class=\"detail-label\">Created by</span><span>">>, warrant_html:h(CreatedBy), <<"</span>
<span class=\"detail-label\">Assigned to</span><span>">>,
     case AssignedTo of null -> <<"-">>; undefined -> <<"-">>; _ -> warrant_html:h(AssignedTo) end,
     <<"</span>
<span class=\"detail-label\">Labels</span><span>">>,
     case Labels of
         [] -> <<"-">>;
         _ -> [[<<"<span class=\"label\">">>, warrant_html:h(L), <<"</span>">>] || L <- Labels]
     end,
     <<"</span>
<span class=\"detail-label\">Created</span><span>">>, warrant_html:h(CreatedAt), <<"</span>
<span class=\"detail-label\">Updated</span><span>">>, warrant_html:h(UpdatedAt), <<"</span>
</div>">>,

     %% Intent
     case Intent of
         null -> <<>>;
         undefined -> <<>>;
         _ -> [<<"<h3 style=\"margin-top:1.5rem\">Intent</h3><p>">>, warrant_html:h(Intent), <<"</p>">>]
     end,

     %% Status transition buttons
     <<"<div style=\"margin-top:1.5rem\">">>,
     [begin
          [<<"<form method=\"POST\" action=\"/tasks/">>,
           warrant_html:h(Org), <<"/">>, warrant_html:h(Project), <<"/">>,
           warrant_html:h(Id), <<"/status\" style=\"display:inline;margin-right:0.5rem\">
<input type=\"hidden\" name=\"status\" value=\"">>, warrant_html:h(S), <<"\">
<input type=\"hidden\" name=\"expected_status\" value=\"">>, warrant_html:h(Status), <<"\">">>,
           warrant_html:button(iolist_to_binary([<<"Move to ">>, format_status_label(S)]),
                               <<"type=\"submit\"">>, <<"secondary">>),
           <<"</form>">>]
      end || S <- valid_next_statuses(Status)],
     <<"</div>
</div>">>,

     %% Lease
     case Lease of
         null -> <<>>;
         #{owner := LOwner, expires_at := LExp} ->
             [<<"<div class=\"section\">
<h2>Lease</h2>
<div class=\"detail-grid\">
<span class=\"detail-label\">Owner</span><span>">>, warrant_html:h(LOwner), <<"</span>
<span class=\"detail-label\">Expires</span><span>">>, warrant_html:h(LExp), <<"</span>
</div></div>">>]
     end,

     <<"</div>">>,  %% end left column

     %% Right sidebar
     <<"<div style=\"width:320px\">">>,

     %% Artifact links
     <<"<div class=\"section\">
<h2>Artifacts</h2>">>,
     render_link_group(<<"Branches">>, maps:get(branches, Links, [])),
     render_link_group(<<"Commits">>, maps:get(commits, Links, [])),
     render_link_group(<<"Pull Requests">>, maps:get(prs, Links, [])),
     <<"<p style=\"margin-top:0.75rem\"><a href=\"/trace/">>,
     warrant_html:h(Org), <<"/">>, warrant_html:h(Project), <<"/">>,
     warrant_html:h(Id), <<"\">Full Trace</a></p>
</div>">>,

     %% Audit timeline
     <<"<div class=\"section\">
<h2>Audit Trail</h2>
<div class=\"timeline\">">>,
     [render_audit_event(E) || E <- lists:sublist(Audit, 20)],
     <<"</div></div>">>,

     <<"</div></div>">>].  %% end sidebar, end flex

render_trace_view(Task, Links, Audit) ->
    #{id := Id, title := Title, status := Status, priority := Priority,
      intent := Intent} = Task,
    [<<"<div class=\"section\">
<h2>Task</h2>
<div class=\"detail-grid\">
<span class=\"detail-label\">ID</span><span>">>, warrant_html:h(Id), <<"</span>
<span class=\"detail-label\">Title</span><span>">>, warrant_html:h(Title), <<"</span>
<span class=\"detail-label\">Status</span><span>">>, warrant_html:badge(Status), <<"</span>
<span class=\"detail-label\">Priority</span><span>">>, warrant_html:priority_badge(Priority), <<"</span>
<span class=\"detail-label\">Intent</span><span>">>,
     case Intent of null -> <<"-">>; _ -> warrant_html:h(Intent) end,
     <<"</span>
</div></div>">>,

     <<"<div class=\"section\">
<h2>Artifact Links</h2>">>,
     render_link_group(<<"Branches">>, maps:get(branches, Links, [])),
     render_link_group(<<"Commits">>, maps:get(commits, Links, [])),
     render_link_group(<<"Pull Requests">>, maps:get(prs, Links, [])),
     <<"</div>">>,

     <<"<div class=\"section\">
<h2>Full Audit Timeline</h2>
<div class=\"timeline\">">>,
     [render_audit_event(E) || E <- Audit],
     <<"</div></div>">>].

render_link_group(_Label, []) -> <<>>;
render_link_group(Label, Items) ->
    [<<"<h3 style=\"font-size:0.875rem;margin:0.75rem 0 0.375rem\">">>,
     warrant_html:h(Label), <<"</h3><ul style=\"list-style:none;font-size:0.875rem\">">>,
     lists:map(fun
         (#{ref := Ref, url := Url}) when Url =/= null ->
             [<<"<li><a href=\"">>, warrant_html:h(Url), <<"\">">>,
              warrant_html:h(Ref), <<"</a></li>">>];
         (#{ref := Ref}) ->
             [<<"<li><code>">>, warrant_html:h(Ref), <<"</code></li>">>];
         (Ref) when is_binary(Ref) ->
             [<<"<li><code>">>, warrant_html:h(Ref), <<"</code></li>">>]
     end, Items),
     <<"</ul>">>].

render_audit_event(#{event_type := Type, actor := Actor,
                     timestamp := Time} = E) ->
    Detail = maps:get(detail, E, null),
    DetailText = case Detail of
        null -> <<>>;
        D when is_binary(D) -> D;
        D when is_map(D) ->
            iolist_to_binary(io_lib:format("~p", [D]));
        _ -> <<>>
    end,
    [<<"<div class=\"timeline-item\">
<div class=\"timeline-time\">">>, warrant_html:h(Time), <<"</div>
<div class=\"timeline-text\"><strong>">>, warrant_html:h(Type),
     <<"</strong> by ">>, warrant_html:h(Actor),
     case DetailText of
         <<>> -> <<>>;
         _ -> [<<" - ">>, warrant_html:h(DetailText)]
     end,
     <<"</div></div>">>].

valid_next_statuses(<<"open">>) -> [<<"in_progress">>, <<"blocked">>];
valid_next_statuses(<<"in_progress">>) -> [<<"in_review">>, <<"blocked">>];
valid_next_statuses(<<"in_review">>) -> [<<"done">>, <<"in_progress">>];
valid_next_statuses(<<"blocked">>) -> [<<"open">>, <<"in_progress">>];
valid_next_statuses(_) -> [].

format_status_label(<<"in_progress">>) -> <<"In Progress">>;
format_status_label(<<"in_review">>) -> <<"In Review">>;
format_status_label(S) -> S.

%%% Auth helpers

require_auth(undefined) ->
    throw({redirect, <<"/login">>});
require_auth(_User) ->
    ok.

check_org_access(#{org_id := OrgId}, OrgSlug) ->
    case ledger_db:one(<<"SELECT id FROM organizations WHERE slug = ?1">>, [OrgSlug]) of
        {ok, {TargetOrgId}} ->
            case TargetOrgId =:= OrgId of
                true -> ok;
                false ->
                    case ledger_db:one(<<"SELECT is_superadmin FROM organizations WHERE id = ?1">>, [OrgId]) of
                        {ok, {1}} -> ok;
                        _ -> throw({redirect, <<"/admin">>})
                    end
            end;
        {error, not_found} ->
            throw({redirect, <<"/admin">>})
    end.

not_found(User, Req) ->
    Body = warrant_html:page(<<"Not Found">>, nav_items(User),
        [<<"<div class=\"section\"><h1>404 &mdash; Not Found</h1>
<p>The page you requested does not exist.</p>
<p><a href=\"/\">Go home</a></p></div>">>]),
    warrant_html:html_reply(404, Body, Req).

resolve_org_project(OrgSlug, ProjectSlug) ->
    case ledger_db:one(
        <<"SELECT o.id, p.id FROM organizations o
           JOIN projects p ON p.org_id = o.id
           WHERE o.slug = ?1 AND p.slug = ?2">>,
        [OrgSlug, ProjectSlug]
    ) of
        {ok, {OrgId, ProjectId}} -> {OrgId, ProjectId};
        {error, not_found} -> error
    end.

resolve_org(Slug) ->
    case ledger_db:one(<<"SELECT id FROM organizations WHERE slug = ?1">>, [Slug]) of
        {ok, {Id}} -> {ok, Id};
        {error, not_found} -> {error, not_found}
    end.

get_cookie_token(Req) ->
    Cookies = cowboy_req:parse_cookies(Req),
    case lists:keyfind(<<"warrant_token">>, 1, Cookies) of
        {_, T} -> T;
        false -> <<>>
    end.
