# Change Ledger — API Reference

## Base URL

```
https://<host>/api/v1
```

Legacy endpoints (`/api/id/*`) remain at their current paths.

## Authentication

All v1 endpoints require a Bearer token in the `Authorization` header:

```
Authorization: Bearer <api_token>
```

The token identifies both the user and their organization. Requests without a valid token receive 401.

Requests to resources outside the user's organization receive 403.

## Common Response Format

### Success

```json
{
  "data": { ... }
}
```

### Error

```json
{
  "error": {
    "code": "conflict",
    "message": "Expected status 'open' but found 'in_progress'"
  }
}
```

### HTTP Status Codes

| Code | Meaning                                    |
|------|--------------------------------------------|
| 200  | Success                                    |
| 201  | Created                                    |
| 204  | Success, no content (DELETE)               |
| 400  | Bad request (missing fields, invalid data) |
| 401  | Missing or invalid token                   |
| 403  | Not authorized for this resource           |
| 404  | Resource not found                         |
| 409  | Conflict (state mismatch, lease held)      |
| 422  | Invalid state transition                   |

---

## Organizations

### Create Organization

```
POST /api/v1/orgs
```

```json
{
  "name": "Stenmans Homelab",
  "slug": "stenmans"
}
```

Response (201):

```json
{
  "data": {
    "id": "uuid",
    "name": "Stenmans Homelab",
    "slug": "stenmans",
    "created_at": "2026-03-18T10:00:00Z"
  }
}
```

### Get Organization

```
GET /api/v1/orgs/:org_slug
```

---

## Projects

### Create Project

```
POST /api/v1/orgs/:org_slug/projects
```

```json
{
  "name": "Solar Frontiers",
  "slug": "solar-frontiers",
  "prefix": "SF"
}
```

Response (201):

```json
{
  "data": {
    "id": "uuid",
    "name": "Solar Frontiers",
    "slug": "solar-frontiers",
    "prefix": "SF",
    "created_at": "2026-03-18T10:00:00Z"
  }
}
```

### List Projects

```
GET /api/v1/orgs/:org_slug/projects
```

---

## Tasks

### Create Task

```
POST /api/v1/orgs/:org_slug/projects/:project_slug/tasks
```

```json
{
  "title": "Add OAuth authentication",
  "intent": "Users need to log in via Google OAuth to access the dashboard",
  "priority": "high",
  "labels": ["feature", "auth"]
}
```

Response (201):

```json
{
  "data": {
    "id": "SF-42",
    "title": "Add OAuth authentication",
    "intent": "Users need to log in via Google OAuth to access the dashboard",
    "status": "open",
    "priority": "high",
    "labels": ["feature", "auth"],
    "created_by": "erik",
    "assigned_to": null,
    "created_at": "2026-03-18T10:00:00Z",
    "updated_at": "2026-03-18T10:00:00Z",
    "lease": null,
    "links": []
  }
}
```

The `id` is allocated by the ID counter service using the project's prefix. It is globally unique within the project.

### Get Task

```
GET /api/v1/orgs/:org_slug/projects/:project_slug/tasks/:task_id
```

Returns the full task with lease and links included.

### List Tasks

```
GET /api/v1/orgs/:org_slug/projects/:project_slug/tasks
```

Query parameters:

| Param      | Type   | Description                |
|------------|--------|----------------------------|
| status     | string | Filter by status           |
| assigned_to| string | Filter by assignee         |
| label      | string | Filter by label            |
| limit      | int    | Max results (default 100)  |
| offset     | int    | Pagination offset          |

### Update Task Status

```
POST /api/v1/orgs/:org_slug/projects/:project_slug/tasks/:task_id/status
```

```json
{
  "status": "in_progress",
  "expected_status": "open"
}
```

Response (200):

```json
{
  "data": {
    "id": "SF-42",
    "status": "in_progress",
    "previous_status": "open",
    "updated_at": "2026-03-18T10:30:00Z"
  }
}
```

If `expected_status` doesn't match current status → 409 Conflict.
If transition is invalid (e.g., `done` → `open`) → 422 Unprocessable.

### Update Task Fields

```
PATCH /api/v1/orgs/:org_slug/projects/:project_slug/tasks/:task_id
```

