import * as vscode from "vscode";
import { ApiClient } from "../core/api-client";
import { getCurrentTaskId } from "../git/branch";

export function registerStatusCommands(api: ApiClient, prefix: string): vscode.Disposable[] {
    return [
        vscode.commands.registerCommand("warrant.startTask", async () => {
            await transitionCurrentTask(api, prefix, "in_progress", "open");
        }),
        vscode.commands.registerCommand("warrant.reviewTask", async () => {
            await transitionCurrentTask(api, prefix, "in_review", "in_progress");
        }),
        vscode.commands.registerCommand("warrant.doneTask", async () => {
            await transitionCurrentTask(api, prefix, "done", "in_review");
        }),
    ];
}

async function transitionCurrentTask(
    api: ApiClient, prefix: string, newStatus: string, expectedStatus: string,
): Promise<void> {
    const taskId = await getCurrentTaskId(prefix);
    if (!taskId) {
        vscode.window.showWarningMessage("No task ID found on current branch");
        return;
    }

    const task = await api.getTask(taskId);
    if (!task) {
        vscode.window.showErrorMessage(`Task ${taskId} not found`);
        return;
    }

    if (task.status !== expectedStatus) {
        const proceed = await vscode.window.showWarningMessage(
            `Task ${taskId} is currently "${task.status}", expected "${expectedStatus}". Transition to "${newStatus}" from "${task.status}"?`,
            "Yes", "No",
        );
        if (proceed !== "Yes") return;
        expectedStatus = task.status;
    }

    const ok = await api.updateStatus(taskId, newStatus, expectedStatus);
    if (ok) {
        vscode.window.showInformationMessage(`${taskId}: ${expectedStatus} → ${newStatus}`);
    } else {
        vscode.window.showErrorMessage(`Failed to transition ${taskId}`);
    }
}
