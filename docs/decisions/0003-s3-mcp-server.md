# 0003: S3 MCP server for RustFS integration

Status: accepted

## Context

The package is intended to be an integration hub for the other AI-relevant apps on the same
Cloudron (see INTEGRATIONS.md and decision 0001). One of those apps is RustFS, which is
S3-compatible object storage. To let agents work with objects through the gateway, we need
an MCP server that exposes S3 operations as tools, configured as a stdio backend inside the
agentgateway container.

The choice was evaluated against four criteria, in priority order:

1. Cloudron fit, including how much extra tooling the package must add to the image, since
   the package already bundles `npx` and `uv`.
2. Development effort and institutional backing behind the project.
3. Future-proofing, including whether the project is locked to S3 alone.
4. Suitability for AI-assisted coding and debugging.

RustFS is young, so support for a custom S3 endpoint and path-style addressing is required,
and full S3 API parity cannot be assumed.

## Options considered

- **Apache OpenDAL MCP server (`mcp-server-opendal`).** Runs via `uvx`, so it needs no extra
  image tooling because `uv` is already bundled. Apache Software Foundation governance, which
  is the strongest backing and longevity of the field. Multi-backend (S3, GCS, Azure,
  filesystem, and more), so it is not locked to S3. Takes a custom S3 endpoint cleanly and is
  MinIO-friendly (region can be a placeholder). Limitation: it is oriented to list, read, and
  metadata operations, which fits retrieval and browsing but is not a full read-write surface.

- **`txn2/mcp-s3` (Go).** Designed S3-compatibility-first, with explicit `S3_ENDPOINT` and
  `S3_USE_PATH_STYLE`, full read and write, presigned URLs, and safety rails (read-only mode,
  size limits). Strong test and lint scaffolding (a Makefile with build, test, lint, verify).
  Cost: it is a Go binary, so the package must build or fetch it rather than reuse `uvx`.

- **`samuraikun/aws-s3-mcp` (TypeScript).** Runs via `npx`, supports stdio and HTTP
  transports, has a bucket allow-list and a health endpoint, and is tested against MinIO. A
  solo project, so weaker on the backing criterion.

- **AWS-published servers.** Rejected. `aws-samples/sample-mcp-server-s3` is an explicit
  sample (PDF only, limited to 1000 objects). The S3 Tables MCP server targets Apache Iceberg
  tables on AWS, not generic S3-compatible object storage.

## Decision

Use the **Apache OpenDAL MCP server** as the default S3 tool backend for RustFS. It is the
strongest fit on the stated priorities: zero extra image tooling, the best backing and
longevity, multi-backend future-proofing, and clean custom-endpoint support.

Document **`txn2/mcp-s3`** as the supported alternative for cases that require writing or
deleting objects or generating presigned URLs. When that path is chosen, the package must add
a build or fetch step for the Go binary.

Both are captured in `config/examples/rustfs-s3-mcp.yaml`, with OpenDAL as the active
configuration and txn2 as a commented alternative block.

## Consequences

- The default integration adds no new runtime to the image; it reuses the bundled `uv`.
- Retrieval and browsing of RustFS objects work out of the box. Write-heavy agent workflows
  require switching to the txn2 alternative, which is a documented, contained change.
- Secrets (RustFS access keys) are referenced as `$VAR` and kept in the environment, never in
  the config file, consistent with the secrets handling in INTEGRATIONS.md.
- The exact OpenDAL environment variable names and the agentgateway stdio env-map
  interpolation behaviour must be verified against current upstream sources before release, as
  noted in the example file. This ADR records the choice, not a guarantee of the field names.
- If OpenDAL later adds a full read-write tool surface, revisit whether the txn2 alternative
  is still needed and update this record.
