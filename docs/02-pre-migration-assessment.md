# Pre-Migration Assessment

Before migrating, you need a clear picture of your source Schema Registry: what schemas exist, how they are configured, and what depends on them. This document covers each area to check, using `srctl` throughout.

---

## Schema Inventory

Get a summary of your registry -- total subjects, schema types (Avro, Protobuf, JSON Schema), and version counts:

```bash
srctl stats --url http://source-sr:8081
srctl stats --url http://source-sr:8081 --by-type
```

Review the subject list for anything that is no longer in use. Dead subjects add unnecessary risk -- soft-delete them before migration if possible.

```bash
srctl list --url http://source-sr:8081 --versions
```

Check for schema references (one schema importing types from another). References create ordering constraints: referenced schemas must be registered in the target first.

```bash
srctl refs --url http://source-sr:8081
```

---

## Schema Size

Confluent Cloud enforces a 1 MB maximum schema size. Self-managed registries have no default limit, so oversized schemas may exist in your source.

```bash
srctl stats --url http://source-sr:8081 --size
```

If any schemas exceed the limit, use `srctl split` to analyze and extract nested types into separate referenced subjects:

```bash
srctl split analyze --subject my-large-schema --url http://source-sr:8081
srctl split extract --subject my-large-schema --url http://source-sr:8081 --dry-run
```

---

## Compatibility Configuration

Compatibility settings control which schema changes are allowed. Migrating without preserving these settings can silently allow breaking changes in the target.

```bash
# Global compatibility level
srctl config get --global --url http://source-sr:8081

# Per-subject overrides (must be replicated in the target)
srctl config get --all --url http://source-sr:8081
```

Also check mode settings. The target must be set to `IMPORT` mode during migration to preserve schema IDs.

```bash
srctl mode get --global --url http://source-sr:8081
srctl mode get --all --url http://source-sr:8081
```

---

## Subject Naming Strategy

The subject naming strategy lives in client configuration, not in Schema Registry, but it affects how subjects map to topics and therefore how they must be migrated.

| Strategy | Subject Format | Notes |
|---|---|---|
| `TopicNameStrategy` | `<topic>-key`, `<topic>-value` | Default. Simplest to migrate. |
| `RecordNameStrategy` | `<record-name>` | Decouples subjects from topics. |
| `TopicRecordNameStrategy` | `<topic>-<record-name>` | Many-to-many topic/subject mapping. |

Check your Kafka client configs for `key.subject.name.strategy` and `value.subject.name.strategy`. If different applications use different strategies, document which strategy each uses.

---

## Topology

Determine how many Schema Registry clusters you have (one per environment, per datacenter, per team, etc.) and run the inventory against each:

```bash
srctl stats --url http://sr-cluster-1:8081
srctl stats --url http://sr-cluster-2:8081
```

If merging multiple clusters into one target, check for subject name collisions:

```bash
srctl diff --url http://sr-cluster-1:8081 --target-url http://sr-cluster-2:8081
```

Collisions can be resolved with Schema Registry contexts (logical namespaces), subject renaming, or keeping environments separate. Check whether your source already uses contexts:

```bash
srctl contexts --url http://source-sr:8081
```

---

## Security and Authentication

Identify the auth mechanism on the source (none, HTTP Basic, mTLS, RBAC, OAuth) and document the target model. If migrating to Confluent Cloud, auth uses API keys or OAuth -- all client configs will need credential updates.

If your source uses RBAC or ACLs, export the current role bindings and plan equivalent configuration in the target.

---

## Client Inventory

Every application that connects to Schema Registry must be updated during or after migration. Common client types: Kafka producers/consumers, Kafka Connect, ksqlDB, Kafka Streams, and any custom REST clients.

For each client, document:
- Current `schema.registry.url` configuration
- Required credential changes for the target
- Cutover strategy: big bang (all at once), rolling (one at a time), or dual-write (register in both during transition)

---

## Network Connectivity

Verify that your migration tool can reach both the source and target registries:

```bash
srctl health --url http://source-sr:8081
srctl health --url https://target-sr-endpoint
```

For on-prem to Cloud migrations, ensure outbound HTTPS (443) is allowed. For large registries (10,000+ schemas), factor in per-request latency when estimating migration duration.

---

## Dangling References

A dangling reference is a schema that references another schema (by subject and version) that does not exist or has been deleted. These will cause migration failures because the target registry rejects schemas with unresolvable references.

```bash
srctl dangling --url http://source-sr:8081
```

Fix all dangling references before proceeding -- either re-register the missing schema, update the reference, or delete the orphaned schema.

Once all blocking issues are resolved, proceed to the migration planning phase.
