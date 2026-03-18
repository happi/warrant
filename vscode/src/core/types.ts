export interface Task {
    id: string;
    title: string;
    intent: string | null;
    status: TaskStatus;
    priority: "low" | "medium" | "high" | "critical" | null;
    labels: string[];
    created_by: string;
    assigned_to: string | null;
    created_at: string;
    updated_at: string;
    lease: Lease | null;
    links: ArtifactLink[];
}

export type TaskStatus = "open" | "in_progress" | "in_review" | "done" | "blocked" | "cancelled";

export interface Lease {
    owner: string;
    acquired_at: string;
    expires_at: string;
}

export interface ArtifactLink {
    id: number;
    kind: "branch" | "commit" | "pr";
    ref: string;
    url: string | null;
    created_at: string;
}

export interface AuditEvent {
    id: number;
    event_type: string;
    actor: string;
    timestamp: string;
    task_id?: string;
    project_id?: string;
    detail?: Record<string, unknown>;
}

export interface Trace {
    task: Pick<Task, "id" | "title" | "intent" | "status" | "priority" | "assigned_to" | "created_by" | "created_at" | "updated_at">;
    links: {
        branches: (string | { ref: string; url?: string })[];
        commits: (string | { ref: string; url?: string })[];
        prs: (string | { ref: string; url?: string })[];
    };
    audit: AuditEvent[];
}

export interface TaskSummary {
    id: string;
    title: string;
    status: TaskStatus;
    priority: string | null;
    assigned_to: string | null;
    updated_at: string;
    labels: string[];
}

export interface LedgerConfig {
    url: string;
    org: string;
    project: string;
    token: string;
    prefix: string;
}

/** Common interface for anything that can look up tasks */
export interface TaskLookup {
    getTask(taskId: string): Promise<Task | null>;
    listTasks(): Promise<TaskSummary[]>;
    getTrace(taskId: string): Promise<Trace | null>;
}
