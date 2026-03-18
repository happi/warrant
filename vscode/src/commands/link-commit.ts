import * as vscode from "vscode";
import { ApiClient } from "../core/api-client";
import { getCurrentTaskId, getHeadSha, getCurrentBranch } from "../git/branch";

export function registerLinkCommands(api: ApiClient, prefix: string): vscode.Disposable[] {
    return [
        vscode.commands.registerCommand("warrant.linkCommit", async () => {
            const taskId = await getCurrentTaskId(prefix);
            if (!taskId) {
                vscode.window.showWarningMessage("No task ID found on current branch");
                return;
            }

            const sha = await getHeadSha();
            if (!sha) {
                vscode.window.showErrorMessage("Could not get HEAD commit SHA");
                return;
            }

            const ok = await api.linkCommit(taskId, sha);
            if (ok) {
                vscode.window.showInformationMessage(`Linked ${sha.slice(0, 8)} → ${taskId}`);
            } else {
                vscode.window.showWarningMessage(`Link may already exist or task not found`);
            }

            // Also link branch if not already done
            const branch = await getCurrentBranch();
            if (branch && branch.startsWith("task/")) {
                await api.linkBranch(taskId, branch);
            }
        }),
    ];
}
