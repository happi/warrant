-module(warrant_html).

%% HTML rendering utilities for Warrant UI.
%% Server-rendered HTML with HTMX for interactivity.

-export([page/3, h/1, html_reply/3]).
-export([badge/1, priority_badge/1, table/2, card/1]).
-export([form_field/3, form_field/4, button/2, button/3]).
-export([flash/2, nav/2, breadcrumbs/1]).

%%% Core rendering

page(Title, NavItems, Content) ->
    [<<"<!DOCTYPE html>
<html lang=\"en\">
<head>
<meta charset=\"utf-8\">
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
<title>">>, h(Title), <<" - Warrant</title>
<script src=\"https://unpkg.com/htmx.org@2.0.4\"></script>
<style>">>, css(), <<"</style>
</head>
<body>
<nav class=\"topnav\">
<div class=\"nav-left\">
<a href=\"/\" class=\"logo\">Warrant</a>
</div>
<div class=\"nav-right\">">>,
    nav(NavItems, []),
<<"</div>
</nav>
<main>">>,
    Content,
<<"</main>
</body>
</html>">>].

h(undefined) -> <<>>;
h(null) -> <<>>;
h(B) when is_binary(B) ->
    B1 = binary:replace(B, <<"&">>, <<"&amp;">>, [global]),
    B2 = binary:replace(B1, <<"<">>, <<"&lt;">>, [global]),
    B3 = binary:replace(B2, <<">">>, <<"&gt;">>, [global]),
    B4 = binary:replace(B3, <<"\"">>, <<"&quot;">>, [global]),
    B4;
h(L) when is_list(L) -> h(list_to_binary(L));
h(A) when is_atom(A) -> h(atom_to_binary(A, utf8));
h(I) when is_integer(I) -> integer_to_binary(I);
h(Other) -> h(iolist_to_binary(io_lib:format("~p", [Other]))).

html_reply(Status, Body, Req0) ->
    Headers = #{<<"content-type">> => <<"text/html; charset=utf-8">>},
    Req = cowboy_req:reply(Status, Headers, Body, Req0),
    {ok, Req}.

%%% Components

badge(<<"open">>) ->
    [<<"<span class=\"badge badge-open\">open</span>">>];
badge(<<"in_progress">>) ->
    [<<"<span class=\"badge badge-progress\">in progress</span>">>];
badge(<<"in_review">>) ->
    [<<"<span class=\"badge badge-review\">in review</span>">>];
badge(<<"done">>) ->
    [<<"<span class=\"badge badge-done\">done</span>">>];
badge(<<"blocked">>) ->
    [<<"<span class=\"badge badge-blocked\">blocked</span>">>];
badge(<<"cancelled">>) ->
    [<<"<span class=\"badge badge-cancelled\">cancelled</span>">>];
badge(Status) ->
    [<<"<span class=\"badge\">">>, h(Status), <<"</span>">>].

priority_badge(<<"critical">>) ->
    [<<"<span class=\"priority priority-critical\">critical</span>">>];
priority_badge(<<"high">>) ->
    [<<"<span class=\"priority priority-high\">high</span>">>];
priority_badge(<<"medium">>) ->
    [<<"<span class=\"priority priority-medium\">medium</span>">>];
priority_badge(<<"low">>) ->
    [<<"<span class=\"priority priority-low\">low</span>">>];
priority_badge(null) -> <<>>;
priority_badge(undefined) -> <<>>;
priority_badge(P) ->
    [<<"<span class=\"priority\">">>, h(P), <<"</span>">>].

table(Headers, Rows) ->
    [<<"<table><thead><tr>">>,
     [[<<"<th>">>, h(H), <<"</th>">>] || H <- Headers],
     <<"</tr></thead><tbody>">>,
     [[<<"<tr>">>, [[<<"<td>">>, C, <<"</td>">>] || C <- Row], <<"</tr>">>] || Row <- Rows],
     <<"</tbody></table>">>].

card(Props) ->
    Id = maps:get(id, Props, <<>>),
    Title = maps:get(title, Props, <<>>),
    Status = maps:get(status, Props, <<>>),
    Priority = maps:get(priority, Props, null),
    Labels = maps:get(labels, Props, []),
    AssignedTo = maps:get(assigned_to, Props, null),
    Org = maps:get(org, Props, <<>>),
    Project = maps:get(project, Props, <<>>),
    [<<"<div class=\"card\" id=\"task-">>, h(Id), <<"\">
<div class=\"card-header\">
<a href=\"/tasks/">>, h(Org), <<"/">>, h(Project), <<"/">>, h(Id), <<"\">
<strong>">>, h(Id), <<"</strong></a>">>,
    priority_badge(Priority),
    <<"</div>
<div class=\"card-title\">">>, h(Title), <<"</div>
<div class=\"card-footer\">">>,
    [[<<"<span class=\"label\">">>, h(L), <<"</span>">>] || L <- Labels],
    case AssignedTo of
        null -> <<>>;
        undefined -> <<>>;
        _ -> [<<"<span class=\"assignee\">">>, h(AssignedTo), <<"</span>">>]
    end,
    <<"<div class=\"card-actions\">">>,
    status_actions(Id, Status, Org, Project),
    <<"</div>
</div>
</div>">>].

status_actions(Id, Status, Org, Project) ->
    Transitions = valid_next(Status),
    case Transitions of
        [] -> <<>>;
        _ ->
            [<<"<select class=\"move-select\" hx-post=\"/api/v1/orgs/">>,
             h(Org), <<"/projects/">>, h(Project),
             <<"/tasks/">>, h(Id), <<"/status\"
             hx-target=\"#board\" hx-swap=\"outerHTML\"
             hx-vals='js:{\"expected_status\":\"">>, h(Status),
             <<"\", \"status\": event.target.value}'
             hx-trigger=\"change\">
<option value=\"\">Move to...</option>">>,
             [[<<"<option value=\"">>, h(S), <<"\">">>, h(format_status(S)), <<"</option>">>]
              || S <- Transitions],
             <<"</select>">>]
    end.

valid_next(<<"open">>) -> [<<"in_progress">>, <<"blocked">>];
valid_next(<<"in_progress">>) -> [<<"in_review">>, <<"blocked">>];
valid_next(<<"in_review">>) -> [<<"done">>, <<"in_progress">>];
valid_next(<<"blocked">>) -> [<<"open">>, <<"in_progress">>];
valid_next(_) -> [].

format_status(<<"in_progress">>) -> <<"In Progress">>;
format_status(<<"in_review">>) -> <<"In Review">>;
format_status(S) -> S.

form_field(Label, Name, Type) ->
    form_field(Label, Name, Type, <<>>).

form_field(Label, Name, Type, Value) ->
    [<<"<div class=\"field\">
<label for=\"">>, h(Name), <<"\">">>, h(Label), <<"</label>
<input type=\"">>, h(Type), <<"\" id=\"">>, h(Name),
     <<"\" name=\"">>, h(Name), <<"\" value=\"">>, h(Value), <<"\">
</div>">>].

button(Text, Attrs) ->
    button(Text, Attrs, <<"primary">>).

button(Text, Attrs, Class) ->
    [<<"<button class=\"btn btn-">>, h(Class), <<"\" ">>, Attrs, <<">">>,
     h(Text), <<"</button>">>].

flash(Type, Message) ->
    [<<"<div class=\"flash flash-">>, h(Type), <<"\">">>, h(Message), <<"</div>">>].

nav([], Acc) -> lists:reverse(Acc);
nav([{Href, Label} | Rest], Acc) ->
    Item = [<<"<a href=\"">>, h(Href), <<"\">">>, h(Label), <<"</a>">>],
    nav(Rest, [Item | Acc]);
nav([{Href, Label, active} | Rest], Acc) ->
    Item = [<<"<a href=\"">>, h(Href), <<"\" class=\"active\">">>, h(Label), <<"</a>">>],
    nav(Rest, [Item | Acc]).

breadcrumbs(Items) ->
    [<<"<div class=\"breadcrumbs\">">>,
     lists:join(<<" / ">>, [[<<"<a href=\"">>, h(Href), <<"\">">>, h(Label), <<"</a>">>]
                             || {Href, Label} <- Items]),
     <<"</div>">>].

%%% CSS

css() -> <<"
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;
  background:#f5f5f5;color:#333;line-height:1.5}
a{color:#2563eb;text-decoration:none}
a:hover{text-decoration:underline}

.topnav{background:#1e293b;color:#fff;padding:0.75rem 1.5rem;display:flex;
  justify-content:space-between;align-items:center;position:sticky;top:0;z-index:100}
.topnav a{color:#94a3b8}
.topnav a:hover{color:#fff;text-decoration:none}
.topnav .logo{color:#fff;font-weight:700;font-size:1.1rem}
.nav-right{display:flex;gap:1.5rem}
.nav-right .active{color:#fff}

main{max-width:1400px;margin:0 auto;padding:1.5rem}

.breadcrumbs{margin-bottom:1rem;color:#64748b;font-size:0.875rem}
.breadcrumbs a{color:#64748b}

h1{font-size:1.5rem;margin-bottom:1rem}
h2{font-size:1.25rem;margin-bottom:0.75rem}
h3{font-size:1.1rem;margin-bottom:0.5rem}

.badge{display:inline-block;padding:0.125rem 0.5rem;border-radius:9999px;
  font-size:0.75rem;font-weight:600;text-transform:uppercase;letter-spacing:0.025em}
.badge-open{background:#dbeafe;color:#1d4ed8}
.badge-progress{background:#fef3c7;color:#92400e}
.badge-review{background:#e0e7ff;color:#4338ca}
.badge-done{background:#d1fae5;color:#065f46}
.badge-blocked{background:#fee2e2;color:#991b1b}
.badge-cancelled{background:#e5e7eb;color:#4b5563}

.priority{display:inline-block;padding:0.125rem 0.375rem;border-radius:4px;
  font-size:0.7rem;font-weight:600;margin-left:0.25rem}
.priority-critical{background:#ef4444;color:#fff}
.priority-high{background:#f97316;color:#fff}
.priority-medium{background:#eab308;color:#fff}
.priority-low{background:#94a3b8;color:#fff}

.label{display:inline-block;padding:0.1rem 0.375rem;border-radius:4px;
  font-size:0.7rem;background:#e2e8f0;color:#475569;margin-right:0.25rem}

.assignee{font-size:0.75rem;color:#64748b}

table{width:100%;border-collapse:collapse;background:#fff;border-radius:8px;
  overflow:hidden;box-shadow:0 1px 3px rgba(0,0,0,0.1)}
th{background:#f8fafc;text-align:left;padding:0.75rem 1rem;font-weight:600;
  font-size:0.875rem;color:#64748b;border-bottom:2px solid #e2e8f0}
td{padding:0.75rem 1rem;border-bottom:1px solid #f1f5f9}
tr:hover td{background:#f8fafc}

.card{background:#fff;border-radius:8px;padding:0.75rem;margin-bottom:0.5rem;
  box-shadow:0 1px 2px rgba(0,0,0,0.08);border:1px solid #e2e8f0}
.card-header{display:flex;align-items:center;gap:0.5rem;margin-bottom:0.375rem}
.card-header a{color:#1e293b}
.card-title{font-size:0.875rem;margin-bottom:0.5rem}
.card-footer{display:flex;align-items:center;gap:0.375rem;flex-wrap:wrap}
.card-actions{margin-left:auto}
.move-select{font-size:0.75rem;padding:0.125rem 0.25rem;border:1px solid #e2e8f0;
  border-radius:4px;background:#fff;cursor:pointer}

.board{display:flex;gap:1rem;overflow-x:auto;padding-bottom:1rem;min-height:60vh}
.column{flex:0 0 280px;background:#f1f5f9;border-radius:8px;padding:0.75rem}
.column-header{font-weight:600;font-size:0.875rem;margin-bottom:0.75rem;
  display:flex;justify-content:space-between;align-items:center}
.column-count{background:#e2e8f0;color:#64748b;padding:0.125rem 0.5rem;
  border-radius:9999px;font-size:0.75rem}

.field{margin-bottom:1rem}
.field label{display:block;font-weight:600;font-size:0.875rem;margin-bottom:0.25rem;color:#374151}
.field input,.field select,.field textarea{width:100%;padding:0.5rem 0.75rem;
  border:1px solid #d1d5db;border-radius:6px;font-size:0.875rem}
.field textarea{min-height:80px;resize:vertical}
.field input:focus,.field select:focus,.field textarea:focus{outline:none;
  border-color:#2563eb;box-shadow:0 0 0 3px rgba(37,99,235,0.1)}

.btn{padding:0.5rem 1rem;border:none;border-radius:6px;font-size:0.875rem;
  font-weight:600;cursor:pointer;display:inline-flex;align-items:center;gap:0.375rem}
.btn-primary{background:#2563eb;color:#fff}
.btn-primary:hover{background:#1d4ed8}
.btn-secondary{background:#e2e8f0;color:#374151}
.btn-secondary:hover{background:#cbd5e1}
.btn-danger{background:#ef4444;color:#fff}
.btn-danger:hover{background:#dc2626}
.btn-sm{padding:0.25rem 0.5rem;font-size:0.75rem}

.flash{padding:0.75rem 1rem;border-radius:6px;margin-bottom:1rem;font-size:0.875rem}
.flash-success{background:#d1fae5;color:#065f46;border:1px solid #a7f3d0}
.flash-error{background:#fee2e2;color:#991b1b;border:1px solid #fecaca}
.flash-info{background:#dbeafe;color:#1d4ed8;border:1px solid #bfdbfe}

.grid{display:grid;gap:1.5rem}
.grid-2{grid-template-columns:repeat(2,1fr)}
.grid-3{grid-template-columns:repeat(3,1fr)}

.section{background:#fff;border-radius:8px;padding:1.5rem;
  box-shadow:0 1px 3px rgba(0,0,0,0.1);margin-bottom:1.5rem}

.detail-grid{display:grid;grid-template-columns:120px 1fr;gap:0.5rem 1rem;
  font-size:0.875rem}
.detail-label{color:#64748b;font-weight:600}

.timeline{border-left:2px solid #e2e8f0;margin-left:1rem;padding-left:1.5rem}
.timeline-item{position:relative;margin-bottom:1rem;padding-bottom:0.5rem}
.timeline-item::before{content:'';position:absolute;left:-1.8rem;top:0.25rem;
  width:10px;height:10px;border-radius:50%;background:#94a3b8;border:2px solid #fff}
.timeline-time{font-size:0.75rem;color:#94a3b8}
.timeline-text{font-size:0.875rem}

.project-card{background:#fff;border-radius:8px;padding:1.25rem;
  box-shadow:0 1px 3px rgba(0,0,0,0.1);border:1px solid #e2e8f0;
  transition:border-color 0.15s}
.project-card:hover{border-color:#2563eb;text-decoration:none}
.project-card h3{margin:0}
.project-card .prefix{color:#64748b;font-size:0.875rem}

.landing{text-align:center;padding:4rem 2rem}
.landing h1{font-size:2rem;margin-bottom:0.5rem}
.landing p{color:#64748b;font-size:1.1rem;margin-bottom:2rem}
.landing .cta{display:inline-flex;gap:1rem}

.empty{text-align:center;padding:2rem;color:#94a3b8;font-style:italic}

.inline-form{background:#f8fafc;border-radius:8px;padding:1rem;margin-top:0.75rem;
  border:1px solid #e2e8f0}

.token-display{font-family:monospace;background:#1e293b;color:#10b981;
  padding:0.75rem 1rem;border-radius:6px;word-break:break-all;font-size:0.875rem}

.user-table .role{text-transform:capitalize}

@media(max-width:768px){
  .board{flex-direction:column}
  .column{flex:none;width:100%}
  .grid-2,.grid-3{grid-template-columns:1fr}
}
">>.
