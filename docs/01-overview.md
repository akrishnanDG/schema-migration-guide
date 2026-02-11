# Migration Overview

This guide provides a practical, step-by-step approach to migrating from the **Community (open-source) Schema Registry** to either **Confluent Platform Schema Registry** (self-managed) or **Confluent Cloud Schema Registry** (fully managed). It covers tooling options, planning considerations, validation strategies, and cutover procedures so you can execute the migration with confidence and minimal disruption.

---

## Why Migrate

The Community Schema Registry serves basic schema management needs, but organizations often outgrow it as their Kafka deployments mature. The following gaps typically drive the decision to migrate.

### Feature Gaps

- **Schema Validation (Broker-side):** Confluent Platform and Cloud enforce schema validation at the broker level, preventing malformed data from ever reaching topics.
- **Role-Based Access Control (RBAC):** Community SR has no built-in RBAC. Confluent Platform provides fine-grained, resource-level access control for subjects and schemas.
- **Schema Linking and Exporter:** Confluent Platform 7.x+ includes the Schema Exporter feature for continuous, automated schema replication across registries.
- **Tags, Data Contracts, and Metadata:** Confluent Cloud supports data quality rules, metadata tagging, and data contracts that are unavailable in the community edition.
- **Multi-format Support:** While community SR supports Avro, Protobuf, and JSON Schema, Confluent editions offer deeper integration, normalization, and cross-format referencing.

### Support and Operations

- **Enterprise Support:** Community SR is unsupported. Confluent Platform and Cloud include SLA-backed support with access to Confluent engineering.
- **Monitoring and Metrics:** Confluent editions ship with JMX metrics, health checks, and integrations with monitoring platforms (Prometheus, Datadog, Grafana).
- **Upgrades and Patching:** Confluent manages the upgrade lifecycle. Community SR upgrades are entirely on you.

### Security

- **TLS / mTLS:** Confluent Platform SR supports mutual TLS authentication out of the box.
- **OAuth and SSO:** Confluent Cloud integrates with identity providers for single sign-on.
- **Audit Logging:** Confluent Platform provides audit logs for compliance and forensics.

### Confluent Cloud Benefits

- **Fully managed** -- no infrastructure to operate, patch, or scale.
- **99.99% SLA** with multi-AZ and multi-region options.
- **Stream Governance** with schema discovery, lineage, and quality rules.
- **Pay-as-you-go pricing** based on schema operations and storage.

---

## Migration Paths

There are two target destinations. Your choice depends on whether you want to continue self-managing infrastructure or move to a fully managed service.

### Path 1: Community SR to Confluent Platform SR (On-Prem / Self-Managed)

| Aspect | Details |
|---|---|
| **Target** | Confluent Platform Schema Registry (CP 7.x+) |
| **Deployment** | Your infrastructure (VMs, Kubernetes, bare metal) |
| **Best for** | Organizations that must keep data on-prem due to regulatory, latency, or operational requirements |
| **Tooling** | srctl clone, Schema Exporter (CP 7.x+), REST API scripts |
| **ID Preservation** | Supported via srctl clone or API-based migration with explicit ID assignment |

### Path 2: Community SR to Confluent Cloud SR (Managed)

| Aspect | Details |
|---|---|
| **Target** | Confluent Cloud Schema Registry |
| **Deployment** | Fully managed by Confluent |
| **Best for** | Organizations looking to reduce operational overhead and adopt cloud-native Kafka |
| **Tooling** | srctl clone, REST API scripts |
| **ID Preservation** | Supported via srctl clone or API-based migration with explicit ID assignment |

---

## Decision Tree {#decision-tree}

Use the following flowchart to determine which migration approach fits your situation.

```
START
  |
  v
[Do you have a single source Schema Registry, or multiple?]
  |                           |
  Single                    Multiple
  |                           |
  v                           v
[Do you need to             [Consolidating into
 preserve schema IDs?]       a single target SR?]
  |           |               |          |
  Yes         No              Yes        No
  |           |               |          |
  v           v               v          v
[Are you     [Any approach   [Use        [Migrate each
 running      will work.      srctl       SR independently.
 CP 7.x+?]   Recommended:    clone --    Follow single-source
  |    |      srctl clone]    recommended flow for each.]
  |    |                      for multi-
  |    |                      source
  |    |                      consolidation]
  |    |
  Yes  No
  |    |
  v    v
[Migrating to         [Migrating to
 Cloud or Platform?]   Cloud or Platform?]
  |          |          |          |
  Cloud    Platform    Cloud    Platform
  |          |          |          |
  v          v          v          v
 USE        USE        USE       USE
 srctl      Schema     srctl     srctl
 clone      Exporter   clone     clone
            (or srctl
             clone)
```

### Recommended Approaches

#### 1. srctl clone (Recommended for Most Migrations)

