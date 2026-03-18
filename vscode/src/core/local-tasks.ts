import * as vscode from "vscode";
import * as fs from "fs";
import * as path from "path";
import { Task, TaskSummary, TaskStatus, Trace } from "./types";
import { execFile } from "child_process";

/**
 * Reads task data from .warrant/tasks/*.md files in the workspace.
 * No server needed. This is the primary data source.
 */
export class LocalTaskReader {
    private tasksDir: string | null;

    constructor(tasksDir?: string) {
        if (tasksDir && fs.existsSync(tasksDir)) {
            this.tasksDir = tasksDir;
        } else {
            this.tasksDir = null;
        }
    }

    available(): boolean {
        return this.tasksDir !== null;
    }

    async getTask(taskId: string): Promise<Task | null> {
        if (!this.tasksDir) return null;
        const filePath = path.join(this.tasksDir, `${taskId}.md`);
        if (!fs.existsSync(filePath)) return null;
        return parseTaskFile(filePath, taskId);
    }

    async listTasks(): Promise<TaskSummary[]> {
        if (!this.tasksDir) return [];
        const files = fs.readdirSync(this.tasksDir).filter(f => f.endsWith(".md"));
        const tasks: TaskSummary[] = [];
        for (const file of files) {
            const filePath = path.join(this.tasksDir, file);
            const t = parseTaskSummary(filePath);
            if (t) tasks.push(t);
        }
        return tasks;
    }

    async getTrace(taskId: string): Promise<Trace | null> {
        const task = await this.getTask(taskId);
        if (!task) return null;

        const root = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
        if (!root) return null;

        // Get audit from git log on the task file
        const filePath = path.join(".warrant", "tasks", `${taskId}.md`);
        const audit = await gitLogForFile(root, filePath);

        // Get linked commits from git log --all --grep
        const commits = await gitLogGrep(root, taskId);

        return {
            task: {
                id: task.id,
                title: task.title,
                intent: task.intent,
                status: task.status,
                priority: task.priority,
                assigned_to: task.assigned_to,
                created_by: task.created_by,
                created_at: task.created_at,
                updated_at: task.updated_at,
            },
            links: {
                branches: [],
                commits: commits.map(c => ({ ref: c.sha, url: undefined })),
                prs: [],
            },
            audit: audit,
        };
    }
}

function parseTaskFile(filePath: string, taskId: string): Task | null {
    try {
        const content = fs.readFileSync(filePath, "utf8");
        const { frontmatter, body } = parseFrontmatter(content);
        if (!frontmatter.id) return null;

        // Extract intent and decision from body sections
        const intent = extractSection(body, "Intent");
        const decision = extractSection(body, "Decision");

        return {
            id: frontmatter.id || taskId,
            title: frontmatter.title || taskId,
            intent: intent || null,
            status: (frontmatter.status || "open") as TaskStatus,
            priority: (frontmatter.priority as Task["priority"]) || null,
            labels: parseLabels(frontmatter.labels),
            created_by: frontmatter.created_by || "",
            assigned_to: frontmatter.assigned_to || null,
            created_at: frontmatter.created_at || "",
            updated_at: frontmatter.updated_at || frontmatter.created_at || "",
            lease: null,
            links: [],
        };
    } catch {
        return null;
    }
}

function parseTaskSummary(filePath: string): TaskSummary | null {
    try {
        const content = fs.readFileSync(filePath, "utf8");
        const { frontmatter } = parseFrontmatter(content);
        if (!frontmatter.id) return null;

        return {
            id: frontmatter.id,
            title: frontmatter.title || frontmatter.id,
            status: (frontmatter.status || "open") as TaskStatus,
            priority: (frontmatter.priority as Task["priority"]) || null,
            assigned_to: frontmatter.assigned_to || null,
            updated_at: frontmatter.updated_at || frontmatter.created_at || "",
            labels: parseLabels(frontmatter.labels),
        };
    } catch {
        return null;
    }
}

function parseFrontmatter(content: string): { frontmatter: Record<string, string>; body: string } {
    const fm: Record<string, string> = {};
    if (!content.startsWith("---")) return { frontmatter: fm, body: content };

    const endIdx = content.indexOf("---", 3);
    if (endIdx < 0) return { frontmatter: fm, body: content };

    const fmBlock = content.slice(3, endIdx).trim();
    const body = content.slice(endIdx + 3).trim();

    for (const line of fmBlock.split("\n")) {
        const colonIdx = line.indexOf(":");
        if (colonIdx < 0) continue;
        const key = line.slice(0, colonIdx).trim();
        let value = line.slice(colonIdx + 1).trim();
        // Strip quotes
        if ((value.startsWith("'") && value.endsWith("'")) ||
            (value.startsWith('"') && value.endsWith('"'))) {
            value = value.slice(1, -1);
        }
        fm[key] = value;
    }

    return { frontmatter: fm, body };
}

function parseLabels(raw: string | undefined): string[] {
    if (!raw) return [];
    // Handle [a, b] format
    const trimmed = raw.replace(/^\[/, "").replace(/\]$/, "");
    return trimmed.split(",").map(s => s.trim()).filter(Boolean);
}

function extractSection(body: string, heading: string): string | null {
    const pattern = new RegExp(`^## ${heading}\\s*$`, "m");
    const match = body.match(pattern);
    if (!match || match.index === undefined) return null;

    const start = match.index + match[0].length;
    // Find next heading or end
    const nextHeading = body.indexOf("\n## ", start);
    const section = nextHeading >= 0
        ? body.slice(start, nextHeading)
        : body.slice(start);

    return section.trim() || null;
}

function gitLogForFile(cwd: string, filePath: string): Promise<Array<{ event_type: string; actor: string; timestamp: string; id: number }>> {
    return new Promise((resolve) => {
        execFile("git", ["log", "--format=%H|%an|%aI|%s", "--follow", "--", filePath],
            { cwd, maxBuffer: 512 * 1024 },
            (err, stdout) => {
                if (err) return resolve([]);
                const lines = stdout.trim().split("\n").filter(Boolean);
                resolve(lines.map((line, i) => {
                    const [_sha, author, date, summary] = line.split("|");
                    return {
                        id: lines.length - i,
                        event_type: summary || "commit",
                        actor: author || "unknown",
                        timestamp: date || "",
                    };
                }));
            });
    });
}

function gitLogGrep(cwd: string, taskId: string): Promise<Array<{ sha: string; summary: string }>> {
    return new Promise((resolve) => {
        execFile("git", ["log", "--all", "--format=%H|%s", `--grep=${taskId}`],
            { cwd, maxBuffer: 512 * 1024 },
            (err, stdout) => {
                if (err) return resolve([]);
                const lines = stdout.trim().split("\n").filter(Boolean);
                resolve(lines.map(line => {
                    const [sha, ...rest] = line.split("|");
                    return { sha, summary: rest.join("|") };
                }));
            });
    });
}
