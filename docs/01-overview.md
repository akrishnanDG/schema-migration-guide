# Migration Overview

This guide covers migrating from the **Community (open-source) Schema Registry** to **Confluent Platform SR** (self-managed) or **Confluent Cloud SR** (fully managed), and migrating from **Confluent Platform (Enterprise) SR** to **Confluent Cloud SR** using Schema Exporter. It includes tooling options, planning, validation, and cutover procedures.

---

## Why Migrate

The Community Schema Registry serves basic needs but lacks the capabilities organizations require as Kafka deployments mature.

- **Broker-side schema validation** -- Confluent enforces validation at the broker, preventing malformed data from reaching topics.
- **RBAC** -- Fine-grained, resource-level access control for subjects and schemas (absent in community SR).
- **Schema Linking** -- Continuous, automated schema replication across Confluent Platform registries.
- **Tags, Data Contracts, Metadata** -- Data quality rules and tagging in Confluent Cloud.
- **Enterprise support** -- SLA-backed support, JMX metrics, health checks, and managed upgrades.
- **Security** -- mTLS and OAuth/SSO for on-prem Confluent Platform; OAuth/SSO and audit logging for Confluent Cloud.
- **Confluent Cloud** -- Fully managed, 99.99% SLA, Stream Governance, pay-as-you-go pricing.

---

## Migration Paths

### Path 1: Community SR to Confluent Platform SR (Self-Managed)

| Aspect | Details |
|---|---|
| **Deployment** | Your infrastructure (VMs, Kubernetes, bare metal) |
| **Best for** | On-prem requirements (regulatory, latency, operational) |
| **Tooling** | `srctl clone` (recommended), REST API |
| **ID Preservation** | Supported via `srctl clone` or API with explicit ID assignment |

### Path 2: Community SR to Confluent Cloud SR (Managed)

| Aspect | Details |
|---|---|
| **Deployment** | Fully managed by Confluent |
| **Best for** | Reducing operational overhead; cloud-native Kafka adoption |
| **Tooling** | `srctl clone` (recommended), REST API |
| **ID Preservation** | Supported via `srctl clone` or API with explicit ID assignment |

### Path 3: CP Enterprise SR to Confluent Cloud SR

| Aspect | Details |
|---|---|
| **Deployment** | Fully managed by Confluent |
| **Best for** | Migrating from self-managed Confluent Platform 7.x+ to Cloud |
| **Tooling** | Schema Exporter (continuous sync), `srctl clone` (one-time copy) |
| **ID Preservation** | Supported by both Schema Exporter and `srctl clone` |

---

## Decision Tree {#decision-tree}

```
START
  |
  v
[Is your source Confluent Platform 7.x+?]
  |                       |
  Yes                     No (Community SR)
  |                       |
  v                       v
[Use Schema Exporter    [Single source SR,
 for continuous sync     or multiple?]
 to Cloud, or srctl       |              |
 clone for one-time       Single       Multiple
 copy]                    |              |
                          v              v
                        [Need to       [Consolidating into
                         preserve       a single target?]
                         schema IDs?]    |         |
                          |      |       Yes       No
                          Yes    No      |         |
                          |      |       v         v
                          v      v      Use       Migrate each
                         Use    Use    srctl     independently
                         srctl  srctl  clone     (single-source
                         clone  clone  with       flow per SR)
                                       --context
```

`srctl clone` is the recommended approach for all community SR migration scenarios. It handles dependency ordering, ID preservation, and mode transitions automatically.

### srctl clone

[`srctl`](https://github.com/akrishnanDG/srctl) is a Go CLI tool purpose-built for Schema Registry migrations. It clones schemas from source to destination with automatic dependency ordering and ID preservation.

**Use when:** migrating to Cloud or Platform, consolidating multiple registries, or when you need a reliable one-time migration. Works with all targets and SR versions.

**Key capabilities:** topological sorting of dependencies, schema ID preservation, Avro/Protobuf/JSON Schema support, dry-run mode.

```bash
# Clone all schemas from community SR to Confluent Cloud
srctl clone \
  --url http://community-sr:8081 \
  --target-url https://psrc-XXXXX.region.aws.confluent.cloud \
  --target-username <CLOUD_API_KEY> \
  --target-password <CLOUD_API_SECRET>
```

For air-gapped environments or when you need to inspect schemas before importing, `srctl export` + `srctl import` provides a two-phase alternative. For full state replication including configs, modes, and tags, use `srctl backup` + `srctl restore`. See [Migration via srctl](04-migration-via-api.md) for details on all options.

### Schema Exporter (CP Enterprise to Cloud)

Available when the source is Confluent Platform 7.x+. Provides continuous schema replication to another CP instance or to Confluent Cloud. See [Migration via Schema Exporter](03-migration-via-exporter.md).

---

## Migration Phases

Every migration follows five phases. Skipping a phase increases risk.

### Phase 1: Assess

Inventory subjects, schema versions, IDs, types, references, compatibility settings, and all producers/consumers that interact with the registry. See [Pre-Migration Assessment](02-pre-migration-assessment.md).

### Phase 2: Plan

Select your approach using the [decision tree](#decision-tree), determine whether IDs must be preserved (they usually must), define success criteria and rollback procedures, and schedule the cutover window.

### Phase 3: Migrate

Run `srctl clone` against a staging environment first, then execute against production. Capture logs for audit and troubleshooting. See [Migration via srctl](04-migration-via-api.md).

### Phase 4: Validate

Compare subject counts, schema content (hash comparison), schema IDs, and compatibility levels between source and target. Run integration tests with representative producers and consumers. See [Post-Migration Validation](06-post-migration-validation.md).

### Phase 5: Cutover

Update producer/consumer configurations to the target registry, monitor for errors, and keep the source registry in read-only mode for 48-72 hours as a rollback safety net. See [Post-Migration Validation](06-post-migration-validation.md).

---

## Downtime Considerations

Schema Registry migrations can be executed with **zero downtime**. The registry is read-heavy and write-light, so most operations can be served by either registry during migration.

**Blue-Green:** Run source and target in parallel. Migrate schemas, validate, then switch all traffic in one coordinated cutover. Provides instant rollback by pointing back to the source.

**Canary:** Migrate a subset of applications first, monitor for issues, then gradually migrate the rest. Limits blast radius but extends the migration window.

Keep the target in IMPORT mode during migration (for ID preservation), switch to READWRITE before cutover, and always test end-to-end in a non-production environment first.

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