```json
{
  "title": "Add OAuth + SAML authentication",
  "assigned_to": "agent-4",
  "intent": "Updated: also need SAML for enterprise customers"
}
```

Only provided fields are updated. Status changes must go through the `/status` endpoint.

---

## Leases

### Acquire Lease

```
POST /api/v1/orgs/:org_slug/projects/:project_slug/tasks/:task_id/lease
```

```json
{
  "owner": "sf-agent-4",
  "ttl_seconds": 3600
}
```

Response (200):

```json
{
  "data": {
    "task_id": "SF-42",
    "owner": "sf-agent-4",
    "acquired_at": "2026-03-18T10:30:00Z",
    "expires_at": "2026-03-18T11:30:00Z"
  }
}
```

If already leased by another owner → 409 Conflict.
If leased by the same owner → lease is renewed with new TTL.

### Release Lease

```
DELETE /api/v1/orgs/:org_slug/projects/:project_slug/tasks/:task_id/lease
```

```json
{
  "owner": "sf-agent-4"
}
```

Response: 204 No Content.

Only the lease owner can release it. Wrong owner → 403.

---

## Artifact Links

### Add Link

```
POST /api/v1/orgs/:org_slug/projects/:project_slug/tasks/:task_id/links
```

```json
{
  "kind": "commit",
  "ref": "abc123def456",
  "url": "https://github.com/org/repo/commit/abc123def456"
}
```

Response (201):

```json
{
  "data": {
    "id": 1,
    "task_id": "SF-42",
    "kind": "commit",
    "ref": "abc123def456",
    "url": "https://github.com/org/repo/commit/abc123def456",
    "created_at": "2026-03-18T10:30:00Z"
  }
}
```

Valid `kind` values: `branch`, `commit`, `pr`.

### List Links

```
GET /api/v1/orgs/:org_slug/projects/:project_slug/tasks/:task_id/links
```

---

## Trace

### Get Task Trace

```
GET /api/v1/orgs/:org_slug/projects/:project_slug/tasks/:task_id/trace
```

Response (200):

```json
{
  "data": {
    "task": {
      "id": "SF-42",
      "title": "Add OAuth authentication",
      "intent": "Users need to log in via Google OAuth",
      "status": "done"
    },
    "links": {
      "branches": ["task/SF-42-add-auth"],
      "commits": [
        {"ref": "abc123", "url": "..."},
        {"ref": "def456", "url": "..."}
      ],
      "prs": [
        {"ref": "17", "url": "..."}
      ]
    },
    "audit": [
      {"event_type": "task.created", "actor": "erik", "timestamp": "..."},
      {"event_type": "task.status", "actor": "erik", "detail": {"from": "open", "to": "in_progress"}, "timestamp": "..."}
    ]
  }
}
```

This is the primary traceability endpoint — it assembles the full picture.

---

## Audit Events

### List Audit Events

```
GET /api/v1/orgs/:org_slug/projects/:project_slug/audit
```

Query parameters:

| Param    | Type   | Description                  |
|----------|--------|------------------------------|
| task_id  | string | Filter to specific task      |
| since    | string | ISO 8601 lower bound         |
| until    | string | ISO 8601 upper bound         |
| limit    | int    | Max results (default 100)    |
| offset   | int    | Pagination offset            |

Audit events are append-only. There is no update or delete endpoint.

---

## Legacy Endpoints (preserved)

These remain unchanged for backward compatibility:

```
POST /api/id/next        — {"prefix": "sf"} → {"id": "SF-42", "number": 42}
GET  /api/id/counters    — {"counters": {"sf": 42, ...}}
POST /api/id/sync        — {"prefix": "sf", "value": 50} → {"ok": true}
```

No authentication required on legacy endpoints (matches current behavior).

---

## Users

### Create User

```
POST /api/v1/orgs/:org_slug/users
```

```json
{
  "username": "erik",
  "role": "admin"
}
```

Response (201):

```json
{
  "data": {
    "id": "uuid",
    "username": "erik",
    "role": "admin",
    "api_token": "cl_live_xxxxxxxxxxxxx",
    "created_at": "2026-03-18T10:00:00Z"
  }
}
```

The `api_token` is returned only on creation. It cannot be retrieved later — only regenerated.

### Regenerate Token

```
POST /api/v1/orgs/:org_slug/users/:username/token
```

Response (200): returns new `api_token`, invalidates old one.
