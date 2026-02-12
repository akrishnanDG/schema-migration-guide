# Multiple Schema Registries and Contexts

## What Are Contexts

Contexts are virtual namespaces within a single Schema Registry instance. They allow independent sets of subjects to coexist without interference. A context is a prefix on the subject name using `:.context-name:` syntax:

```
:.team-a:my-topic-value
```

- A single instance can host any number of contexts.
- Each context maintains independent subjects and schema IDs.
- The default context is `:.:`  or no prefix.
- Contexts are implicit -- created automatically when a schema is registered under a new prefix.

---

## When to Use Schema Contexts for Migration

Use contexts during migration in two scenarios:

1. **The destination Schema Registry already has schemas.** Migrating into the default context risks subject name collisions with existing subjects. Placing the migrated schemas under a dedicated context (e.g., `:.migrated:`) keeps them isolated from schemas already registered on the target.

2. **You are migrating from multiple source registries into one target.** Each source registry likely has its own set of subject names that may overlap with others. Assigning each source its own context (e.g., `:.team-a:`, `:.team-b:`) keeps every source's schemas isolated and avoids conflicts.

If the target registry is empty and you are migrating from a single source, contexts are unnecessary -- migrate directly into the default context.

---

## Migration Approach

### Step 1: Inventory Source Registries

```bash
srctl stats --url http://sr-team-a:8081 --workers 100
srctl stats --url http://sr-team-b:8081 --workers 100
```

### Step 2: Check for Subject Name Collisions

```bash
srctl compare --url http://sr-team-a:8081 --target-url http://sr-team-b:8081 --workers 100
```

Collisions are safe with contexts (`:.team-a:orders-value` and `:.team-b:orders-value` are distinct).

### Step 3: Define a Context Naming Convention

| Pattern | Example | When to use |
|---|---|---|
| Team name | `team-a`, `platform` | Clusters map to teams |
| Environment | `prod-east`, `prod-west` | Consolidating regional clusters |
| Domain | `payments`, `logistics` | Domain-driven design |

### Step 4: Migrate Each Source SR into Its Own Context

Use `srctl clone` with `--context` to scope each source into the target. `srctl clone` handles IMPORT mode on the destination automatically. See [Migration via srctl](04-migration-via-api.md) for details.

```bash
srctl clone \
  --url http://sr-team-a:8081 \
  --target-url http://consolidated-sr:8081 \
  --context team-a \
  --workers 100

srctl clone \
  --url http://sr-team-b:8081 \
  --target-url http://consolidated-sr:8081 \
  --context team-b \
  --workers 100
```

### Step 5: Update Client Configurations

Point clients at the consolidated instance and configure context awareness. See Client Configuration below.

### Step 6: Verify

```bash
srctl contexts --url http://consolidated-sr:8081
srctl subjects --url http://consolidated-sr:8081 --context team-a
srctl subjects --url http://consolidated-sr:8081 --context team-b
```

---

## Client Configuration for Contexts

### Kafka Producer / Consumer (Java)

```properties
schema.registry.url=http://consolidated-sr:8081
value.subject.name.strategy=io.confluent.kafka.serializers.subject.TopicRecordNameStrategy
context.name.strategy=io.confluent.kafka.serializers.context.strategy.ContextNameStrategy
context.name=team-a
```

### Kafka Connect

```properties
value.converter=io.confluent.connect.avro.AvroConverter
value.converter.schema.registry.url=http://consolidated-sr:8081
value.converter.context.name.strategy=io.confluent.kafka.serializers.context.strategy.ContextNameStrategy
value.converter.context.name=team-a
```

### ksqlDB

```properties
ksql.schema.registry.url=http://consolidated-sr:8081
ksql.schema.registry.context.name=team-a
```

---

## Limitations

- **Version requirement.** Contexts require CP Enterprise 7.0+ (or Confluent Cloud) and compatible client libraries.
- **Schema IDs are globally unique across contexts.** The same schema in two contexts gets two different IDs. Consumers must query with the correct context.
- **ID preservation with contexts.** When using `srctl clone` with `--context`, schema IDs from the source are preserved within the target context. The IDs are globally unique within the target SR instance, but the original source IDs are maintained. Consumers configured with the correct context will resolve the same IDs they used on the source.
- **Coordination.** All affected teams must agree on timing and context naming. Keep source registries in read-only mode until cutover is verified. Migrate one source at a time.
- **Cross-context references.** Schemas referencing schemas in another context require fully qualified subject names with context prefixes.
