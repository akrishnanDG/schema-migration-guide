# Migration via srctl

Use `srctl` for migrating schemas between Schema Registry instances -- whether
crossing SR versions, migrating to Confluent Cloud, or needing selective control
over which subjects to migrate.

`srctl` handles dependency ordering, ID preservation, IMPORT/READWRITE mode
transitions, and error recovery automatically.

### Installation

```bash
go install github.com/akrishnanDG/srctl@latest

# Or download a prebuilt binary:
# https://github.com/akrishnanDG/srctl/releases
```

---

## srctl clone

`srctl clone` is the primary migration command. It performs a live,
registry-to-registry copy in a single step.

```bash
srctl clone \
  --url http://source-sr:8081 \
  --target-url https://target-sr.confluent.cloud \
  --target-username <API_KEY> \
  --target-password <API_SECRET> \
  --workers 100
```

Useful flags:

| Flag | Purpose |
|---|---|
| `--workers N` | Parallel registration (default 1; use 100 for large registries) |
| `--dry-run` | Preview without making changes |
| `--subjects "pattern.*"` | Include only matching subjects |
| `--exclude-subjects "internal.*"` | Exclude matching subjects |
| `--skip-mode-switch` | Skip automatic IMPORT/READWRITE toggle |

### Other srctl commands

**export + import** -- Use `srctl export` and `srctl import` when the source and
target registries cannot communicate directly (air-gapped environments). Export
produces a portable archive that can be transferred to the target network before
importing.

```bash
# Phase 1 -- export from source
srctl export --url http://source-sr:8081 --output schemas.tar.gz --workers 100

# Phase 2 -- import to target
srctl import \
  --url https://target-sr.confluent.cloud \
  --username <API_KEY> --password <API_SECRET> \
  --input schemas.tar.gz \
  --workers 100
```

**backup + restore** -- Use `srctl backup` and `srctl restore` for disaster
recovery. Backup captures everything -- schemas, configs, modes, and tags -- so
you can restore a registry to a known good state.

```bash
# Backup
srctl backup --url http://source-sr:8081 --output full-backup.tar.gz --workers 100

# Restore
srctl restore \
  --url https://target-sr.confluent.cloud \
  --username <API_KEY> --password <API_SECRET> \
  --input full-backup.tar.gz \
  --preserve-ids \
  --workers 100
```

Additional flags: `--restore-configs`, `--restore-modes`.

---

<a id="continuous-replication-with-srctl-replicate"></a>

## Continuous Replication with `srctl replicate`

For migrations that require continuous sync -- where schemas are still being registered on the source during the migration window -- use `srctl replicate` instead of `srctl clone`.

`srctl replicate` is a long-running process that consumes the source cluster's `_schemas` Kafka topic and applies every change to the target in real-time. It works with **any source** (CP Community, CP Enterprise, or self-managed) -- no Enterprise license required.

### When to use `replicate` vs `clone`

| Scenario | Use |
|---|---|
| Simple migration, can freeze schema registrations during cutover | `srctl clone` |
| Schemas are still being registered on the source during migration | `srctl replicate` |
| Gradual client rollout over days/weeks | `srctl replicate` |
| Source is CP Community and you need continuous sync (Schema Exporter is CP Enterprise only) | `srctl replicate` |
| Air-gapped environment (no Kafka access from migration host) | `srctl clone` or `export/import` |

### Setup

Configure both registries in `~/.srctl/srctl.yaml`, including Kafka connection details for the source:

```yaml
registries:
  - name: on-prem
    url: http://source-sr:8081
    kafka:
      brokers:
        - broker1:9092
        - broker2:9092
      sasl:
        mechanism: PLAIN
        username: kafka-user
        password: kafka-pass
      tls:
        enabled: true

  - name: ccloud
    url: https://psrc-xxxxx.confluent.cloud
    username: <API_KEY>
    password: <API_SECRET>
    context: .migrated    # Optional: replicate into a specific context
```

### Start replication

```bash
# Basic (Kafka config from srctl.yaml)
srctl replicate --source on-prem --target ccloud

# With explicit Kafka brokers
srctl replicate --source on-prem --target ccloud \
  --kafka-brokers broker1:9092,broker2:9092

# With subject filtering (only replicate matching subjects)
srctl replicate --source on-prem --target ccloud --filter "user-*"

# With Prometheus monitoring
srctl replicate --source on-prem --target ccloud --metrics-port 9090
```

On first run, the replicator performs a full initial sync (equivalent to `srctl clone`), then switches to streaming mode for real-time replication. On subsequent runs with `--no-initial-sync`, it resumes from the last committed Kafka consumer group offset.

### What gets replicated

| Source event | Target action |
|---|---|
| New schema version | Registered on target |
| Schema deletion | Deleted on target |
| Compatibility config change | Applied (global and subject-level) |
| Subject mode change | Applied (subject-level only) |

### Monitoring

**CLI status** -- Periodic one-line status printed to terminal (configurable with `--status-interval`):

```
[15:42:14] on-prem -> ccloud | schemas=142 configs=8 deletes=2 errors=0 events=1523 filtered=45 offset=1568 uptime=2h15m
```