[`srctl`](https://github.com/akrishnanDG/srctl) is a Go CLI tool purpose-built for Schema Registry migrations. It is the recommended approach for the majority of migration scenarios.

- **What it does:** Clones schemas from a source registry to a destination registry with automatic dependency ordering and schema ID preservation.
- **When to use it:**
  - Migrating to Confluent Cloud (Schema Exporter is not available for Cloud targets).
  - Migrating to Confluent Platform when you are not yet on CP 7.x+.
  - Consolidating multiple source registries into a single target.
  - When you need a one-time, reliable migration with ID preservation.
- **Key capabilities:**
  - Automatic topological sorting of schema dependencies (handles references and imports).
  - Preserves schema IDs on the target registry.
  - Supports Avro, Protobuf, and JSON Schema.
  - Dry-run mode for pre-migration validation.
  - Works with both Confluent Platform and Confluent Cloud as targets.

```bash
# Example: clone all schemas from community SR to Confluent Cloud
srctl clone \
  --src http://community-sr:8081 \
  --dst https://psrc-XXXXX.region.aws.confluent.cloud \
  --dst-api-key <CLOUD_API_KEY> \
  --dst-api-secret <CLOUD_API_SECRET>
```

#### 2. Schema Exporter (CP 7.x+ Only)

The Schema Exporter is a built-in feature of Confluent Platform 7.x+ that continuously replicates schemas from one registry to another.

- **When to use it:**
  - You are already running Confluent Platform 7.x+ (or upgrading to it).
  - You want continuous, ongoing synchronization rather than a one-time migration.
  - Your target is another Confluent Platform registry (not Cloud).
- **Key capabilities:**
  - Continuous replication with configurable lag.
  - Built-in monitoring via JMX metrics.
  - Supports context-based routing of schemas.
- **Limitations:**
  - Only available in CP 7.x+.
  - Source must be a Confluent Platform SR (requires the exporter plugin).
  - Not available for direct export to Confluent Cloud.

#### 3. REST API / Custom Scripts (Manual Approach)

Direct use of the Schema Registry REST API to export and import schemas via custom scripts.

- **When to use it:**
  - You have a small number of schemas and simple dependencies.
  - You need full control over the migration process.
  - Neither srctl nor the Exporter fits your environment.
- **Key capabilities:**
  - Works in every scenario -- no version or tooling requirements.
  - Can be customized to handle edge cases specific to your environment.
- **Limitations:**
  - You must manually handle dependency ordering (schema references).
  - ID preservation requires setting the target registry to IMPORT mode.
  - More error-prone and time-consuming than automated tools.

---

## Migration Phases

Every migration follows five phases. Skipping a phase increases risk.

### Phase 1: Assess

Inventory your current state. Understand what you are migrating and what might break.

- Count subjects, schema versions, and unique schema IDs.
- Identify schema types (Avro, Protobuf, JSON Schema) and inter-schema references.
- Document compatibility settings (BACKWARD, FORWARD, FULL, NONE) per subject.
- Catalog all producers and consumers that interact with the registry.
- Identify any hard-coded schema IDs in application configurations.

See: [Pre-Migration Assessment](02-pre-migration-assessment.md)

### Phase 2: Plan

Select your migration approach, define your rollback strategy, and schedule the work.

- Choose your tooling (srctl clone, Exporter, or REST API) based on the [decision tree](#decision-tree) above.
- Determine whether schema IDs must be preserved (they usually must).
- Define success criteria: what does "migration complete" mean for your organization?
- Plan your cutover window and communication to application teams.
- Build and test your rollback procedure.

### Phase 3: Migrate

Execute the schema migration from source to target.

- Run the migration tool against a staging or dev environment first.
- Execute against production.
- Capture logs and output for audit and troubleshooting.

See: [Migration via Exporter](03-migration-via-exporter.md) | [Migration via API](04-migration-via-api.md)

### Phase 4: Validate

Confirm that every schema, version, ID, and compatibility setting arrived intact.

- Compare subject counts between source and target.
- Validate schema content (hash comparison) for every version.
- Verify that schema IDs match between source and target (if preservation was required).
- Confirm compatibility levels are correctly set on the target.
- Run integration tests with representative producers and consumers against the target registry.

See: [Validation](05-validation.md)

### Phase 5: Cutover

Switch producers and consumers to the new registry and decommission the old one.

- Update producer and consumer configurations to point to the target registry.
- Monitor for errors, serialization failures, and registry connectivity issues.
- Keep the source registry running in read-only mode for a rollback window (recommended: 48--72 hours).
- After the rollback window expires with no issues, decommission the source registry.

See: [Cutover](06-cutover.md)

---

## Downtime Considerations

Schema Registry migrations can be executed with **zero downtime** if planned correctly. The registry itself is a read-heavy, write-light service -- most operations are schema lookups, which can be served by either the old or new registry during migration.

### Blue-Green Deployment

Run the source and target registries in parallel. Migrate schemas to the target while producers and consumers continue to use the source. Once migration and validation are complete, switch traffic to the target in a single coordinated cutover.

- **Advantage:** Clean cutover with instant rollback (just point back to source).
- **Trade-off:** Requires running two registries simultaneously and coordinating the switch across all clients.

### Canary Deployment

Migrate a subset of applications (or a single team's applications) to the target registry first. Monitor for issues. Gradually migrate remaining applications.

- **Advantage:** Limits blast radius. Issues are caught early with minimal impact.
- **Trade-off:** Longer migration window. Some applications read from the old registry while others read from the new one, which can complicate debugging.

### Key Recommendations

- **Do not** stop producers during migration. Schemas are registered ahead of time; producers only look up existing schemas during normal operation.
- **Do** put the target registry in IMPORT mode during migration (if preserving IDs), then switch it back to READWRITE mode before cutover.
- **Do** keep the source registry available in read-only mode for at least 48 hours after cutover as a safety net.
- **Do** test the migration end-to-end in a non-production environment before executing in production.

---

## What's Next

| Document | Description |
|---|---|
| [Pre-Migration Assessment](02-pre-migration-assessment.md) | Inventory your schemas, subjects, IDs, and dependencies |
| [Migration via Exporter](03-migration-via-exporter.md) | Step-by-step guide using the CP 7.x+ Schema Exporter |
| [Migration via API](04-migration-via-api.md) | Step-by-step guide using REST API calls and custom scripts |
| [Validation](05-validation.md) | How to verify that migration was successful |
| [Cutover](06-cutover.md) | Switching traffic and decommissioning the source registry |
| [Troubleshooting](07-troubleshooting.md) | Common issues and how to resolve them |
