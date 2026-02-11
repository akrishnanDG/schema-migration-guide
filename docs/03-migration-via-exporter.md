# Migration via Schema Exporter

## Overview

The **Schema Exporter** is a built-in feature of Confluent Platform Schema Registry (7.x and later) that continuously replicates schemas from a source Schema Registry to a target Schema Registry. Unlike one-time migration approaches such as `srctl clone` or manual REST API calls, the Exporter maintains a live, ongoing synchronization between the two registries until you explicitly disable it.

**When to use Schema Exporter:**

- Your source Schema Registry is running **Confluent Platform 7.x or later**.
- You need **continuous synchronization** between source and target during a migration window (for example, when you cannot freeze schema changes during cutover).
- You want a **built-in, operationally simple** mechanism that does not require external tooling or scripts.
- You are migrating between two **self-managed Confluent Platform** Schema Registry clusters.

**When NOT to use Schema Exporter:**

- Your source is a community (open-source) Schema Registry that does not include the Exporter feature.
- You need a one-time bulk migration with no ongoing sync -- consider [Migration via REST API](04-migration-via-api.md) or `srctl clone` instead.
- You are migrating from a non-Confluent registry (AWS Glue, Apicurio).

For an alternative migration approach that works with any Schema Registry (including community editions), see [Migration via REST API](04-migration-via-api.md).

---

## Prerequisites and Limitations

### Prerequisites

| Requirement | Details |
|-------------|---------|
| Source SR version | Confluent Platform **7.0.0 or later** (Schema Exporter was introduced in CP 7.0) |
| Target SR version | Any Confluent Schema Registry that supports the `/mode` endpoint (CP 5.4+) |
| Network connectivity | The **source** Schema Registry must be able to reach the **target** Schema Registry over HTTP(S) |
| Authentication credentials | If either registry uses authentication (basic auth, mTLS, OAuth), you must have valid credentials configured |
| Admin permissions | You need admin-level access on **both** registries: to create/manage exporters on the source, and to set import mode on the target |

### Limitations

1. **Cannot export directly to Confluent Cloud.** The Schema Exporter is designed for self-managed-to-self-managed replication. If your target is Confluent Cloud Schema Registry, you can chain the approach: export to an intermediate self-managed SR, then use `srctl clone` or the REST API to push schemas into Confluent Cloud.

2. **One-directional only.** The Exporter replicates schemas from source to target. It does not support bidirectional sync or conflict resolution.

3. **Subject-level filtering is limited.** You can filter by schema context (context prefix), but you cannot cherry-pick individual subjects within a context for export.

4. **Schema IDs may differ.** The target registry assigns its own schema IDs during import. If your applications rely on hard-coded schema IDs, you will need to account for this during cutover. (See [Post-Migration Validation](06-post-migration-validation.md) for ID mapping guidance.)

5. **Exporter runs on the source cluster.** The Exporter is a process within the source Schema Registry. If the source becomes unavailable, replication stops.

6. **Requires IMPORT mode on the target.** The target Schema Registry must be placed into IMPORT mode before the Exporter can write to it. While in IMPORT mode, the target will reject direct schema registrations from clients.

---

## Step-by-Step Migration

### Step 1: Set the Target Schema Registry to IMPORT Mode

Before the Exporter can write schemas to the target, the target must be placed into **IMPORT** mode. In IMPORT mode, the target registry accepts schemas only from an exporter (or via the import API) and rejects normal client registrations.

Using `srctl`:

```bash
srctl mode set IMPORT --global --url http://target-sr:8081
```

Using `curl`:

```bash
curl -X PUT -H "Content-Type: application/json" \
  --data '{"mode": "IMPORT"}' \
  http://target-sr:8081/mode
```

If the target uses basic authentication:

```bash
curl -X PUT -H "Content-Type: application/json" \
  -u '<api-key>:<api-secret>' \
  --data '{"mode": "IMPORT"}' \
  http://target-sr:8081/mode
```

**Verify the mode was set:**

```bash
curl -s http://target-sr:8081/mode | jq .
```

Expected response:

```json
{
  "mode": "IMPORT"
}
```

> **Important:** While the target is in IMPORT mode, any producer or consumer applications pointed at the target will be unable to register new schemas. Plan this step during a maintenance window or before any clients are pointed at the target.

