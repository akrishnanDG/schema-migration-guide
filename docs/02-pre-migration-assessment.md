# Pre-Migration Assessment

## Overview

A thorough pre-migration assessment is the single most important step in any Schema Registry migration. Skipping or rushing this phase is the leading cause of migration failures, broken consumers, and unplanned downtime. The goal is to build a complete picture of your current Schema Registry environment -- its schemas, configurations, dependencies, clients, and network topology -- so that you can choose the right migration strategy and anticipate problems before they occur.

This document walks through each dimension of the assessment. Every section includes both `srctl` commands (the recommended approach) and raw `curl`/`jq` equivalents for environments where `srctl` is not yet installed.

For a fully automated version of this assessment, see the companion script at [`scripts/pre-check.sh`](../scripts/pre-check.sh).

---

## 1. Schema Inventory

Before you can migrate anything, you need to know exactly what you have. A schema inventory answers four questions: how many subjects exist, what schema types are in use, how many versions each subject carries, and whether any schemas reference other schemas.

### 1.1 Total Subject Count

```bash
# Using srctl (recommended)
srctl stats --url http://source-sr:8081

# Using curl
curl -s http://source-sr:8081/subjects | jq '. | length'
```

A large subject count (thousands or more) does not prevent migration, but it does affect how long the migration takes and whether you should batch the work.

### 1.2 List All Subjects

```bash
# Using srctl (recommended)
srctl list --url http://source-sr:8081

# Using curl
curl -s http://source-sr:8081/subjects | jq '.[]'
```

Review the list for subjects that are no longer in use. Migrating dead subjects adds unnecessary risk and clutter. If you can identify and soft-delete them before migration, do so.

### 1.3 Schema Types in Use

Schema Registry supports three schema types: **Avro**, **Protobuf**, and **JSON Schema**. Each type has different serialization behavior, reference handling, and compatibility semantics. Knowing the mix is essential for planning.

```bash
# Using srctl (recommended)
srctl stats --url http://source-sr:8081 --by-type

# Using curl -- inspect each subject's latest schema
for subject in $(curl -s http://source-sr:8081/subjects | jq -r '.[]'); do
  schema_type=$(curl -s "http://source-sr:8081/subjects/${subject}/versions/latest" \
    | jq -r '.schemaType // "AVRO"')
  echo "${subject}: ${schema_type}"
done
```

> **Note:** The Schema Registry API returns `schemaType` only for Protobuf and JSON Schema. If the field is absent, the schema is Avro.

### 1.4 Versions per Subject

Subjects with many versions take longer to migrate and are more likely to have complex compatibility histories.

```bash
# Using srctl (recommended)
srctl list --url http://source-sr:8081 --versions

# Using curl
for subject in $(curl -s http://source-sr:8081/subjects | jq -r '.[]'); do
  version_count=$(curl -s "http://source-sr:8081/subjects/${subject}/versions" | jq '. | length')
  echo "${subject}: ${version_count} version(s)"
done
```

Subjects with more than 50 versions deserve a closer look. Consider whether all versions need to be migrated or only the latest N versions are required for active consumers.

### 1.5 Schema References and Dependencies

Schema references allow one schema to import types defined in another schema. This is common with Protobuf (`import` statements) and increasingly used in Avro and JSON Schema. References create an ordering constraint: referenced schemas must be registered in the target **before** the schemas that depend on them.

```bash
# Using srctl (recommended)
srctl refs --url http://source-sr:8081

# Using curl -- check each subject for references
for subject in $(curl -s http://source-sr:8081/subjects | jq -r '.[]'); do
  refs=$(curl -s "http://source-sr:8081/subjects/${subject}/versions/latest" \
    | jq '.references // [] | length')
  if [ "$refs" -gt 0 ]; then
    echo "${subject}: ${refs} reference(s)"
    curl -s "http://source-sr:8081/subjects/${subject}/versions/latest" \
      | jq '.references'
  fi
done
```

Build a dependency graph from this output. Any circular references will need to be resolved before migration.

---

## 2. Schema Size Analysis

### 2.1 Maximum Schema Size

