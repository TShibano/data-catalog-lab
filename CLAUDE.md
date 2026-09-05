# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

This repo builds Podman containers for data catalog tools ([OpenMetadata](https://open-metadata.org/) and [DataHub](https://datahubproject.io/)) and compares their functionality and operability side by side. It is a hands-on evaluation lab, not a production deployment.

## Status

The repo currently contains `README.md`, `CLAUDE.md`, and `plans/`. The directory layout below is the intended structure — most of these paths do not exist yet and will be created as work progresses. See `plans/001-container-setup.md` for the implementation plan.

## Planned architecture

The layout is tool-first: each tool owns a top-level directory holding its compose definition, configs, Containerfile, and scripts.

```
openmetadata/
├── compose.upstream.yml    # official compose, pinned version, committed as-is
├── compose.override.yml    # this repo's overrides (ports, volumes, memory)
├── Containerfile.ingestion # thin extension of the official image
├── configs/                # config files and ingestion definitions
└── scripts/                # up / down / logs / status / ingest
datahub/                    # same shape as openmetadata/
shared/
└── scripts/                # preflight checks, compose fetching, shared helpers
examples/                   # sample data, shared by both tools
docs/
└── comparison.md           # write-up comparing OpenMetadata and DataHub
plans/                      # implementation plans
```

Each tool gets its own isolated Compose stack rather than a single shared stack — this keeps the two tools' services, networks, and volumes from colliding when comparing them side by side.

Tool-first (rather than concern-first `compose/<tool>/`, `configs/<tool>/`) keeps each Containerfile's build context inside its own tool directory, so `COPY configs/ ...` works without widening the context to the repo root. It also means one logical unit of work maps to one directory subtree.

Compose owns stack startup; Containerfiles are extension layers (`FROM` the official image) for ingestion work only — never a hand-rolled replacement for the stack.

## Commands

Requires Podman and a compose provider (`podman compose`, which delegates to `podman-compose`).

```sh
# start / stop a tool's stack
./openmetadata/scripts/up.sh
./openmetadata/scripts/down.sh    # --purge also removes volumes

./datahub/scripts/up.sh
./datahub/scripts/down.sh
```

UIs: OpenMetadata on 8585, DataHub on 9002. The two stacks contend for ports (8080 / 9200 / 3306) and memory, so do not run them at the same time.

There is no build, lint, or test tooling in this repo — it orchestrates existing container images rather than building application code.

## Working conventions

- Findings from comparing the tools belong in `docs/comparison.md`, not scattered across other docs.
- Keep OpenMetadata- and DataHub-specific compose files, configs, and scripts inside that tool's top-level directory. Only genuinely shared things (`shared/scripts/`, `examples/`, `docs/`) live outside it.
- Logical units of work in this repo look like: "add OpenMetadata stack", "add DataHub stack", "write comparison doc" — one `jj` change each (see global VCS conventions for the general rule).
