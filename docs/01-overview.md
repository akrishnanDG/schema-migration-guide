# Migration Overview

This guide covers migrating from the **Community (open-source) Schema Registry** to **Confluent Platform SR** (self-managed) or **Confluent Cloud SR** (fully managed), and migrating from **CP Enterprise SR** to **Confluent Cloud SR** using Schema Exporter. It includes tooling options, planning, validation, and cutover procedures.

> **Terminology:** This guide distinguishes between **CP Community** (the open-source/community-licensed Schema Registry, freely available) and **CP Enterprise** (requires an enterprise license, includes features like Schema Exporter). When the guide says "Confluent Platform," it refers to the enterprise-licensed distribution unless otherwise noted.

---

## Why Migrate

The Community Schema Registry serves basic needs but lacks the capabilities organizations require as Kafka deployments mature.

- **Broker-side schema validation** -- Confluent enforces validation at the broker, preventing malformed data from reaching topics.
- **RBAC** -- Fine-grained, resource-level access control for subjects and schemas (absent in CP Community).
- **Schema Linking** -- Continuous, automated schema replication across CP Enterprise registries.
- **Tags, Data Contracts, Metadata** -- Data quality rules and tagging in Confluent Cloud.
- **Enterprise support** -- SLA-backed support, JMX metrics, health checks, and managed upgrades.
- **Security** -- mTLS and OAuth/SSO for on-prem CP Enterprise; OAuth/SSO and audit logging for Confluent Cloud.
- **Confluent Cloud** -- Fully managed, 99.99% SLA, Stream Governance, pay-as-you-go pricing.

---

## Migration Paths

### Path 1: CP Community SR to CP Enterprise SR (Self-Managed)

| Aspect | Details |
|---|---|
| **Deployment** | Your infrastructure (VMs, Kubernetes, bare metal) |
| **Best for** | On-prem requirements (regulatory, latency, operational) |
| **Tooling** | `srctl clone` (recommended) |
| **ID Preservation** | Handled automatically by `srctl clone` |

### Path 2: CP Community SR to Confluent Cloud SR (Managed)

| Aspect | Details |
|---|---|
| **Deployment** | Fully managed by Confluent |
| **Best for** | Reducing operational overhead; cloud-native Kafka adoption |
| **Tooling** | `srctl clone` (recommended) |
| **ID Preservation** | Handled automatically by `srctl clone` |

### Path 3: CP Enterprise SR to Confluent Cloud SR

| Aspect | Details |
|---|---|
| **Deployment** | Fully managed by Confluent |
| **Best for** | Migrating from CP Enterprise to Cloud |
| **Tooling** | Schema Exporter (continuous sync), `srctl clone` (one-time copy) |
| **ID Preservation** | Supported by both Schema Exporter and `srctl clone` |

---

<a id="decision-tree"></a>

## Decision Tree

```
START
  |
  v
[Is your source CP Enterprise?]
  |                       |
  Yes                     No (CP Community)
  |                       |
  v                       v
[Use Schema Exporter    [Single source SR,
 for continuous sync     or multiple?]
 to Cloud, or srctl       |              |
 clone for one-time       Single       Multiple
 copy]                    |              |
                          v              v
                        [Use srctl     [Consolidating into
                         clone]         a single target?]
                                         |         |
                                         Yes       No
                                         |         |
                                         v         v
                                        Use       Migrate each
                                        srctl     independently
                                        clone     (single-source
                                        with       flow per SR)
                                        --context
```

`srctl clone` is the recommended approach for all CP Community migration scenarios. It handles dependency ordering, ID preservation, and mode transitions automatically.

### srctl clone

