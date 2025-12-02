# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