Confluent Cloud enforces a default maximum schema size of **1 MB**. Self-managed Schema Registry does not enforce a limit by default, so it is possible to have schemas in your source registry that exceed the Cloud limit.

```bash
# Using srctl (recommended)
srctl stats --url http://source-sr:8081 --size

# Using curl -- check the byte size of each schema
for subject in $(curl -s http://source-sr:8081/subjects | jq -r '.[]'); do
  size=$(curl -s "http://source-sr:8081/subjects/${subject}/versions/latest" \
    | jq '.schema | length')
  if [ "$size" -gt 1000000 ]; then
    echo "WARNING: ${subject} schema is ${size} bytes (exceeds 1 MB limit)"
  fi
done
```

### 2.2 Identifying Oversized Schemas

Schemas that exceed the target size limit must be refactored before migration. Common causes of oversized schemas include:

- **Deeply nested types** -- schemas with many levels of nested record definitions.
- **Inlined dependencies** -- types that should be separate subjects referenced via schema references, but are instead copied inline.
- **Generated schemas** -- code-generated schemas (e.g., from large Protobuf files) that bundle many message types into a single registration.

### 2.3 Splitting Large Schemas with srctl

`srctl` provides a `split` subcommand that analyzes oversized schemas and extracts nested types into separate subjects that can be registered independently and referenced.

```bash
# Analyze a schema to see what can be extracted
srctl split analyze --subject my-large-schema --url http://source-sr:8081

# Extract nested types into separate subjects
srctl split extract --subject my-large-schema --url http://source-sr:8081

# Dry-run the extraction to preview changes without applying them
srctl split extract --subject my-large-schema --url http://source-sr:8081 --dry-run
```

After splitting, re-run the size check to confirm all resulting schemas are within the target limit.

---

## 3. Compatibility Configuration

Compatibility settings control which schema changes are allowed when a new version is registered. Migrating schemas without preserving compatibility settings can silently allow breaking changes in the target environment.

### 3.1 Global Compatibility Level

```bash
# Using srctl (recommended)
srctl config get --global --url http://source-sr:8081

# Using curl
curl -s http://source-sr:8081/config | jq '.compatibilityLevel'
```

The default global compatibility level is `BACKWARD`. Common levels include:

| Level | Description |
|---|---|
| `BACKWARD` | New schema can read data written by the previous version |
| `BACKWARD_TRANSITIVE` | New schema can read data written by all previous versions |
| `FORWARD` | Previous schema can read data written by the new version |
| `FORWARD_TRANSITIVE` | All previous schemas can read data written by the new version |
| `FULL` | Both backward and forward compatible with the previous version |
| `FULL_TRANSITIVE` | Both backward and forward compatible with all previous versions |
| `NONE` | No compatibility checking |

### 3.2 Per-Subject Compatibility Overrides

Individual subjects can override the global compatibility level. These overrides must be captured and replicated in the target.

```bash
# Using srctl (recommended)
srctl config get --all --url http://source-sr:8081

# Using curl
for subject in $(curl -s http://source-sr:8081/subjects | jq -r '.[]'); do
  compat=$(curl -s "http://source-sr:8081/config/${subject}" 2>/dev/null \
    | jq -r '.compatibilityLevel // empty')
  if [ -n "$compat" ]; then
    echo "${subject}: ${compat}"
  fi
done
```

Document every override. During migration, you will need to set these on the target before registering schemas (or register with compatibility checks disabled, then re-enable).

### 3.3 Mode Settings

Schema Registry supports three modes:

| Mode | Description |
|---|---|
| `READWRITE` | Normal operation -- schemas can be read and written |
| `READONLY` | Schemas can be read but not written |
| `IMPORT` | Schemas can be imported with explicit IDs (required for migration) |

```bash
# Using srctl (recommended)
srctl mode get --global --url http://source-sr:8081
srctl mode get --all --url http://source-sr:8081

# Using curl
curl -s http://source-sr:8081/mode | jq '.mode'

# Per-subject modes
for subject in $(curl -s http://source-sr:8081/subjects | jq -r '.[]'); do
  mode=$(curl -s "http://source-sr:8081/mode/${subject}" 2>/dev/null \
    | jq -r '.mode // empty')
  if [ -n "$mode" ]; then
    echo "${subject}: ${mode}"
  fi
done
```

