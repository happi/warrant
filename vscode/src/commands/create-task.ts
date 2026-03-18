import * as vscode from "vscode";
import { ApiClient } from "../core/api-client";

export function registerCreateCommand(api: ApiClient | null): vscode.Disposable[] {
    return [
        vscode.commands.registerCommand("warrant.createTask", async () => {
            const title = await vscode.window.showInputBox({
                prompt: "Task title",
                placeHolder: "Fix the login page redirect",
            });
            if (!title) return;

            const intent = await vscode.window.showInputBox({
                prompt: "Intent (why does this task exist?)",
                placeHolder: "Users get redirected to a 404 after login",
            });

            const priorityPick = await vscode.window.showQuickPick(
                ["high", "medium", "low"],
                { placeHolder: "Priority" },
            );

            const labelsInput = await vscode.window.showInputBox({
                prompt: "Labels (comma-separated, optional)",
                placeHolder: "bug, auth",
            });
            const labels = labelsInput
                ? labelsInput.split(",").map(l => l.trim()).filter(Boolean)
                : undefined;

            if (!api) {
                vscode.window.showWarningMessage("No server configured. Create the task file manually in .warrant/tasks/");
                return;
            }
            const task = await api.createTask(title, intent || undefined, labels, priorityPick || undefined);
            if (task) {
                const action = await vscode.window.showInformationMessage(
                    `Created ${task.id}: ${task.title}`,
                    "Copy ID", "Create Branch",
                );
                if (action === "Copy ID") {
                    await vscode.env.clipboard.writeText(task.id);
                } else if (action === "Create Branch") {
                    const slug = title.toLowerCase().replace(/[^a-z0-9]+/g, "-").slice(0, 40);
                    const branchName = `task/${task.id}-${slug}`;
                    await vscode.env.clipboard.writeText(`git checkout -b ${branchName}`);
                    vscode.window.showInformationMessage(`Branch command copied: ${branchName}`);
                }
            } else {
                vscode.window.showErrorMessage("Failed to create task");
            }
        }),
    ];
}
