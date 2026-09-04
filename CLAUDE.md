# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

This repo builds Podman containers for data catalog tools ([OpenMetadata](https://open-metadata.org/) and [DataHub](https://datahubproject.io/)) and compares their functionality and operability side by side. It is a hands-on evaluation lab, not a production deployment.

## Status

The repo currently contains only `README.md`. The directory layout below is the intended structure — most of these paths do not exist yet and will be created as work progresses.

## Planned architecture

```
compose/
├── openmetadata/   # Podman Compose definition for OpenMetadata
└── datahub/        # Podman Compose definition for DataHub
configs/            # per-tool configuration files
scripts/            # start/stop/data-loading helper scripts
examples/           # sample data and metadata definitions used for verification
docs/
└── comparison.md   # write-up comparing OpenMetadata and DataHub
```

Each tool gets its own isolated Compose stack under `compose/<tool>/` rather than a single shared stack — this keeps the two tools' services, networks, and volumes from colliding when comparing them side by side.

## Commands

Requires Podman and `podman-compose` (or Podman's compose-compatible command).

```sh
# start a tool's stack
cd compose/openmetadata && podman-compose up -d
cd compose/datahub && podman-compose up -d

# stop a tool's stack
podman-compose down   # run from within the same compose/<tool>/ directory
```

There is no build, lint, or test tooling in this repo — it orchestrates existing container images rather than building application code.

## Working conventions

- Findings from comparing the tools belong in `docs/comparison.md`, not scattered across other docs.
- Keep OpenMetadata- and DataHub-specific configs/scripts under their own subdirectory rather than a shared one, matching the Compose split above.
- Logical units of work in this repo look like: "add OpenMetadata compose stack", "add DataHub compose stack", "write comparison doc" — one `jj` change each (see global VCS conventions for the general rule).