> **Important:** The target registry must be set to `IMPORT` mode during migration if you need to preserve schema IDs. This is covered in detail in the migration execution docs.

---

## 4. Subject Naming Strategy

The subject naming strategy determines how Kafka clients map topics and schemas to Schema Registry subjects. This setting lives in the client configuration, not in Schema Registry itself, but it fundamentally affects how subjects are organized and therefore how they must be migrated.

### 4.1 Strategies

| Strategy | Subject Name Format | Typical Use Case |
|---|---|---|
| `TopicNameStrategy` | `<topic>-key`, `<topic>-value` | Default. One schema per topic. |
| `RecordNameStrategy` | `<fully-qualified-record-name>` | Multiple record types per topic. |
| `TopicRecordNameStrategy` | `<topic>-<fully-qualified-record-name>` | Multiple record types per topic, scoped by topic. |

### 4.2 Impact on Migration

- **TopicNameStrategy** is the simplest to migrate. Subjects map 1:1 to topics, and the subject names are predictable.
- **RecordNameStrategy** decouples subjects from topics entirely. You must audit client configurations to understand which topics use which subjects.
- **TopicRecordNameStrategy** creates a many-to-many relationship between topics and subjects. The migration must preserve subject names exactly, or consumers will fail to find their schemas.

```bash
# Check your Kafka client configurations for these properties:
# key.subject.name.strategy
# value.subject.name.strategy
```

If different applications use different strategies against the same Schema Registry, document which strategy each application uses.

---

## 5. Topology Assessment

### 5.1 Single vs. Multiple Schema Registry Clusters

Determine how many Schema Registry clusters exist in your current environment. Common patterns include:

- **Single cluster** serving all environments (dev, staging, prod).
- **One cluster per environment** with identical or overlapping schemas.
- **One cluster per Kafka cluster** in a multi-datacenter deployment.
- **One cluster per team or domain** for organizational isolation.

```bash
# If you have multiple SR clusters, run the inventory against each
srctl stats --url http://sr-cluster-1:8081
srctl stats --url http://sr-cluster-2:8081
```

### 5.2 Overlap Analysis

If you are merging multiple Schema Registry clusters into a single target (e.g., Confluent Cloud), you must check for subject name collisions.

```bash
# Using srctl (recommended)
srctl diff --url http://sr-cluster-1:8081 --target-url http://sr-cluster-2:8081

# Using curl -- compare subject lists
diff <(curl -s http://sr-cluster-1:8081/subjects | jq -r '.[]' | sort) \
     <(curl -s http://sr-cluster-2:8081/subjects | jq -r '.[]' | sort)
```

If the same subject name exists in multiple source clusters with different schemas, you have a conflict. Resolution options:

1. **Use Schema Registry contexts** to namespace subjects (e.g., `:.cluster1:my-subject`).
2. **Rename subjects** in one cluster before migration (requires coordinated client changes).
3. **Keep separate environments** in the target and do not merge.

### 5.3 Schema Registry Contexts

Contexts provide logical namespaces within a single Schema Registry instance. They are particularly useful when consolidating multiple source registries into one target.

```bash
# Using srctl (recommended)
srctl contexts --url http://source-sr:8081

# Using curl
curl -s http://source-sr:8081/contexts | jq '.[]'
```

If your source already uses contexts, they must be preserved in the target.

---

## 6. Security and ACLs

### 6.1 Current Authentication Setup

Identify the authentication mechanism in use on the source Schema Registry:

| Auth Type | Configuration Indicators |
|---|---|
| **None** | No authentication headers required |
| **HTTP Basic Auth** | `basic.auth.credentials.source`, `basic.auth.user.info` in client configs |
| **mTLS** | `ssl.keystore.location`, `ssl.truststore.location` in SR and client configs |
| **RBAC** | Confluent RBAC enabled, role bindings defined in MDS |
| **OAuth/OIDC** | `bearer.auth.credentials.source` in client configs |