**Prometheus metrics** -- Enable with `--metrics-port`. Key metrics for alerting:

| Metric | Alert on |
|---|---|
| `srctl_replicate_errors_total` | Rate > 0 for 5+ minutes |
| `srctl_replicate_events_processed_total` | No change for 10+ minutes (stalled) |
| `srctl_replicate_uptime_seconds` | Drops to 0 (replicator down) |

### Retry and resilience

- Events retry up to 10 times with exponential backoff (1s → 30s cap)
- Offsets are only committed when the entire batch succeeds
- On restart, uncommitted events are replayed automatically
- Network errors and 5xx responses are retried; client errors (400, 422) fail immediately

### Cutover from continuous replication

1. **Verify replication is caught up** -- Check the CLI status or Prometheus metrics. The offset should be stable with no errors.
2. **Set the source to READONLY**:
   ```bash
   srctl mode set READONLY --global --url http://source-sr:8081
   ```
3. **Wait for the replicator to drain** -- The replicator will process the READONLY mode event and any remaining schemas.
4. **Validate**:
   ```bash
   srctl compare \
     --url http://source-sr:8081 \
     --target-url https://psrc-xxxxx.confluent.cloud \
     --target-username <API_KEY> --target-password <API_SECRET> \
     --workers 100
   ```
5. **Stop the replicator** -- Send SIGINT (Ctrl+C). It prints a final stats table and exits cleanly.
6. **Update client configurations** to point at the target registry.
7. **Keep the source in READONLY for 72+ hours** as a rollback window.

### Running in production

For long-running production deployments, run the replicator as a systemd service, Docker container, or Kubernetes Deployment. See the [srctl continuous replication guide](https://github.com/akrishnanDG/srctl/blob/main/docs/continuous-replication-guide.md) for systemd, Docker, and Kubernetes deployment examples, Prometheus alert rules, and Grafana dashboard queries.

---

## One-Time Migration with `srctl clone`

The full migration flow using `srctl clone`:

### 1. Clone schemas to the destination

Run `srctl clone`. The command automatically:

- Sets the destination registry to **IMPORT** mode.
- Clones all schemas in dependency order with their original IDs preserved.
- Sets the destination registry back to **READWRITE** mode.

```bash
srctl clone \
  --url http://source-sr:8081 \
  --target-url https://target-sr.confluent.cloud \
  --target-username <API_KEY> \
  --target-password <API_SECRET> \
  --workers 100
```

### 2. Set the source registry to READONLY

After the clone completes, set the source registry to READONLY to prevent
further schema changes while you cut over clients:

```bash
srctl mode set READONLY --global --url http://source-sr:8081 --workers 100
```

### 3. Point CI/CD and schema-registering clients to the new registry

Update any CI/CD pipelines, schema registration scripts, or applications that
register new schemas so they target the new registry. This ensures all new schema
changes go to the destination from this point forward.

### 4. Update consumer and producer configs

Reconfigure consumers and producers to read from the new registry. Because
schema IDs are preserved, serialized messages continue to deserialize correctly
against the same IDs on the destination.

---

## Preserving Schema IDs

ID preservation is critical: serialized Kafka messages embed the schema ID, and
consumers use it to fetch the correct schema. If IDs drift, deserialization
breaks.

`srctl clone` and `srctl restore --preserve-ids` handle this automatically by
placing the target in IMPORT mode, registering schemas with their original IDs,
and restoring READWRITE mode when finished. Use `--dry-run` to detect ID
conflicts before making changes.

---

## Confluent Cloud Specifics

**Authentication.** Confluent Cloud supports two authentication methods:

- **API keys.** Create a Schema Registry API key (`confluent api-key create
  --resource <SR_CLUSTER_ID>`) and pass it via `--username` / `--password` (or
  `--target-username` / `--target-password` for `clone`).
- **OAuth.** Configure OAuth tokens via `--bearer-token` or
  `--target-bearer-token`.

**Endpoint URL.** Your SR endpoint follows the pattern
`https://psrc-XXXXX.region.aws.confluent.cloud`. Find it in the Cloud Console or
via `confluent schema-registry cluster describe`.

**Rate limits.** Confluent Cloud enforces API rate limits. `srctl` retries
automatically with backoff on HTTP 429 responses. Use `--workers 100` by default;
reduce to `--workers 5` if you encounter persistent rate limiting (HTTP 429).

**IMPORT mode permissions.** Your API key must have the **ResourceOwner** role
binding on the SR cluster to toggle IMPORT mode. Standard DeveloperRead/Write
roles are not sufficient.

---

## Using the REST API Directly

If you cannot install `srctl`, the same migration can be performed using `curl`
and `jq` against the Schema Registry REST API. The process involves exporting
subjects and configs, setting the target to IMPORT mode, registering schemas with
preserved IDs in dependency order, and restoring READWRITE mode. See
[Appendix](08-appendix.md) for endpoint
details and example requests.

---

## Next Steps

Proceed to [Post-Migration Validation](06-post-migration-validation.md) to
verify schemas, IDs, configurations, and modes on the target.
