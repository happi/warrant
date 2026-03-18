import * as vscode from "vscode";
import { execFile } from "child_process";
import { extractTaskIdFromBranch } from "../core/task-id-parser";

export async function getCurrentBranch(cwd?: string): Promise<string | null> {
    const workDir = cwd ?? vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
    if (!workDir) return null;

    return new Promise((resolve) => {
        execFile("git", ["rev-parse", "--abbrev-ref", "HEAD"], { cwd: workDir }, (err, stdout) => {
            if (err) return resolve(null);
            resolve(stdout.trim() || null);
        });
    });
}

export async function getCurrentTaskId(prefix?: string, cwd?: string): Promise<string | null> {
    const branch = await getCurrentBranch(cwd);
    if (!branch) return null;
    return extractTaskIdFromBranch(branch, prefix);
}

export async function getHeadSha(cwd?: string): Promise<string | null> {
    const workDir = cwd ?? vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
    if (!workDir) return null;

    return new Promise((resolve) => {
        execFile("git", ["rev-parse", "HEAD"], { cwd: workDir }, (err, stdout) => {
            if (err) return resolve(null);
            resolve(stdout.trim() || null);
        });
    });
}
