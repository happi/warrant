# Change Ledger — Data Model

## Entity Relationship

```
Organization 1──* Project 1──* Task 1──* ArtifactLink
                         │           1──* AuditEvent
                         │           0──1 Lease
                         │
Organization 1──* User ──* AuditEvent (as actor)
```

## Tables

### organizations

| Column       | Type    | Constraints          | Description                    |
|-------------|---------|----------------------|--------------------------------|
| id          | TEXT    | PK                   | UUID                           |
| name        | TEXT    | NOT NULL, UNIQUE     | Display name                   |
| slug        | TEXT    | NOT NULL, UNIQUE     | URL-safe identifier            |
| created_at  | TEXT    | NOT NULL             | ISO 8601 timestamp             |

### users

| Column       | Type    | Constraints          | Description                    |
|-------------|---------|----------------------|--------------------------------|
| id          | TEXT    | PK                   | UUID                           |
| org_id      | TEXT    | FK → organizations   | Owning organization            |
| username    | TEXT    | NOT NULL             | Unique within org              |
| role        | TEXT    | NOT NULL             | `admin` or `developer`         |
| api_token   | TEXT    | UNIQUE               | Bearer token (hashed)          |
| created_at  | TEXT    | NOT NULL             | ISO 8601 timestamp             |

UNIQUE(org_id, username)

### projects

| Column       | Type    | Constraints          | Description                    |
|-------------|---------|----------------------|--------------------------------|
| id          | TEXT    | PK                   | UUID                           |
| org_id      | TEXT    | FK → organizations   | Owning organization            |
| name        | TEXT    | NOT NULL             | Display name                   |
| slug        | TEXT    | NOT NULL             | URL-safe identifier            |
| prefix      | TEXT    | NOT NULL             | Task ID prefix (e.g., `SF`)    |
| created_at  | TEXT    | NOT NULL             | ISO 8601 timestamp             |

UNIQUE(org_id, slug)
UNIQUE(org_id, prefix)

### tasks

| Column          | Type    | Constraints          | Description                        |
|----------------|---------|----------------------|------------------------------------|
| id             | TEXT    | PK                   | e.g., `SF-42`                      |
| project_id     | TEXT    | FK → projects        | Owning project                     |
| org_id         | TEXT    | FK → organizations   | Denormalized for query efficiency  |
| title          | TEXT    | NOT NULL             | Short description                  |
| intent         | TEXT    |                      | Why this task exists               |
| status         | TEXT    | NOT NULL             | Current status (see state machine) |
| priority       | TEXT    |                      | `low`, `medium`, `high`, `critical`|
| created_by     | TEXT    | FK → users           | Who created it                     |
| assigned_to    | TEXT    |                      | Username or agent ID               |
| created_at     | TEXT    | NOT NULL             | ISO 8601 timestamp                 |
| updated_at     | TEXT    | NOT NULL             | ISO 8601 timestamp                 |

INDEX on (org_id, project_id, status)

### task_labels

| Column       | Type    | Constraints          | Description                    |
|-------------|---------|----------------------|--------------------------------|
| task_id     | TEXT    | FK → tasks           | Task reference                 |
| label       | TEXT    | NOT NULL             | Label string                   |

PK(task_id, label)

### leases

| Column       | Type    | Constraints          | Description                    |
|-------------|---------|----------------------|--------------------------------|
| task_id     | TEXT    | PK, FK → tasks       | One lease per task             |
| owner       | TEXT    | NOT NULL             | Agent or user claiming the task|
| acquired_at | TEXT    | NOT NULL             | ISO 8601 timestamp             |
| expires_at  | TEXT    | NOT NULL             | ISO 8601 timestamp             |

### artifact_links

| Column       | Type    | Constraints          | Description                    |
|-------------|---------|----------------------|--------------------------------|
| id          | INTEGER | PK AUTOINCREMENT     | Row ID                         |
| task_id     | TEXT    | FK → tasks           | Linked task                    |
| kind        | TEXT    | NOT NULL             | `branch`, `commit`, `pr`       |
| ref         | TEXT    | NOT NULL             | Branch name, SHA, or PR number |
| url         | TEXT    |                      | Optional link (e.g., GitHub URL)|
| created_at  | TEXT    | NOT NULL             | ISO 8601 timestamp             |
| created_by  | TEXT    |                      | Who added the link             |

UNIQUE(task_id, kind, ref)

### audit_events

| Column       | Type    | Constraints          | Description                    |
|-------------|---------|----------------------|--------------------------------|
| id          | INTEGER | PK AUTOINCREMENT     | Monotonic event ID             |
| org_id      | TEXT    | NOT NULL             | Organization scope             |
| project_id  | TEXT    |                      | Project scope (if applicable)  |
| task_id     | TEXT    |                      | Task scope (if applicable)     |
| event_type  | TEXT    | NOT NULL             | See event types below          |
| actor       | TEXT    | NOT NULL             | User or agent performing action|
| detail      | TEXT    |                      | JSON payload with event data   |
| timestamp   | TEXT    | NOT NULL             | ISO 8601 timestamp             |

INDEX on (org_id, task_id)
INDEX on (org_id, timestamp)

### Event Types

| Event Type          | Detail Fields                           |
|--------------------|-----------------------------------------|
| `task.created`     | `{title, intent, status}`               |
| `task.status`      | `{from, to}`                            |
| `task.updated`     | `{fields: {field: {from, to}, ...}}`    |
| `lease.acquired`   | `{owner, expires_at}`                   |
| `lease.released`   | `{owner}`                               |
| `lease.expired`    | `{owner}`                               |
| `link.added`       | `{kind, ref}`                           |

## Task Status State Machine

```
          ┌──────────┐
          │   open   │ ← initial state
          └────┬─────┘
               │
          ┌────▼─────┐
          │ in_progress│
          └────┬─────┘
               │
          ┌────▼─────┐
          │ in_review │
          └────┬─────┘
               │
          ┌────▼─────┐
          │   done   │
          └──────────┘

  Any state → blocked (and back to previous)
  Any state → cancelled (terminal)
```

Valid transitions:

| From          | To                                    |
|---------------|---------------------------------------|
| `open`        | `in_progress`, `blocked`, `cancelled` |
| `in_progress` | `in_review`, `blocked`, `cancelled`   |
| `in_review`   | `done`, `in_progress`, `cancelled`    |
| `blocked`     | `open`, `in_progress`, `cancelled`    |
| `done`        | (terminal — no transitions)           |
| `cancelled`   | (terminal — no transitions)           |

## Tenant Isolation

Every query that touches task data includes `org_id` in its WHERE clause. The API path structure (`/orgs/:org/projects/:proj/...`) ensures tenant context is always present.

The `org_id` column is denormalized on `tasks` (in addition to the `project_id → org_id` relationship) to allow efficient queries without joins for the common case.

No cross-organization queries exist in the API. Admin endpoints for the service itself are separate and protected.
