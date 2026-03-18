---
id: W-1
title: Initial release of Warrant
status: Done
priority: high
labels:
  - meta
assignee: []
created_date: '2026-03-18 18:00'
updated_date: '2026-03-18 18:00'
dependencies: []
---

## Description

Consolidate backlog-server, change-ledger-client, and vscode-change-ledger into a single monorepo under the name **Warrant**.

## Decision

Single repo over three separate repos — the client and server share an API contract and version together. The VS Code extension also shares types with the client. One repo, one README, one set of docs. Customers point submodules at `client/` only.

## Intent

Ship the first unified release of Warrant as a coherent product, not three loosely connected tools.
