# Migration Overview

This guide covers migrating from the **Community (open-source) Schema Registry** to **Confluent Platform SR** (self-managed) or **Confluent Cloud SR** (fully managed). It includes tooling options, planning, validation, and cutover procedures.

---

## Why Migrate

The Community Schema Registry serves basic needs but lacks the capabilities organizations require as Kafka deployments mature.

- **Broker-side schema validation** -- Confluent enforces validation at the broker, preventing malformed data from reaching topics.
- **RBAC** -- Fine-grained, resource-level access control for subjects and schemas (absent in community SR).
- **Schema Linking / Exporter** -- Continuous, automated schema replication across registries (CP 7.x+).
- **Tags, Data Contracts, Metadata** -- Data quality rules and tagging in Confluent Cloud.
- **Enterprise support** -- SLA-backed support, JMX metrics, health checks, and managed upgrades.
- **Security** -- mTLS, OAuth/SSO, and audit logging out of the box.
- **Confluent Cloud** -- Fully managed, 99.99% SLA, Stream Governance, pay-as-you-go pricing.

---

## Migration Paths

### Path 1: Community SR to Confluent Platform SR (Self-Managed)

| Aspect | Details |
|---|---|
| **Deployment** | Your infrastructure (VMs, Kubernetes, bare metal) |
| **Best for** | On-prem requirements (regulatory, latency, operational) |
| **Tooling** | `srctl clone` (recommended), Schema Exporter (CP 7.x+), REST API |
| **ID Preservation** | Supported via `srctl clone` or API with explicit ID assignment |

### Path 2: Community SR to Confluent Cloud SR (Managed)

| Aspect | Details |
|---|---|
| **Deployment** | Fully managed by Confluent |
| **Best for** | Reducing operational overhead; cloud-native Kafka adoption |
| **Tooling** | `srctl clone` (recommended), REST API |
| **ID Preservation** | Supported via `srctl clone` or API with explicit ID assignment |

---

## Decision Tree {#decision-tree}

```
START
  |
  v
[Single source SR, or multiple?]
  |                       |
  Single                Multiple
  |                       |
  v                       v
[Need to preserve      [Consolidating into
 schema IDs?]           a single target?]
  |         |            |         |
  Yes       No           Yes       No
  |         |            |         |
  v         v            v         v
 Use       Use          Use       Migrate each
 srctl     srctl        srctl     independently
 clone     clone        clone     (single-source
  |                                flow per SR)
  v
[On CP 7.x+ targeting Platform?]
  |              |
  Yes            No
  v              v
 Schema         srctl
 Exporter       clone
 (or srctl
  clone)
```

### Recommended Approaches

#### 1. srctl clone (Recommended for Most Migrations)

[`srctl`](https://github.com/akrishnanDG/srctl) is a Go CLI tool purpose-built for Schema Registry migrations. It clones schemas from source to destination with automatic dependency ordering and ID preservation.

**Use when:** migrating to Cloud or Platform, consolidating multiple registries, or when you need a reliable one-time migration. Works with all targets and SR versions.

**Key capabilities:** topological sorting of dependencies, schema ID preservation, Avro/Protobuf/JSON Schema support, dry-run mode.

```bash
# Clone all schemas from community SR to Confluent Cloud
srctl clone \
  --src http://community-sr:8081 \
  --dst https://psrc-XXXXX.region.aws.confluent.cloud \
  --dst-api-key <CLOUD_API_KEY> \
  --dst-api-secret <CLOUD_API_SECRET>
```

#### 2. Schema Exporter (CP 7.x+ Only)

Built-in feature for continuous schema replication between Confluent Platform registries. Use when you are already on CP 7.x+ and want ongoing synchronization rather than a one-time migration. Not available for Cloud targets. Source must be a Confluent Platform SR.

#### 3. REST API / Custom Scripts

Direct use of the SR REST API for export/import. Use when you have few schemas with simple dependencies and need full control. You must manually handle dependency ordering and IMPORT mode for ID preservation.

---

## Migration Phases

Every migration follows five phases. Skipping a phase increases risk.

### Phase 1: Assess

Inventory subjects, schema versions, IDs, types, references, compatibility settings, and all producers/consumers that interact with the registry. See [Pre-Migration Assessment](02-pre-migration-assessment.md).

### Phase 2: Plan

Select your tooling using the [decision tree](#decision-tree), determine whether IDs must be preserved (they usually must), define success criteria and rollback procedures, and schedule the cutover window.

### Phase 3: Migrate

Run `srctl clone` (or your chosen tool) against a staging environment first, then execute against production. Capture logs for audit and troubleshooting. See [Migration via Exporter](03-migration-via-exporter.md) | [Migration via API](04-migration-via-api.md).

### Phase 4: Validate

Compare subject counts, schema content (hash comparison), schema IDs, and compatibility levels between source and target. Run integration tests with representative producers and consumers. See [Validation](05-validation.md).

### Phase 5: Cutover

Update producer/consumer configurations to the target registry, monitor for errors, and keep the source registry in read-only mode for 48-72 hours as a rollback safety net. See [Cutover](06-cutover.md).

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
| [Migration via Exporter](03-migration-via-exporter.md) | Step-by-step guide using the CP 7.x+ Schema Exporter |
| [Migration via API](04-migration-via-api.md) | Step-by-step guide using REST API and custom scripts |
| [Validation](05-validation.md) | Verify migration success |
| [Cutover](06-cutover.md) | Switch traffic and decommission the source registry |
| [Troubleshooting](07-troubleshooting.md) | Common issues and resolutions |