[`srctl`](https://github.com/akrishnanDG/srctl) is a Go CLI tool purpose-built for Schema Registry migrations. It clones schemas from source to destination with automatic dependency ordering and ID preservation.

**Use when:** migrating to Cloud or CP Enterprise, consolidating multiple registries, or when you need a reliable one-time migration. Works with all targets and SR versions.

**Key capabilities:** topological sorting of dependencies, schema ID preservation, automatic IMPORT mode handling on the destination, Avro/Protobuf/JSON Schema support, dry-run mode.

```bash
# Clone all schemas from CP Community SR to Confluent Cloud
srctl clone \
  --url http://community-sr:8081 \
  --target-url https://psrc-XXXXX.region.aws.confluent.cloud \
  --target-username <CLOUD_API_KEY> \
  --target-password <CLOUD_API_SECRET> \
  --workers 100
```

> **Note:** `srctl clone` automatically sets the destination to IMPORT mode before copying and restores it to READWRITE after. For manual migrations (e.g., using the REST API directly), you must set the destination to IMPORT mode before copying schemas and switch it to READWRITE after the copy is complete.

For air-gapped environments where the migration host cannot reach both registries simultaneously, `srctl export` + `srctl import` provides a two-phase alternative (export to disk, transfer files, then import). For full state replication including configs, modes, and tags, `srctl backup` + `srctl restore` is available. See [Migration via srctl](04-migration-via-api.md) for details on these alternatives.

### Schema Exporter (CP Enterprise to Cloud)

Available when the source is CP Enterprise. Provides continuous schema replication to another CP Enterprise instance or to Confluent Cloud. See [Migration via Schema Exporter](03-migration-via-exporter.md).

---

## Migration Phases

Every migration follows five phases. Skipping a phase increases risk.

### Phase 1: Assess

Inventory subjects, schema versions, IDs, types, references, compatibility settings, and all producers/consumers that interact with the registry. See [Pre-Migration Assessment](02-pre-migration-assessment.md).

### Phase 2: Plan

Select your approach using the [decision tree](#decision-tree), plan for schema ID preservation (Schema IDs MUST be preserved to avoid deserialization errors on existing messages), define success criteria and rollback procedures, and schedule the cutover window.

### Phase 3: Migrate

Run `srctl clone` against a staging environment first, then execute against production. Always include `--workers 100` for speed. Capture logs for audit and troubleshooting. See [Migration via srctl](04-migration-via-api.md).

### Phase 4: Validate

Compare subject counts, schema content (hash comparison), schema IDs, and compatibility levels between source and target. Run integration tests with representative producers and consumers. See [Post-Migration Validation](06-post-migration-validation.md).

### Phase 5: Cutover

After a one-time copy with `srctl clone`, cutover is straightforward:

1. **Set source to READONLY** -- prevents further schema registrations on the old registry.
2. **Set destination to READWRITE** -- `srctl clone` does this automatically, but verify the mode is correct.
3. **Update client configurations** -- point all producers, consumers, Connect workers, ksqlDB, and Kafka Streams applications to the new registry URL and credentials.
4. **Monitor** -- watch for errors in both registries for 48-72 hours. Keep the source in READONLY as a rollback safety net; if issues arise, revert client configs to point back to the source.

See [Post-Migration Validation](06-post-migration-validation.md).

---

## Downtime Considerations

Schema Registry migrations can be executed with **zero downtime**. The registry is read-heavy and write-light, so most operations can be served by either registry during migration.

For a one-time copy (`srctl clone`), cutover involves switching all clients at once after validation. This is the simplest approach and works well for most organizations.

For organizations that need a gradual rollout of client changes (e.g., hundreds of microservices with different release schedules), consider these strategies:

**Blue-Green:** Run source and target in parallel. Migrate schemas, validate, then switch all traffic in one coordinated cutover. Provides instant rollback by pointing back to the source.

**Canary:** Migrate a subset of applications first, monitor for issues, then gradually migrate the rest. Limits blast radius but extends the migration window.

These strategies apply to how you roll out client configuration changes, not to the schema copy itself -- the schema copy via `srctl clone` is always a single operation.

---

## What's Next

| Document | Description |
|---|---|
| [Pre-Migration Assessment](02-pre-migration-assessment.md) | Inventory schemas, subjects, IDs, and dependencies |
| [Migration via Schema Exporter](03-migration-via-exporter.md) | Continuous schema replication from CP Enterprise to Cloud |
| [Migration via srctl](04-migration-via-api.md) | Clone, export/import, backup/restore options |
| [Multiple SRs & Contexts](05-multi-sr-and-contexts.md) | Consolidating multiple registries |
| [Post-Migration Validation](06-post-migration-validation.md) | Verify migration success and cutover |
| [Troubleshooting](07-troubleshooting.md) | Common issues and resolutions |
