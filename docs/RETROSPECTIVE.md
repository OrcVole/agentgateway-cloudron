# Retrospective: Packaging agentgateway for Cloudron

## Summary

We packaged agentgateway v1.3.1 as a community Cloudron app, validated it end to end on a live Cloudron box, and prepared it for public release as version 1.0.0 of the package. The work divided into six phases: aligning the original brief with reality, empirical grounding on the actual binary and base image, building the packaging artifacts, installing and smoke testing on the box, documentation and branding, and a publish-readiness pass. This document records what went smoothly, what took time, what helped, and how each integration behaved, so that the next packaging effort starts ahead of where this one did.

## What agentgateway is, in packaging terms

It ships as a single dynamically linked binary with the web UI embedded, which is close to ideal for packaging. The binary links only libc, libm, and libgcc_s, so the runtime surface is small. The only persistent state is a YAML configuration file, which keeps updates low risk and removes any storage migration concern at the data level. On Cloudron base 5.0.0 the binary runs natively, because the base provides glibc 2.39 and the binary requires exactly that version.

## What took time

The single largest recurring cost was the gap between the original brief and the live system. The brief was written against pre-release information, and by the time of the build several of its points were stale or simply wrong. The pinned version, the base image version, the admin bind mechanism, the multi-subdomain support, and the treatment of the OAuth proxy all needed correction against the running system. Reconciling each one was slow, but it prevented defects that would have surfaced only after install.

The admin bind address was the most instructive correction. The brief described it as an environment variable. In reality it is a configuration field, and its genuine default with an empty configuration is localhost. Because the admin UI rewrites the configuration file when a user saves settings, and because that rewrite can drop or alter fields, a single first-run seed of the bind address was not enough. We had to re-assert the bind address on every boot. A simple text edit was too fragile against the formatting the UI produces, so we added a YAML-aware tool to the image purely to make that re-assertion reliable. This was the one deviation from a minimal runtime, and it was forced by the confirmed localhost default rather than by convenience.

The proxy-auth scoping question could only be answered after install, because it is behavior applied by the platform reverse proxy according to the manifest, not behavior of the application. We had to declare the proxy-auth addon in the manifest before we could test it, because it cannot be added after first install, and then verify that it scoped only to the primary domain and did not extend across the data-plane subdomain. A casing detail also cost a failed validation: the packaging addon reference showed the proxy-auth key in lowercase, while the platform requires it in camelCase.

The reverse-proxy read timeout took real diagnosis. A long first call to a cold model was being severed at sixty seconds, and it was not obvious whether the limit belonged to the platform proxy or to the application. We ran the same call internally, bypassing the proxy, and it completed, while the external call was cut at the same sixty-second mark with the application logging a request that never received a status. That isolated the limit to the platform reverse-proxy read window, for which there is no per-app setting. We addressed it durably with a keep-alive on the inference backend and by preferring streaming responses, which keep bytes flowing and reset the read window.

The relationship between the data-plane completion route and the admin model registry was the last thing to understand. The admin dashboard, the cost view, and the virtual-models feature read a top-level model registry and a separate model catalog. The completion endpoint, by contrast, is served by a route backend and works even when that registry is empty. The visible result is a warning that the LLM configuration is not initialized, which appears even while the completion endpoint returns valid responses. Along the way we corrected an earlier belief that the top-level registry binds its own port; it does not, and it adds no extra listener.

A final time cost was verifying that the built image contained no secrets. A gitignore entry does not protect the Docker build context; only a dockerignore entry does. We had to confirm on the built image filesystem, not only in the repository, that no credential files were present. One scare turned out to be a false positive from reading a process environment rather than an image file.

## What helped

Verifying on the real box and the real binary, rather than trusting documentation or the brief, was decisive. Checking the binary against the base with the dynamic linker and a version flag, validating the configuration with the application's own validate-only mode, and inspecting the running container directly all caught issues that documentation alone would have hidden.

Pinning everything helped keep the work reproducible: the upstream image by digest, the base image by digest, the two added tools by checksum, and a single version variable that the manifest mirrors.

A defensive boot sequence protected user data. The sequence seeds a default only when no configuration exists, re-asserts the bind address, validates, runs a migration only when validation fails, re-validates, and fails loudly rather than silently overwriting a configuration that is merely incompatible. A visible failure is the correct outcome, because the platform surfaces it and the user can recover from a backup.

Shipping an inert default also helped. The default has the MCP demo active and the LLM route commented, so a fresh install boots with no environment variables set. This matters because the application refuses to start when its configuration references a variable that is not set.

## How the integrations went

MCP worked well. The demonstration server launches through a Node runner, the protocol handshake completes, and tools list and call correctly. Stdio backends launch local subprocesses and run on the read-only root filesystem by using the writable data directory as a cache. The first call to a freshly fetched server is slow while the runner downloads it.

The LLM path worked well, with one operational caveat. An OpenAI-compatible request to the data-plane endpoint returns a valid completion with token counts, and streaming returns response chunks. The caveat is cold-load time on a processor-only backend, which can exceed the proxy read window on the first call. Warming the model, setting a keep-alive, and preferring streaming resolve it.

A separate chat UI as a client was clean. A human-facing UI sitting behind single sign-on, making outbound calls to the open and key-protected data plane, is the intended topology and avoids putting the OAuth proxy in front of a programmatic client.

The one rough edge for users is the distinction between the completion route and the admin registry, and the resulting initialization warning on a fresh install. It is benign, and it is now documented.

## Testing performed

We validated, on a live box, the on-server build and install, the proxy-auth scoping in all three directions, the MCP handshake and tool call, the LLM round trip including streaming, configuration persistence across a restart, a cross-version update, the absence of secrets in the built image, and a full repository anonymity sweep, followed by the project conformance checklist.

The cross-version update installed a throwaway instance at the prior version, changed its configuration, and updated to the current version. The configuration survived and health stayed green. Because the two versions share the configuration schema, the migration ran as a no-op. This proves configuration survival across a real version change. It does not exercise the migration transformation itself, which remains unproven until a version with an actual schema change ships. That is recorded as a release gate.

## Versioning and forward compatibility

The package version 1.0.0 wraps upstream 1.3.1, and the two version lines move independently. Because the binary depends on an exact glibc version, a future upstream build on a newer toolchain could fail silently on an older base. We therefore made a dynamic-linker and version check against the target base a mandatory step on every version bump. Since the only persistent state is the YAML configuration, updates carry no data-level migration risk.

## The single biggest lesson

For packaging, empirical verification beats documentation. Every assumption carried from the brief or from a reference document, and not checked against the running system, needed correction at least once. That included a point in the official packaging reference itself.