```bash
# Test if authentication is required
curl -s -o /dev/null -w "%{http_code}" http://source-sr:8081/subjects

# 200 = no auth required
# 401 = authentication required
# 403 = authenticated but not authorized
```

### 6.2 Target Authentication Model

Document the target authentication model. If migrating to Confluent Cloud, authentication uses API keys or OAuth. Map your current auth model to the target:

| Source Auth | Target Auth (Confluent Cloud) | Action Required |
|---|---|---|
| None | API Key | Generate API keys, update all client configs |
| Basic Auth | API Key | Replace credentials in all client configs |
| mTLS | API Key or OAuth | Replace TLS configs with API key or OAuth configs |
| RBAC | Confluent Cloud RBAC | Recreate role bindings using `confluent iam` CLI |

### 6.3 RBAC and ACL Mapping

If your source uses RBAC or ACLs, export the current bindings and plan the equivalent configuration in the target.

```bash
# Export RBAC role bindings (Confluent Platform)
confluent iam rolebinding list --principal User:alice --schema-registry-cluster-id <id>

# Export Kafka ACLs related to Schema Registry
kafka-acls --bootstrap-server broker:9092 --list --resource-pattern-type any \
  --topic _schemas
```

Create a mapping table of principals, roles, and resources that must be recreated in the target.

---

## 7. Client Inventory

Every application that reads from or writes to Schema Registry must be updated during or after migration. Missing even one client can cause production failures.

### 7.1 Identify All Clients

Build a list of every system that connects to Schema Registry. Common client types include:

| Client Type | How to Identify |
|---|---|
| **Kafka Producers** | Application configs with `schema.registry.url` |
| **Kafka Consumers** | Application configs with `schema.registry.url` |
| **Kafka Connect** | Connector configs with `value.converter.schema.registry.url` or `key.converter.schema.registry.url` |
| **ksqlDB** | Server config with `ksql.schema.registry.url` |
| **Kafka Streams** | Application configs with `schema.registry.url` |
| **Custom REST clients** | Any application making direct HTTP calls to the SR API |

### 7.2 Configuration Changes Needed

For each client, document the configuration changes required for the migration:

```properties
# Before (self-managed)
schema.registry.url=http://source-sr:8081

# After (Confluent Cloud example)
schema.registry.url=https://<cloud-sr-endpoint>
basic.auth.credentials.source=USER_INFO
basic.auth.user.info=<API_KEY>:<API_SECRET>
```

### 7.3 Client Cutover Planning

Decide on a cutover strategy:

- **Big bang:** All clients switch to the new SR at the same time.
- **Rolling:** Clients switch one at a time or in groups. This requires the source and target to be in sync during the rollover window.
- **Dual-write:** Producers register schemas in both source and target during the transition. This adds complexity but reduces risk.

---

## 8. Network and Connectivity

### 8.1 Source-to-Target Connectivity

If you plan to use the Schema Registry Exporter or Schema Linking, the source Schema Registry must be able to reach the target over the network. This is not always possible, especially when migrating from on-premises to Confluent Cloud.

```bash
# Using srctl (recommended)
srctl health --url http://source-sr:8081
srctl health --url https://target-sr-endpoint

# Test connectivity from source to target
curl -s -o /dev/null -w "%{http_code}" https://<target-sr-endpoint>/subjects
```

### 8.2 Firewall and Proxy Considerations

| Scenario | Considerations |
|---|---|
| On-prem to Cloud | Outbound HTTPS (443) must be allowed to `*.confluent.cloud` |
| VPC Peering | SR endpoint must be reachable within the peered VPC |
| PrivateLink | Configure PrivateLink endpoint for Schema Registry |
| HTTP Proxy | Set `https_proxy` environment variable or configure proxy in client settings |

### 8.3 Latency and Bandwidth

For large migrations (10,000+ schemas), network latency and bandwidth can affect migration duration. Consider:

