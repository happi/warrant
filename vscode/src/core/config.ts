import * as vscode from "vscode";
import * as fs from "fs";
import * as path from "path";
import { LedgerConfig } from "./types";

export interface WarrantConfig {
    prefix: string;
    tasksDir: string;           // absolute path
    server: LedgerConfig | null; // null = local-only mode
}

/**
 * Resolve warrant configuration. Sources in priority order:
 * 1. .warrant/config.yaml (checked into repo, shared by CLI and VS Code)
 * 2. .warrant/.env (legacy, tokens only)
 * 3. VS Code settings
 * 4. Environment variables
 */
export function resolveWarrantConfig(): WarrantConfig | null {
    const workspaceRoot = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
    if (!workspaceRoot) return null;

    let prefix = "";
    let tasksDir = path.join(workspaceRoot, ".warrant", "tasks");
    let serverUrl = "";
    let serverOrg = "";
    let serverProject = "";
    let serverToken = "";
    let tokenEnv = "";

    // 1. .warrant/config.yaml
    const configPath = path.join(workspaceRoot, ".warrant", "config.yaml");
    if (fs.existsSync(configPath)) {
        const yaml = parseSimpleYaml(fs.readFileSync(configPath, "utf8"));
        prefix = yaml["prefix"] || "";
        if (yaml["tasks_dir"]) {
            tasksDir = path.isAbsolute(yaml["tasks_dir"])
                ? yaml["tasks_dir"]
                : path.join(workspaceRoot, yaml["tasks_dir"]);
        }
        // Server block (simple flat parse for now)
        serverUrl = yaml["server.url"] || yaml["server_url"] || "";
        serverOrg = yaml["server.org"] || yaml["server_org"] || "";
        serverProject = yaml["server.project"] || yaml["server_project"] || "";
        tokenEnv = yaml["server.token_env"] || yaml["server_token_env"] || "";
    }

    // 2. .warrant/.env (overrides, especially for token)
    const envPath = path.join(workspaceRoot, ".warrant", ".env");
    if (fs.existsSync(envPath)) {
        const env = parseEnvFile(envPath);
        serverUrl = serverUrl || env["WARRANT_URL"] || "";
        serverOrg = serverOrg || env["WARRANT_ORG"] || "";
        serverProject = serverProject || env["WARRANT_PROJECT"] || "";
        serverToken = serverToken || env["WARRANT_TOKEN"] || "";
        prefix = prefix || env["WARRANT_PREFIX"] || "";
    }

    // 3. VS Code settings
    const vsConfig = vscode.workspace.getConfiguration("warrant");
    prefix = prefix || vsConfig.get<string>("prefix") || "";
    serverUrl = serverUrl || vsConfig.get<string>("url") || "";
    serverOrg = serverOrg || vsConfig.get<string>("org") || "";
    serverProject = serverProject || vsConfig.get<string>("project") || "";
    serverToken = serverToken || vsConfig.get<string>("token") || "";

    // 4. Environment variables
    serverUrl = serverUrl || process.env.WARRANT_URL || "";
    serverOrg = serverOrg || process.env.WARRANT_ORG || "";
    serverProject = serverProject || process.env.WARRANT_PROJECT || "";
    serverToken = serverToken || process.env.WARRANT_TOKEN || "";
    prefix = prefix || process.env.WARRANT_PREFIX || "";

    // Resolve token from env var name if specified
    if (!serverToken && tokenEnv) {
        serverToken = process.env[tokenEnv] || "";
    }

    // Need at minimum a tasks directory or server config
    const hasTasksDir = fs.existsSync(tasksDir);
    const hasServer = !!(serverUrl && serverOrg && serverProject && serverToken);

    if (!hasTasksDir && !hasServer) return null;

    const server: LedgerConfig | null = hasServer
        ? { url: serverUrl, org: serverOrg, project: serverProject, token: serverToken, prefix }
        : null;

    return { prefix, tasksDir, server };
}

// Legacy function for backward compat
export function resolveConfig(): LedgerConfig | null {
    const wc = resolveWarrantConfig();
    return wc?.server ?? null;
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

/**
 * Minimal YAML parser for flat key: value files.
 * Handles nested keys by flattening: "server:\n  url: x" becomes "server.url": "x"
 */
function parseSimpleYaml(content: string): Record<string, string> {
    const result: Record<string, string> = {};
    let currentPrefix = "";

    for (const line of content.split("\n")) {
        // Skip comments and empty lines
        if (line.trim().startsWith("#") || !line.trim()) continue;

        const indent = line.length - line.trimStart().length;
        const trimmed = line.trim();

        const colonIdx = trimmed.indexOf(":");
        if (colonIdx < 0) continue;

        const key = trimmed.slice(0, colonIdx).trim();
        const value = trimmed.slice(colonIdx + 1).trim();

        if (indent === 0) {
            if (value === "" || value === "|") {
                // This is a parent key
                currentPrefix = key + ".";
            } else {
                currentPrefix = "";
                result[key] = value;
            }
        } else if (currentPrefix && value) {
            result[currentPrefix + key] = value;
        }
    }

    return result;
}
