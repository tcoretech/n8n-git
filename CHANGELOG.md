# Changelog

All notable changes to n8n Git will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.3] - 2026-04-19

### Added
-  add GitLab support and generic git configuration options
-  allow "latest" install tag on version

### Fixed
-  remove redundant 'fi' causing syntax error in interactive.sh
-  allow passing of specific versions for install

### Maintenance
- release): bump version to 1.2.3

### Other Changes
- test: replace docker exec jq with piping cat to jq on host to fix exit code 127 in push-test
- test: add missing id fields to test workflows to satisfy n8n NOT NULL constraint
- test: remove output redirection to debug test-push.sh failures

## [1.2.2] - 2026-01-07

### Added
-  add bootstrap test job to CI and update Makefile; enhance test-bootstrap.sh permissions
-  enable parallel organisation and upload during pull commands, implement folder caching and fix minor issues with reset

### Fixed
-  folder structure interleaving during import and issues with importing active workflows
-  shellcheck fixes and update / version management variable bug fixes

### Maintenance
- release): bump version to 1.2.2

## [1.2.1] - 2026-01-05

### Fixed
-  skip uncommitted changes check when using temporary clone in reset scripts
-  address folder path resolution and clearer error messaging in reset scripts
-  improve exit code handling and add temp file cleanup

### Maintenance
- release): bump version to 1.2.1

## [1.2.0] - 2026-01-05

### Added
-  add version check and self-update capability (#4)

### Maintenance
- release): bump version to 1.2.0

## [1.1.0] - 2025-12-27

### Maintenance
- release): bump version to 1.1.0

### Other Changes
- Feat: Enable inside n8n container execution and bootstrapping of n8n-git for use within n8n nodes (#3)
- Apply consistent formatting to Pull and Reset examples with use case descriptions
- Update README: split push examples with justifications and add cron backup example
- Initial plan

## [1.0.0] - 2025-12-02

### Initial Release

- **Core**: Initial public release of `n8n-git`, a CLI tool to sync n8n workflows with Git.
- **Push**: Export workflows, credentials, and environment variables from n8n to Git or local storage.
- **Pull**: Import workflows and credentials from Git/local storage to n8n, preserving folder structures.
- **Reset**: Time-travel functionality to restore n8n state to a specific Git commit, tag, or time window.
- **Folder Support**: Full support for n8n project and folder hierarchy synchronization.
- **Interactive CLI**:
  - Configuration wizard (`n8n-git config`).
  - Interactive reset picker with date grouping and filtering.
- **Authentication**: Session-based authentication handling for n8n API access.
- **Documentation**: Comprehensive guides for [Architecture](docs/ARCHITECTURE.md), [Push](docs/push.md), [Pull](docs/pull.md), and [Reset](docs/reset.md) operations.