---

### Step 2: Configure the Exporter on the Source Schema Registry

You can configure the exporter in two ways: via the Schema Registry properties file (static configuration) or via the REST API (dynamic configuration). The REST API approach is preferred because it does not require restarting the source Schema Registry.

#### Option A: REST API Configuration (Recommended)

No changes to `schema-registry.properties` are required. You will create the exporter entirely through the REST API in Step 3.

#### Option B: Properties File Configuration

Add the following to the source Schema Registry's `schema-registry.properties` file and restart the service:

```properties
# Enable the exporter feature (enabled by default in CP 7.x+)
schema.registry.exporter.enable=true
```

In most CP 7.x+ installations, the exporter feature is already enabled. You only need to add this property if it was explicitly disabled.

---

### Step 3: Create the Exporter

Use the REST API on the **source** Schema Registry to create an exporter. The exporter definition includes the name, the target Schema Registry connection details, and optional context/subject configuration.

**Create an exporter using a PUT request:**

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

**Parameter reference for the exporter creation payload:**

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | A unique name for this exporter instance |
| `contextType` | No | How to handle schema contexts. Values: `AUTO` (default), `CUSTOM`, `NONE`. See [Handling Schema Contexts with Exporter](#handling-schema-contexts-with-exporter) below |
| `context` | No | Custom context string (only used when `contextType` is `CUSTOM`) |
| `subjects` | No | List of subject name patterns to export. Defaults to `["*"]` (all subjects) |
| `config` | Yes | Map of configuration properties for connecting to the target SR |

**If the target Schema Registry uses basic authentication:**

```bash
curl -X PUT -H "Content-Type: application/json" \
  --data '{
    "name": "migration-exporter",
    "contextType": "AUTO",
    "subjects": ["*"],
    "config": {
      "schema.registry.url": "http://target-sr:8081",
      "basic.auth.credentials.source": "USER_INFO",
      "basic.auth.user.info": "<api-key>:<api-secret>"
    }
  }' \
  http://source-sr:8081/exporters
```

**If the target Schema Registry uses TLS/mTLS:**

```bash
curl -X PUT -H "Content-Type: application/json" \
  --data '{
    "name": "migration-exporter",
    "contextType": "AUTO",
    "subjects": ["*"],
    "config": {
      "schema.registry.url": "https://target-sr:8081",
      "schema.registry.ssl.truststore.location": "/path/to/truststore.jks",
      "schema.registry.ssl.truststore.password": "<truststore-password>",
      "schema.registry.ssl.keystore.location": "/path/to/keystore.jks",
      "schema.registry.ssl.keystore.password": "<keystore-password>",
      "schema.registry.ssl.key.password": "<key-password>"
    }
  }' \
  http://source-sr:8081/exporters
```

Once created, the exporter begins replicating schemas immediately.

---

### Step 4: Monitor Exporter Status

After creating the exporter, monitor its status to ensure schemas are being replicated successfully.

**Check exporter status:**

```bash
curl -s http://source-sr:8081/exporters/migration-exporter/status | jq .
```

Example response:

```json
{
  "name": "migration-exporter",
  "state": "RUNNING",
  "offset": 42,
  "ts": 1700000000000,
  "trace": ""
}
```

**Exporter states:**

| State | Meaning |
|-------|---------|
| `STARTING` | The exporter is initializing |
| `RUNNING` | The exporter is actively replicating schemas |
| `PAUSED` | The exporter has been manually paused |
| `ERROR` | The exporter encountered an error (check the `trace` field for details) |

**List all exporters:**

```bash
curl -s http://source-sr:8081/exporters | jq .
```

**Get exporter configuration:**

```bash
curl -s http://source-sr:8081/exporters/migration-exporter/config | jq .
```

If the exporter enters an `ERROR` state, inspect the `trace` field in the status response and check the source Schema Registry logs for details. Common issues include network connectivity problems, authentication failures, or the target not being in IMPORT mode.

---

### Step 5: Validate Schema Sync

Once the exporter has been running and the offset has stabilized (no longer incrementing), all schemas from the source have been replicated. Validate the sync using `srctl compare`:

```bash
srctl compare \
  --url http://source-sr:8081 \
  --target-url http://target-sr:8081
```

This command compares all subjects and schema versions between the source and target, reporting any discrepancies. You should see output confirming that all subjects and versions match.

You can also perform a quick manual count check:

```bash
# Count subjects on source
echo "Source subjects:"
curl -s http://source-sr:8081/subjects | jq 'length'

# Count subjects on target
echo "Target subjects:"
curl -s http://target-sr:8081/subjects | jq 'length'
```

For comprehensive validation procedures, see [Post-Migration Validation](06-post-migration-validation.md).

---

### Step 6: Cut Over Clients to the Target Schema Registry

Once validation confirms that all schemas are in sync:

1. **Stop schema-producing workloads** (or accept that any new schemas registered after the cutover check will need to be handled).
2. **Perform a final validation** to confirm no new schemas were registered during the cutover window.
3. **Reconfigure client applications** to point to the target Schema Registry URL.
4. **Restart clients** with the new configuration.

Client configuration change (example for a Kafka producer):

```properties
# Before (source)
schema.registry.url=http://source-sr:8081

# After (target)
schema.registry.url=http://target-sr:8081
```

If you are using `srctl` to manage client configurations, update the `--url` flag accordingly.

---

### Step 7: Disable the Exporter and Reset Target Mode

After all clients have been successfully migrated to the target:

**Pause the exporter:**

```bash
curl -X PUT http://source-sr:8081/exporters/migration-exporter/pause
```

**Delete the exporter (once you are confident the migration is complete):**

```bash
curl -X DELETE http://source-sr:8081/exporters/migration-exporter
```

**Set the target Schema Registry back to READWRITE mode:**

Using `srctl`:

```bash
srctl mode set READWRITE --global --url http://target-sr:8081
```

Using `curl`:

```bash
curl -X PUT -H "Content-Type: application/json" \
  --data '{"mode": "READWRITE"}' \
  http://target-sr:8081/mode
```

**Verify the mode change:**

```bash
curl -s http://target-sr:8081/mode | jq .
```

Expected response:

```json
{
  "mode": "READWRITE"
}
```

> **Important:** Do not set the target back to READWRITE mode until you have confirmed that all clients are pointing to the target and that no further replication from the source is needed.

---

## Exporter Configuration Reference

The following properties can be specified in the `config` map when creating or updating an exporter via the REST API.

### Target Connection Properties

| Property | Required | Description |
|----------|----------|-------------|
| `schema.registry.url` | Yes | URL of the target Schema Registry (e.g., `http://target-sr:8081`) |
| `basic.auth.credentials.source` | No | Credentials source for basic auth. Set to `USER_INFO` when using `basic.auth.user.info` |
| `basic.auth.user.info` | No | Basic auth credentials in `<username>:<password>` format |
| `bearer.auth.credentials.source` | No | Bearer auth credentials source |
| `bearer.auth.token` | No | Bearer token for authentication |

### TLS/SSL Properties

| Property | Required | Description |
|----------|----------|-------------|
| `schema.registry.ssl.truststore.location` | No | Path to the truststore file (JKS or PKCS12) |
| `schema.registry.ssl.truststore.password` | No | Password for the truststore |
| `schema.registry.ssl.truststore.type` | No | Truststore type (`JKS` or `PKCS12`). Defaults to `JKS` |
| `schema.registry.ssl.keystore.location` | No | Path to the keystore file (for mTLS) |
| `schema.registry.ssl.keystore.password` | No | Password for the keystore |
| `schema.registry.ssl.keystore.type` | No | Keystore type (`JKS` or `PKCS12`). Defaults to `JKS` |
| `schema.registry.ssl.key.password` | No | Password for the private key in the keystore |

### Exporter Behavior Properties

| Property | Required | Description |
|----------|----------|-------------|
| `schema.registry.exporter.poll.interval.ms` | No | How frequently the exporter checks for new schemas to replicate (in milliseconds). Default: `5000` |
| `schema.registry.exporter.batch.size` | No | Number of schemas to export in a single batch. Default: `1000` |

### Exporter REST API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/exporters` | List all exporters |
| `PUT` | `/exporters` | Create a new exporter |
| `GET` | `/exporters/{name}` | Get exporter details |
| `PUT` | `/exporters/{name}` | Update exporter configuration |
| `DELETE` | `/exporters/{name}` | Delete an exporter |
| `GET` | `/exporters/{name}/status` | Get exporter status (state, offset, errors) |
| `PUT` | `/exporters/{name}/pause` | Pause an exporter |
| `PUT` | `/exporters/{name}/resume` | Resume a paused exporter |
| `PUT` | `/exporters/{name}/reset` | Reset exporter offset (re-export from the beginning) |
| `GET` | `/exporters/{name}/config` | Get exporter configuration |
| `PUT` | `/exporters/{name}/config` | Update exporter configuration without recreating |

---

## Handling Schema Contexts with Exporter

Schema contexts allow you to organize subjects into logical namespaces within a single Schema Registry. The context appears as a prefix in the form `:.context-name:` before the subject name. When using the Exporter, you have three options for how contexts are handled.

### Context Types

| `contextType` | Behavior |
|----------------|----------|
| `AUTO` | Subjects are exported with their original context preserved. If the source subject is `:.production:user-value`, it will appear as `:.production:user-value` on the target. Subjects in the default context remain in the default context. |
| `CUSTOM` | All exported subjects are placed under a custom context that you specify in the `context` field. For example, if you set `context` to `:.migrated:`, a source subject `user-value` becomes `:.migrated:user-value` on the target. |
| `NONE` | All subjects are exported into the default context on the target, stripping any context prefix from the source. |

### Examples

**Export with original contexts preserved (AUTO):**

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

**Export all subjects into a custom context (CUSTOM):**

```bash
curl -X PUT -H "Content-Type: application/json" \
  --data '{
    "name": "migration-exporter",
    "contextType": "CUSTOM",
    "context": ":.from-cluster-a:",
    "subjects": ["*"],
    "config": {
      "schema.registry.url": "http://target-sr:8081"
    }
  }' \
  http://source-sr:8081/exporters
```

This is particularly useful when consolidating multiple source Schema Registries into a single target. Each source can export into its own context to avoid subject name collisions. For more on multi-SR consolidation strategies, see [Multiple SRs and Contexts](05-multi-sr-and-contexts.md).

**Export all subjects into the default context (NONE):**

```bash
curl -X PUT -H "Content-Type: application/json" \
  --data '{
    "name": "migration-exporter",
    "contextType": "NONE",
    "subjects": ["*"],
    "config": {
      "schema.registry.url": "http://target-sr:8081"
    }
  }' \
  http://source-sr:8081/exporters
```

### Subject Filtering with Contexts

You can combine context handling with subject filtering. The `subjects` field accepts a list of subject name patterns:

```bash
curl -X PUT -H "Content-Type: application/json" \
  --data '{
    "name": "migration-exporter",
    "contextType": "AUTO",
    "subjects": ["user-*", "order-*"],
    "config": {
      "schema.registry.url": "http://target-sr:8081"
    }
  }' \
  http://source-sr:8081/exporters
```

This exports only subjects whose names match `user-*` or `order-*`.

---

## Monitoring and Alerting During Export

### Polling the Exporter Status

The simplest monitoring approach is to periodically poll the exporter status endpoint:

```bash
# Poll every 10 seconds and log the state
while true; do
  STATUS=$(curl -s http://source-sr:8081/exporters/migration-exporter/status)
  STATE=$(echo "$STATUS" | jq -r '.state')
  OFFSET=$(echo "$STATUS" | jq -r '.offset')
  TRACE=$(echo "$STATUS" | jq -r '.trace')

  echo "[$(date)] State: $STATE | Offset: $OFFSET"

  if [ "$STATE" = "ERROR" ]; then
    echo "[$(date)] ERROR detected: $TRACE"
    # Send alert (e.g., via PagerDuty, Slack webhook, email)
  fi

  sleep 10
done
```

### Key Indicators to Monitor

| Indicator | What to Watch |
|-----------|---------------|
| **Exporter state** | Should remain `RUNNING`. Any transition to `ERROR` requires investigation. |
| **Offset progression** | The `offset` value should increment as schemas are replicated. Once it stabilizes, the exporter has caught up with the source. |
| **Error trace** | The `trace` field in the status response contains the stack trace or error message when the exporter is in an `ERROR` state. |
| **Target subject count** | Periodically compare the subject count between source and target to confirm convergence. |

### JMX Metrics

If your Schema Registry exposes JMX metrics, the following MBeans are relevant to exporter monitoring:

| MBean | Description |
|-------|-------------|
| `kafka.schema.registry:type=SchemaRegistryExporter,name=<exporter-name>` | Exporter-specific metrics including replication lag, error counts, and throughput |

To enable JMX on the Schema Registry, add the following to your startup configuration:

```bash
export SCHEMA_REGISTRY_JMX_OPTS="-Dcom.sun.management.jmxremote \
  -Dcom.sun.management.jmxremote.port=9999 \
  -Dcom.sun.management.jmxremote.authenticate=false \
  -Dcom.sun.management.jmxremote.ssl=false"
```

You can then connect a JMX client (JConsole, Prometheus JMX Exporter, Datadog, etc.) to port 9999 to scrape these metrics.

### Alerting Recommendations

| Condition | Severity | Action |
|-----------|----------|--------|
| Exporter state transitions to `ERROR` | Critical | Investigate immediately. Check `trace` field and SR logs. |
| Exporter offset has not changed in > 5 minutes while source is active | Warning | May indicate the exporter is stalled. Check network connectivity and target availability. |
| Subject count mismatch between source and target persists after offset stabilizes | Warning | Run `srctl compare` to identify specific discrepancies. |

---

## Rollback Procedure

If the migration encounters issues after clients have been partially or fully cut over to the target, follow this procedure to revert.

### Scenario 1: Exporter Is Still Running, No Clients Moved Yet

This is the simplest case. Simply stop and clean up:

```bash
# Pause the exporter
curl -X PUT http://source-sr:8081/exporters/migration-exporter/pause

# Delete the exporter
curl -X DELETE http://source-sr:8081/exporters/migration-exporter

# Reset the target back to READWRITE (or leave it; it has no active clients)
curl -X PUT -H "Content-Type: application/json" \
  --data '{"mode": "READWRITE"}' \
  http://target-sr:8081/mode
```

No client changes are needed because no clients were pointed at the target.

### Scenario 2: Some Clients Have Been Moved to the Target

1. **Point affected clients back to the source Schema Registry.** Update configuration and restart:

   ```properties
   # Revert to source
   schema.registry.url=http://source-sr:8081
   ```

2. **Leave the exporter running** (if it is still active) until all clients are confirmed back on the source.

3. **Pause and delete the exporter:**

   ```bash
   curl -X PUT http://source-sr:8081/exporters/migration-exporter/pause
   curl -X DELETE http://source-sr:8081/exporters/migration-exporter
   ```

4. **Reset the target to READWRITE mode** (or decommission it):

   ```bash
   curl -X PUT -H "Content-Type: application/json" \
     --data '{"mode": "READWRITE"}' \
     http://target-sr:8081/mode
   ```

### Scenario 3: All Clients Have Been Moved, Issues Found on Target

If all clients are on the target and you discover data issues:

1. **Assess whether the issue is with missing schemas or incorrect schemas.** Run:

   ```bash
   srctl compare \
     --url http://source-sr:8081 \
     --target-url http://target-sr:8081
   ```

2. **If schemas are missing**, you can re-create the exporter and let it re-sync, or manually register the missing schemas using the REST API (see [Migration via REST API](04-migration-via-api.md)).

3. **If a full rollback is needed**, point all clients back to the source:

   ```properties
   schema.registry.url=http://source-sr:8081
   ```

4. **Investigate and fix** the root cause before attempting the migration again.

### Post-Rollback Cleanup

After a successful rollback:

- Confirm all clients are operating normally against the source.
- Delete the exporter if it is still configured.
- Optionally, soft-delete or hard-delete subjects on the target to clean up the partial migration.
- Document the failure reason and update your migration plan before retrying.

---

## Next Steps

- For an alternative migration approach that works without the Exporter feature, see [Migration via REST API](04-migration-via-api.md).
- After completing the migration, follow [Post-Migration Validation](06-post-migration-validation.md) to verify schema integrity, reconfigure clients, and finalize the cutover.
- If you are consolidating multiple Schema Registries, see [Multiple SRs and Contexts](05-multi-sr-and-contexts.md) for context-based consolidation strategies.