- Schema registration is sequential when preserving IDs (each schema must be registered one at a time in ID order).
- Cross-region migrations add latency per request.
- Estimate total migration time: `(number_of_schemas * average_latency_per_registration)`.

---

## 9. Dangling References Check

A dangling reference occurs when a schema references another schema (by subject and version) that does not exist or has been deleted. Dangling references will cause migration failures because the target registry will reject schemas whose references cannot be resolved.

```bash
# Using srctl (recommended)
srctl dangling --url http://source-sr:8081

# Using curl -- manual check
for subject in $(curl -s http://source-sr:8081/subjects | jq -r '.[]'); do
  refs=$(curl -s "http://source-sr:8081/subjects/${subject}/versions/latest" \
    | jq -r '.references[]? | "\(.subject) v\(.version)"')
  if [ -n "$refs" ]; then
    while IFS= read -r ref; do
      ref_subject=$(echo "$ref" | awk '{print $1}')
      ref_version=$(echo "$ref" | awk '{print $2}' | tr -d 'v')
      status=$(curl -s -o /dev/null -w "%{http_code}" \
        "http://source-sr:8081/subjects/${ref_subject}/versions/${ref_version}")
      if [ "$status" != "200" ]; then
        echo "DANGLING: ${subject} -> ${ref_subject} v${ref_version} (HTTP ${status})"
      fi
    done <<< "$refs"
  fi
done
```

Fix all dangling references before proceeding with migration. Options include:

- **Re-register the missing referenced schema** in the source registry.
- **Update the referencing schema** to remove or replace the broken reference.
- **Delete the referencing schema** if it is no longer in use.

---

## 10. Automated Assessment

The [`scripts/pre-check.sh`](../scripts/pre-check.sh) script automates the checks described in this document. It produces a JSON report summarizing the state of your Schema Registry environment.

### Usage

```bash
# Basic usage
./scripts/pre-check.sh --url http://source-sr:8081

# With authentication
./scripts/pre-check.sh --url http://source-sr:8081 \
  --auth-user admin \
  --auth-pass secret

# Output to file
./scripts/pre-check.sh --url http://source-sr:8081 --output report.json
```

### What the Script Checks

| Check | Description |
|---|---|
| Subject count | Total number of subjects |
| Schema types | Breakdown by Avro, Protobuf, JSON Schema |
| Version counts | Per-subject version counts, flagging subjects with > 50 versions |
| Schema sizes | Identifies schemas exceeding 1 MB |
| Compatibility config | Global level and per-subject overrides |
| Mode settings | Global and per-subject modes |
| References | Full reference graph |
| Dangling references | Broken references that will block migration |
| Connectivity | Reachability of source and target endpoints |

### Interpreting the Report

The script exits with one of three codes:

| Exit Code | Meaning |
|---|---|
| `0` | All checks passed -- ready to proceed |
| `1` | Warnings found -- migration can proceed but review the warnings |
| `2` | Blocking issues found -- must be resolved before migration |

Review the JSON output and resolve any blocking issues before moving to the migration planning phase.

---

## Assessment Checklist

Use this checklist to confirm that the assessment is complete before proceeding:

- [ ] Total subject count documented
- [ ] Schema types identified (Avro, Protobuf, JSON Schema)
- [ ] Version counts reviewed; unused subjects identified for cleanup
- [ ] Schema references mapped; dependency order determined
- [ ] All schemas within target size limits (or splitting plan in place)
- [ ] Global compatibility level documented
- [ ] Per-subject compatibility overrides documented
- [ ] Mode settings documented
- [ ] Subject naming strategy confirmed for all clients
- [ ] Topology mapped (single vs. multiple clusters)
- [ ] Overlap analysis completed (if merging clusters)
- [ ] Authentication model documented (source and target)
- [ ] RBAC/ACL mapping created (if applicable)
- [ ] All clients inventoried (producers, consumers, Connect, ksqlDB, Streams)
- [ ] Client cutover strategy chosen
- [ ] Network connectivity verified (source to target)
- [ ] Dangling references resolved
- [ ] Automated pre-check script run and report reviewed

Once all items are checked, proceed to the migration planning phase.
