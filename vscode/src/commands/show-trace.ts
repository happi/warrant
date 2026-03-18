import * as vscode from "vscode";
import { ApiClient } from "../core/api-client";
import { getCurrentTaskId } from "../git/branch";
import { Trace } from "../core/types";

export function registerTraceCommands(api: ApiClient, prefix: string): vscode.Disposable[] {
    return [
        vscode.commands.registerCommand("warrant.showTrace", async (taskIdArg?: string) => {
            const taskId = taskIdArg || await getCurrentTaskId(prefix);
            if (!taskId) {
                const input = await vscode.window.showInputBox({
                    prompt: "Task ID",
                    placeHolder: `${prefix || "TASK"}-42`,
                });
                if (!input) return;
                return showTrace(api, input.toUpperCase());
            }
            return showTrace(api, taskId);
        }),

        vscode.commands.registerCommand("warrant.openTask", async (taskIdArg?: string) => {
            if (taskIdArg) return showTrace(api, taskIdArg);

            const tasks = await api.listTasks({ limit: "20" });
            const pick = await vscode.window.showQuickPick(
                tasks.map(t => ({
                    label: `${t.id}: ${t.title}`,
                    description: t.status,
                    detail: t.assigned_to ? `Assigned: ${t.assigned_to}` : undefined,
                    taskId: t.id,
                })),
                { placeHolder: "Select a task" },
            );
            if (pick) return showTrace(api, pick.taskId);
        }),
    ];
}

async function showTrace(api: ApiClient, taskId: string): Promise<void> {
    const trace = await api.getTrace(taskId);
    if (!trace) {
        vscode.window.showErrorMessage(`Task ${taskId} not found`);
        return;
    }

    const panel = vscode.window.createWebviewPanel(
        "warrant.trace",
        `Trace: ${taskId}`,
        vscode.ViewColumn.Beside,
        { enableScripts: false },
    );

    panel.webview.html = renderTrace(trace, taskId);
}

function renderTrace(trace: Trace, taskId: string): string {
    const { task, links, audit } = trace;

    const refStr = (item: string | { ref: string; url?: string }): string => {
        if (typeof item === "string") return esc(item);
        if (item.url) return `<a href="${esc(item.url)}">${esc(item.ref)}</a>`;
        return esc(item.ref);
    };

    const branches = links.branches.map(refStr).join("<br>") || "<em>none</em>";
    const commits = links.commits.map(refStr).join("<br>") || "<em>none</em>";
    const prs = links.prs.map(refStr).join("<br>") || "<em>none</em>";

    const auditRows = audit.map(e =>
        `<tr>
            <td>${esc(e.timestamp)}</td>
            <td>${esc(e.actor)}</td>
            <td>${esc(e.event_type)}</td>
            <td><code>${esc(JSON.stringify(e.detail ?? {}))}</code></td>
        </tr>`
    ).join("\n");

    return `<!DOCTYPE html>
<html>
<head>
<style>
body { font-family: var(--vscode-font-family); color: var(--vscode-foreground); background: var(--vscode-editor-background); padding: 1em; }
h1, h2, h3 { color: var(--vscode-foreground); }
table { border-collapse: collapse; width: 100%; margin: 0.5em 0; }
th, td { text-align: left; padding: 4px 8px; border-bottom: 1px solid var(--vscode-panel-border); }
th { font-weight: bold; }
.badge { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 0.85em; }
.status-open { background: #555; }
.status-in_progress { background: #0a6; color: white; }
.status-in_review { background: #d80; color: white; }
.status-done { background: #080; color: white; }
.status-blocked { background: #c00; color: white; }
code { font-size: 0.85em; word-break: break-all; }
</style>
</head>
<body>
<h1>${esc(taskId)}: ${esc(task.title)}</h1>
<p><span class="badge status-${task.status}">${esc(task.status)}</span>
${task.priority ? ` | Priority: <strong>${esc(task.priority)}</strong>` : ""}
${task.assigned_to ? ` | Assigned: ${esc(task.assigned_to)}` : ""}
</p>
${task.intent ? `<p><strong>Intent:</strong> ${esc(task.intent)}</p>` : ""}

<h2>Linked Artifacts</h2>
<table>
<tr><th>Branches</th><td>${branches}</td></tr>
<tr><th>Commits</th><td>${commits}</td></tr>
<tr><th>PRs</th><td>${prs}</td></tr>
</table>

<h2>Audit Trail</h2>
<table>
<tr><th>Time</th><th>Actor</th><th>Event</th><th>Detail</th></tr>
${auditRows}
</table>
</body>
</html>`;
}

function esc(s: string | null | undefined): string {
    if (!s) return "";
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}
