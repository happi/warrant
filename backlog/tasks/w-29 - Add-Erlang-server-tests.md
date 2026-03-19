---
id: W-29
title: Add Erlang server tests
status: Done
assignee: []
created_date: '2026-03-19 14:50'
updated_date: '2026-03-19 14:52'
labels:
  - server
  - testing
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The server has zero automated tests. CI compiles but does not verify behavior. Add EUnit tests for core modules: warrant_canonical, warrant_object, warrant_merge, status CAS logic, hash chain computation, lease expiry. Test at the module level, not through HTTP.
<!-- SECTION:DESCRIPTION:END -->
