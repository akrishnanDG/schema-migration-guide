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

## When to Use Contexts vs. Separate Instances

**Use contexts when** teams share infrastructure, you want centralized governance, cross-team schema discovery is valuable, or operational simplicity is the priority.

**Use separate instances when** strict tenant isolation is required, different SLAs or upgrade cadences apply, regulatory rules mandate physical separation, or teams operate in disconnected networks.

---

## Migration Approach

### Step 1: Inventory Source Registries

```bash
srctl stats --url http://sr-team-a:8081
srctl stats --url http://sr-team-b:8081
```

### Step 2: Check for Subject Name Collisions

```bash
srctl compare --url http://sr-team-a:8081 --target-url http://sr-team-b:8081
```

Collisions are safe with contexts (`:.team-a:orders-value` and `:.team-b:orders-value` are distinct).

### Step 3: Define a Context Naming Convention

| Pattern | Example | When to use |
|---|---|---|
| Team name | `team-a`, `platform` | Clusters map to teams |
| Environment | `prod-east`, `prod-west` | Consolidating regional clusters |
| Domain | `payments`, `logistics` | Domain-driven design |

### Step 4: Migrate Each Source SR into Its Own Context

Use `srctl clone` with `--context` to scope each source into the target. See [Migration via API](04-migration-via-api.md) for mechanics.

```bash
srctl clone \
  --url http://sr-team-a:8081 \
  --target-url http://consolidated-sr:8081 \
  --context team-a

srctl clone \
  --url http://sr-team-b:8081 \
  --target-url http://consolidated-sr:8081 \
  --context team-b
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

- **Version requirement.** Contexts require Confluent Platform 7.0+ and compatible client libraries.
- **Schema IDs are globally unique across contexts.** The same schema in two contexts gets two different IDs. Consumers must query with the correct context.
- **ID preservation.** Schema IDs may differ between source and target after cloning. See [Migration via API](04-migration-via-api.md) for ID translation strategies.
- **Coordination.** All affected teams must agree on timing and context naming. Keep source registries in read-only mode until cutover is verified. Migrate one source at a time.
- **Cross-context references.** Schemas referencing schemas in another context require fully qualified subject names with context prefixes.
