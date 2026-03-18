import * as vscode from "vscode";
import * as fs from "fs";
import * as path from "path";
import { LedgerConfig } from "./types";

/**
 * Resolve ledger configuration from multiple sources (in priority order):
 * 1. VS Code settings
 * 2. .warrant/.env in workspace root
 * 3. .warrant.json in workspace root
 */
export function resolveConfig(): LedgerConfig | null {
    const vsConfig = vscode.workspace.getConfiguration("warrant");
    const workspaceRoot = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;

    // Start with VS Code settings
    let url = vsConfig.get<string>("url") || "";
    let org = vsConfig.get<string>("org") || "";
    let project = vsConfig.get<string>("project") || "";
    let token = vsConfig.get<string>("token") || "";
    let prefix = vsConfig.get<string>("prefix") || "";

    if (workspaceRoot) {
        // Try .warrant/.env
        const envPath = path.join(workspaceRoot, ".warrant", ".env");
        if (fs.existsSync(envPath)) {
            const env = parseEnvFile(envPath);
            url = url || env["WARRANT_URL"] || "";
            org = org || env["WARRANT_ORG"] || "";
            project = project || env["WARRANT_PROJECT"] || "";
            token = token || env["WARRANT_TOKEN"] || "";
            prefix = prefix || env["WARRANT_PREFIX"] || "";
        }

        // Try .warrant.json
        const jsonPath = path.join(workspaceRoot, ".warrant.json");
        if (fs.existsSync(jsonPath)) {
            try {
                const json = JSON.parse(fs.readFileSync(jsonPath, "utf8"));
                url = url || json.url || "";
                org = org || json.org || "";
                project = project || json.project || "";
                token = token || json.token || "";
                prefix = prefix || json.prefix || "";
            } catch {
                // ignore parse errors
            }
        }
    }

    // Also check environment variables
    url = url || process.env.WARRANT_URL || "";
    org = org || process.env.WARRANT_ORG || "";
    project = project || process.env.WARRANT_PROJECT || "";
    token = token || process.env.WARRANT_TOKEN || "";
    prefix = prefix || process.env.WARRANT_PREFIX || "";

    if (!url || !org || !project || !token) {
        return null;
    }

    return { url, org, project, token, prefix };
}

function parseEnvFile(filePath: string): Record<string, string> {
    const result: Record<string, string> = {};
    const content = fs.readFileSync(filePath, "utf8");
    for (const line of content.split("\n")) {
        const trimmed = line.trim();
        if (!trimmed || trimmed.startsWith("#")) continue;
        const eqIdx = trimmed.indexOf("=");
        if (eqIdx < 0) continue;
        const key = trimmed.slice(0, eqIdx).trim();
        const value = trimmed.slice(eqIdx + 1).trim();
        result[key] = value;
    }
    return result;
}
