import * as vscode from "vscode";
import { getCurrentTaskId } from "./git/branch";
import { TaskLookup } from "./core/types";

let statusBarItem: vscode.StatusBarItem;

export function createStatusBar(api: TaskLookup, prefix: string): vscode.StatusBarItem {
    statusBarItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 100);
    statusBarItem.command = "warrant.showTrace";
    statusBarItem.tooltip = "Click to show task trace";
    refreshStatusBar(api, prefix);
    return statusBarItem;
}

export async function refreshStatusBar(api: TaskLookup, prefix: string): Promise<void> {
    const taskId = await getCurrentTaskId(prefix);

    if (!taskId) {
        statusBarItem.text = "$(checklist) No task";
        statusBarItem.tooltip = "Branch doesn't contain a task ID";
        statusBarItem.show();
        return;
    }

    statusBarItem.text = `$(loading~spin) ${taskId}`;
    statusBarItem.show();

    const task = await api.getTask(taskId);
    if (task) {
        const icon = statusIcon(task.status);
        statusBarItem.text = `${icon} ${task.id}: ${truncate(task.title, 30)}`;
        statusBarItem.tooltip = [
            `${task.id}: ${task.title}`,
            `Status: ${task.status}`,
            task.intent ? `Intent: ${task.intent}` : "",
            task.assigned_to ? `Assigned: ${task.assigned_to}` : "",
            task.lease ? `Leased by: ${task.lease.owner}` : "",
        ].filter(Boolean).join("\n");
    } else {
        statusBarItem.text = `$(warning) ${taskId} (not found)`;
        statusBarItem.tooltip = `Task ${taskId} not found in the ledger`;
    }
}

function statusIcon(status: string): string {
    switch (status) {
        case "open": return "$(circle-outline)";
        case "in_progress": return "$(play-circle)";
        case "in_review": return "$(eye)";
        case "done": return "$(check)";
        case "blocked": return "$(stop-circle)";
        case "cancelled": return "$(close)";
        default: return "$(question)";
    }
}

function truncate(s: string, max: number): string {
    return s.length > max ? s.slice(0, max - 1) + "\u2026" : s;
}
