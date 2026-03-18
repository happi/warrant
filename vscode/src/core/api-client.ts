import * as vscode from "vscode";
import { LedgerConfig, Task, TaskSummary, Trace, AuditEvent, ArtifactLink } from "./types";
import { Cache } from "./cache";

const TASK_TTL = 30_000;      // 30s for individual tasks
const LIST_TTL = 60_000;      // 1min for task lists
const TRACE_TTL = 120_000;    // 2min for traces
const TIMEOUT = 5_000;        // 5s request timeout

export class ApiClient {
    private config: LedgerConfig;
    private cache: Cache;
    private baseUrl: string;
    private log: vscode.OutputChannel;

    constructor(config: LedgerConfig, cache: Cache, log: vscode.OutputChannel) {
        this.config = config;
        this.cache = cache;
        this.log = log;
        this.baseUrl = `${config.url}/api/v1/orgs/${config.org}/projects/${config.project}`;
    }

    async getTask(taskId: string): Promise<Task | null> {
        const key = `task:${taskId}`;
        const cached = this.cache.get<Task>(key);
        if (cached) return cached;

        const result = await this.request<{ data: Task }>(`/tasks/${taskId}`);
        if (result?.data) {
            this.cache.set(key, result.data, TASK_TTL);
            return result.data;
        }
        return null;
    }

    async listTasks(filters: Record<string, string> = {}): Promise<TaskSummary[]> {
        const qs = new URLSearchParams(filters).toString();
        const key = `tasks:${qs}`;
        const cached = this.cache.get<TaskSummary[]>(key);
        if (cached) return cached;

        const result = await this.request<{ data: TaskSummary[] }>(`/tasks?${qs}`);
        if (result?.data) {
            this.cache.set(key, result.data, LIST_TTL);
            return result.data;
        }
        return [];
    }

    async getTrace(taskId: string): Promise<Trace | null> {
        const key = `trace:${taskId}`;
        const cached = this.cache.get<Trace>(key);
        if (cached) return cached;

        const result = await this.request<{ data: Trace }>(`/tasks/${taskId}/trace`);
        if (result?.data) {
            this.cache.set(key, result.data, TRACE_TTL);
            return result.data;
        }
        return null;
    }

    async updateStatus(taskId: string, status: string, expectedStatus: string): Promise<boolean> {
        const result = await this.request(`/tasks/${taskId}/status`, "POST", {
            status, expected_status: expectedStatus,
        });
        if (result) {
            this.cache.invalidate(`task:${taskId}`);
            this.cache.invalidate(`trace:${taskId}`);
        }
        return !!result;
    }

    async linkCommit(taskId: string, sha: string): Promise<boolean> {
        const result = await this.request(`/tasks/${taskId}/links`, "POST", {
            kind: "commit", ref: sha,
        });
        if (result) {
            this.cache.invalidate(`task:${taskId}`);
            this.cache.invalidate(`trace:${taskId}`);
        }
        return !!result;
    }

    async linkBranch(taskId: string, branch: string): Promise<boolean> {
        const result = await this.request(`/tasks/${taskId}/links`, "POST", {
            kind: "branch", ref: branch,
        });
        return !!result;
    }

    async createTask(title: string, intent?: string, labels?: string[], priority?: string): Promise<Task | null> {
        const body: Record<string, unknown> = { title };
        if (intent) body.intent = intent;
        if (labels?.length) body.labels = labels;
        if (priority) body.priority = priority;

        const result = await this.request<{ data: Task }>("/tasks", "POST", body);
        return result?.data ?? null;
    }

    async getAudit(filters: Record<string, string> = {}): Promise<AuditEvent[]> {
        const qs = new URLSearchParams(filters).toString();
        const result = await this.request<{ data: AuditEvent[] }>(`/audit?${qs}`);
        return result?.data ?? [];
    }

    invalidateAll(): void {
        this.cache.clear();
    }

    private async request<T = unknown>(path: string, method = "GET", body?: unknown): Promise<T | null> {
        const url = `${this.baseUrl}${path}`;
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), TIMEOUT);

        this.log.appendLine(`${method} ${url}`);

        try {
            const opts: RequestInit = {
                method,
                headers: {
                    "Authorization": `Bearer ${this.config.token}`,
                    "Content-Type": "application/json",
                    "X-Actor": "vscode",
                },
                signal: controller.signal,
            };
            if (body) opts.body = JSON.stringify(body);

            const resp = await fetch(url, opts);
            if (!resp.ok) {
                const errBody = await resp.text().catch(() => "");
                this.log.appendLine(`  → ${resp.status} ${resp.statusText}: ${errBody}`);
                return null;
            }
            const data = await resp.json() as T;
            this.log.appendLine(`  → ${resp.status} OK`);
            return data;
        } catch (err) {
            this.log.appendLine(`  → ERROR: ${err}`);
            return null;
        } finally {
            clearTimeout(timer);
        }
    }
}
