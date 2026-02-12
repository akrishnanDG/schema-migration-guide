# Migration via Schema Exporter (CP Enterprise -> Cloud)

## Overview

Schema Exporter is a built-in feature of Confluent Platform Enterprise that
provides continuous, real-time replication of schemas from an on-premises Schema
Registry to a remote target such as Confluent Cloud.

> **Before you begin:** Run through the pre-migration assessment in
> [02-pre-migration-assessment.md](02-pre-migration-assessment.md) to identify
> potential blockers (incompatible schema types, ID collisions, context
> conflicts) before starting the exporter.

- **Use when** your source is CP Enterprise (requires an Enterprise license --
  this feature is not available in CP Community or open-source Schema Registry)
  and you are migrating to Confluent Cloud Schema Registry.
- **NOT available** when the source is CP Community or open-source Schema
  Registry. If your source is CP Community, use `srctl clone` instead (see
  [Migration via srctl](04-migration-via-api.md)).
- For one-time bulk migrations from CP Enterprise, `srctl clone` also works.
  Schema Exporter is preferred when you need continuous sync during a longer
  cutover window.

## Prerequisites

| Requirement | Details |
|---|---|
| Source | CP Enterprise with a valid Enterprise license |
| Target | Confluent Cloud Schema Registry |
| Cloud API key | Service account with **ResourceOwner** role on the SR cluster |
| Network | Source CP must be able to reach Cloud SR over HTTPS (port 443) |

## Step-by-Step

### 1. Set Cloud SR to IMPORT mode

The target must be in IMPORT mode before it will accept externally-written schemas.

```bash
srctl mode set IMPORT --global \
  --url https://psrc-XXXXX.confluent.cloud \
  --username <API_KEY> --password <API_SECRET> \
  --workers 100
```

### 2. Create the exporter on the source CP Enterprise SR

The exporter API is a CP Enterprise REST endpoint, so use `curl` directly
against the source Schema Registry.

To export all schemas across all contexts, use `:.*:` as the subject pattern:

```bash
curl -X PUT -H "Content-Type: application/json" \
  --data '{
    "name": "cloud-migration",
    "contextType": "AUTO",
    "subjects": [":.*:"],
    "config": {
      "schema.registry.url": "https://psrc-XXXXX.confluent.cloud",
      "basic.auth.credentials.source": "USER_INFO",
      "basic.auth.user.info": "<API_KEY>:<API_SECRET>"
    }
  }' \
  http://source-cp-sr:8081/exporters
```

- `subjects: [":.*:"]` exports every subject across all contexts. Replace
  with a specific list (e.g., `["my-topic-value"]`) to export only a subset,
  or use `["*"]` if you only need subjects in the default context.
- `contextType: AUTO` maps subjects one-to-one (no prefix added on the target).

### 3. Monitor exporter status

```bash
curl -s http://source-cp-sr:8081/exporters/cloud-migration/status | jq .
```

Possible states:

| State | Meaning |
|---|---|
| STARTING | Exporter is initializing |
| RUNNING | Actively replicating; check the offset to confirm it is caught up |
| PAUSED | Manually paused |
| ERROR | Something went wrong; inspect the `trace` field for details |

When the reported offset stabilizes and no new schemas are being registered on
the source, the exporter has caught up.

### 4. Set source to READONLY

Once schemas are fully synced and the exporter has caught up, set the source
registry to READONLY to prevent further schema changes during cutover:

```bash
srctl mode set READONLY --global \
  --url http://source-cp-sr:8081 \
  --workers 100
```

### 5. Validate with srctl compare

```bash
srctl compare \
  --url http://source-cp-sr:8081 \
  --target-url https://psrc-XXXXX.confluent.cloud \
  --target-username <API_KEY> --target-password <API_SECRET> \
  --workers 100
```

This reports any subjects or versions present on one side but missing on the
other. A clean comparison means you are ready to cut over.

### 6. Cut over clients

Update every producer and consumer to point at Cloud SR:

- Change `schema.registry.url` to `https://psrc-XXXXX.confluent.cloud`.
- Set `basic.auth.credentials.source=USER_INFO` and supply the API key/secret.
- Deploy and verify that applications are producing and consuming normally.

### 7. Clean up

```bash
# Pause the exporter
curl -X PUT http://source-cp-sr:8081/exporters/cloud-migration/pause

# Once you are confident the migration is complete, delete it
curl -X DELETE http://source-cp-sr:8081/exporters/cloud-migration

# Set Cloud SR back to READWRITE mode
srctl mode set READWRITE --global \
  --url https://psrc-XXXXX.confluent.cloud \
  --username <API_KEY> --password <API_SECRET> \
  --workers 100
```

## Using Schema Contexts

If the Cloud SR already contains schemas, subject names from the source may
collide with existing subjects. Use a custom context to namespace them.

In the exporter configuration, set `contextType` to `CUSTOM` and provide a
context name:

```json
{
  "contextType": "CUSTOM",
  "context": ":.from-onprem:",
  "subjects": [":.*:"],
  "config": { "..." }
}
```

All exported subjects will be prefixed with `:.from-onprem:` on Cloud (for
example, `:.from-onprem:my-topic-value`). This keeps them isolated from any
pre-existing subjects in the default context.

## Rollback

If you need to revert, set the source back to READWRITE and point clients back
to the source CP Enterprise Schema Registry. As long as the exporter is still
running, both registries contain the same schemas, so rollback is
straightforward with no data loss. After confirming that all clients are back on
the source, pause and then delete the exporter.
