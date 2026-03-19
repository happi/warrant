---
id: W-31
title: Add npm/brew package for CLI
status: To Do
assignee: []
created_date: '2026-03-19 14:50'
labels:
  - client
  - packaging
dependencies: []
priority: low
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Installing the CLI requires cloning the repo or downloading a tarball. Start with npm since the CLI is bash (no compilation). Wrap in a thin npm package that copies scripts to the bin path. Homebrew tap later if there is demand.
<!-- SECTION:DESCRIPTION:END -->
