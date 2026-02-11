# Migration via Schema Exporter

## Overview

The **Schema Exporter** is a built-in Confluent Platform feature (7.x+) that continuously replicates schemas from a source Schema Registry to a target. Unlike one-time approaches (`srctl clone`, REST API), it maintains live synchronization until explicitly disabled.

**Use when:** your source is CP 7.x+, you need continuous sync during a migration window, and both clusters are self-managed Confluent Platform.

**Do not use when:** your source is community/open-source SR, you only need a one-time bulk copy, or you are migrating from a non-Confluent registry. See [Migration via REST API](04-migration-via-api.md) instead.

---

## Prerequisites and Limitations

| Requirement | Details |
|-------------|---------|
| Source SR | Confluent Platform **7.0.0+** |
| Target SR | Any Confluent SR supporting `/mode` endpoint (CP 5.4+) |
| Network | Source must reach target over HTTP(S) |
| Credentials | Valid auth credentials for both registries if auth is enabled |
| Permissions | Admin access on both registries |

**Key limitations:**

- Cannot export directly to Confluent Cloud (chain through an intermediate self-managed SR).
- One-directional only; no bidirectional sync.
- Subject filtering is by pattern, not individual subject cherry-picking.
- Schema IDs may differ on the target. See [Post-Migration Validation](06-post-migration-validation.md).
- Exporter runs on the source; if the source goes down, replication stops.
- Target must be in IMPORT mode, which blocks direct client registrations.

---

## Step-by-Step Migration

### Step 1: Set Target to IMPORT Mode

```bash
srctl mode set IMPORT --global --url http://target-sr:8081
```

Verify:

```bash
srctl mode get --global --url http://target-sr:8081
```

> **Note:** While in IMPORT mode, the target rejects direct schema registrations from clients.

### Step 2: Configure the Exporter on the Source

The exporter feature is enabled by default in CP 7.x+. No properties file changes are needed -- you create the exporter entirely via the REST API in Step 3.

### Step 3: Create the Exporter

```bash
curl -X PUT -H "Content-Type: application/json" \
  --data '{
    "name": "migration-exporter",
    "contextType": "AUTO",
    "subjects": ["*"],
    "config": {
      "schema.registry.url": "http://target-sr:8081"
    }
  }' \
  http://source-sr:8081/exporters
```

If the target requires **basic auth**, add to the `config` map:

```json
"basic.auth.credentials.source": "USER_INFO",
"basic.auth.user.info": "<api-key>:<api-secret>"
```

If the target requires **mTLS**, add to the `config` map:

```json
"schema.registry.ssl.truststore.location": "/path/to/truststore.jks",
"schema.registry.ssl.truststore.password": "<password>",
"schema.registry.ssl.keystore.location": "/path/to/keystore.jks",
"schema.registry.ssl.keystore.password": "<password>",
"schema.registry.ssl.key.password": "<password>"
```

The exporter begins replicating immediately after creation.

### Step 4: Monitor Exporter Status

```bash
curl -s http://source-sr:8081/exporters/migration-exporter/status | jq .
```

| State | Meaning |
|-------|---------|
| `STARTING` | Initializing |
| `RUNNING` | Actively replicating |
| `PAUSED` | Manually paused |
| `ERROR` | Failed -- check the `trace` field for details |

The `offset` value increments as schemas replicate. Once it stabilizes, the exporter has caught up.

### Step 5: Validate Schema Sync

```bash
srctl compare \
  --url http://source-sr:8081 \
  --target-url http://target-sr:8081
```

For comprehensive validation, see [Post-Migration Validation](06-post-migration-validation.md).

### Step 6: Cut Over Clients

1. Stop schema-producing workloads (or accept a brief gap).
2. Run a final `srctl compare` to confirm sync.
3. Reconfigure clients to point to the target SR URL.
4. Restart clients.

```properties
# Update client config
schema.registry.url=http://target-sr:8081
```

### Step 7: Disable Exporter and Reset Target Mode

Pause and delete the exporter:

```bash
curl -X PUT http://source-sr:8081/exporters/migration-exporter/pause
curl -X DELETE http://source-sr:8081/exporters/migration-exporter
```

Set the target back to READWRITE:

```bash
srctl mode set READWRITE --global --url http://target-sr:8081
```

> **Important:** Do not reset to READWRITE until all clients are confirmed on the target.

---

## Exporter Configuration Reference

### Essential Config Properties

| Property | Description |
|----------|-------------|
| `schema.registry.url` | **(Required)** Target SR URL |
| `basic.auth.credentials.source` | Set to `USER_INFO` for basic auth |
| `basic.auth.user.info` | `<username>:<password>` |
| `schema.registry.ssl.truststore.location` | Truststore path (JKS/PKCS12) |
| `schema.registry.ssl.keystore.location` | Keystore path for mTLS |

### Key REST API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| `PUT` | `/exporters` | Create exporter |
| `GET` | `/exporters/{name}/status` | Get status |
| `PUT` | `/exporters/{name}/pause` | Pause exporter |
| `PUT` | `/exporters/{name}/resume` | Resume exporter |
| `PUT` | `/exporters/{name}/reset` | Reset offset (re-export from beginning) |
| `DELETE` | `/exporters/{name}` | Delete exporter |

---

## Handling Schema Contexts

Schema contexts organize subjects into namespaces with a `:.context-name:` prefix. The `contextType` field controls how contexts are mapped during export:

| `contextType` | Behavior |
|---------------|----------|
| `AUTO` | Preserves original contexts. Default. |
| `CUSTOM` | Places all exported subjects under a context you specify in the `context` field. Useful when consolidating multiple SRs (see [Multiple SRs and Contexts](05-multi-sr-and-contexts.md)). |
| `NONE` | Strips context prefixes; all subjects land in the default context. |

You can combine context handling with subject pattern filtering via the `subjects` field (e.g., `["user-*", "order-*"]`).

---

## Rollback

**If no clients have moved yet:** pause and delete the exporter, then reset the target mode.

```bash
curl -X PUT http://source-sr:8081/exporters/migration-exporter/pause
curl -X DELETE http://source-sr:8081/exporters/migration-exporter
srctl mode set READWRITE --global --url http://target-sr:8081
```

**If some or all clients have moved:** revert client configs to the source SR URL, restart clients, then clean up the exporter and target mode as above. If schemas are missing on the target, re-run the exporter or manually register them via the [REST API](04-migration-via-api.md).

After rollback, confirm all clients operate normally against the source and document the failure before retrying.

---

## Next Steps

- Alternative approach without the Exporter: [Migration via REST API](04-migration-via-api.md)
- Verify schema integrity after migration: [Post-Migration Validation](06-post-migration-validation.md)
- Consolidating multiple registries: [Multiple SRs and Contexts](05-multi-sr-and-contexts.md)
