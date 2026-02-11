# Multiple Schema Registries and Contexts

## Problem Statement

In many organizations, Schema Registry clusters proliferate over time. Different teams, business units, or environments each stand up their own instance. This leads to operational overhead: more clusters to monitor, patch, and secure. Consolidating multiple Schema Registry clusters into a single instance reduces that burden, but raises a new challenge -- how to keep each team's subjects and schemas logically separated within a shared registry.

Schema Registry **contexts** solve this problem.

---

## What Are Schema Registry Contexts

Contexts are virtual namespaces within a single Schema Registry instance. They allow multiple independent sets of subjects to coexist without interfering with each other. Under the hood, a context is expressed as a prefix on the subject name, delimited by the `:.context-name:` syntax.

For example, a subject called `my-topic-value` placed in the context `team-a` becomes:

```
:.team-a:my-topic-value
```

Key characteristics:

- A single Schema Registry instance can host an arbitrary number of contexts.
- Each context maintains its own independent set of subjects and schema IDs.
- The default context (no prefix) is represented by `:.:`  or simply by omitting the context prefix entirely.
- Contexts are implicit -- they are created automatically when a schema is registered under a new context prefix.

---

## When to Use Contexts vs. Separate SR Instances

### Use contexts when

- Teams share the same infrastructure and Kafka clusters, and centralized management is preferred.
- You want a single pane of glass for schema governance across the organization.
- Cross-team schema discovery is valuable -- teams need visibility into what schemas exist elsewhere.
- Operational simplicity matters more than hard isolation.
- All teams can tolerate the same availability SLA and maintenance windows.

### Use separate instances when

- Strict tenant isolation is a hard requirement (for example, one team's outage must never impact another).
- Different clusters require different SLAs, upgrade cadences, or availability guarantees.
- Regulatory or compliance requirements mandate physical separation of data or metadata.
- Teams operate in entirely different network zones or cloud accounts with no connectivity.

---

## Migration Approach

The following steps walk through consolidating two or more source Schema Registry clusters into a single target instance, each mapped to its own context.

### Step 1: Inventory All Source Schema Registries

Start by understanding what exists in each source cluster. Gather subject counts, schema counts, and compatibility settings.

```bash
# Check each SR
srctl stats --url http://sr-team-a:8081
srctl stats --url http://sr-team-b:8081
```

Record the output for each cluster. Pay attention to the total number of subjects, the compatibility modes in use, and any mode overrides at the subject level.

### Step 2: Check for Subject Name Collisions Across SRs

Before consolidating, determine whether any subject names overlap between source registries. Collisions are not fatal when using contexts (each context is independent), but understanding overlaps helps you plan the context naming convention and anticipate any confusion.

```bash
srctl compare --url http://sr-team-a:8081 --target-url http://sr-team-b:8081
```

Review the output for subjects that appear in both registries. If you find collisions, contexts will naturally resolve them since `:.team-a:orders-value` and `:.team-b:orders-value` are distinct subjects.

### Step 3: Define a Context Naming Convention

Choose a consistent naming scheme for contexts. Common patterns include:

| Pattern | Example | When to use |
|---|---|---|
| Team name | `team-a`, `platform` | When clusters map to teams |
| Environment origin | `prod-east`, `prod-west` | When consolidating regional clusters |
| Domain name | `payments`, `logistics` | When aligning with domain-driven design |

Document the convention and communicate it to all affected teams before proceeding.

### Step 4: Migrate Each Source SR into Its Own Context

Use `srctl clone` with the `--context` flag to export all subjects and schemas from each source registry into the target, scoped under the appropriate context. For details on how the underlying migration mechanics work (subject enumeration, schema transfer, compatibility preservation), refer to [Migration via API](04-migration-via-api.md).

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

Repeat for each additional source registry, assigning a unique context to each.

### Step 5: Update Client Configurations with Context Prefix

After migration, all producers, consumers, and stream processing applications that previously pointed at a source registry must be reconfigured. There are two aspects to update:

1. **Schema Registry URL** -- point to the consolidated instance.
2. **Context awareness** -- configure clients to use the correct context prefix when registering or looking up schemas.

See the Client Configuration section below for specifics.

### Step 6: Verify the Consolidated Registry

List all contexts in the target to confirm each source was migrated successfully.

```bash
srctl contexts --url http://consolidated-sr:8081
```

You should see an entry for each context you created. Then spot-check individual contexts:

```bash
srctl subjects --url http://consolidated-sr:8081 --context team-a
srctl subjects --url http://consolidated-sr:8081 --context team-b
```

Compare the subject lists and schema counts against the inventory from Step 1 to verify completeness.

---

## Client Configuration for Contexts

Clients must be told which context to use when communicating with a context-aware Schema Registry. The mechanism varies by client type.

### Kafka Producer and Consumer (Java)

Set the `context.name.strategy` property in the serializer/deserializer configuration:

```properties
schema.registry.url=http://consolidated-sr:8081

# Tell the serializer which context to use
value.subject.name.strategy=io.confluent.kafka.serializers.subject.TopicRecordNameStrategy
context.name.strategy=io.confluent.kafka.serializers.context.strategy.ContextNameStrategy

# Specify the context name
context.name=team-a
```

### Kafka Connect

For connectors using the Avro, Protobuf, or JSON Schema converters, prefix the context configuration with the converter property path:

```properties
value.converter=io.confluent.connect.avro.AvroConverter
value.converter.schema.registry.url=http://consolidated-sr:8081
value.converter.context.name.strategy=io.confluent.kafka.serializers.context.strategy.ContextNameStrategy
value.converter.context.name=team-a
```

Apply the same pattern for `key.converter` if key schemas are also managed in the registry.

### ksqlDB

Configure ksqlDB server properties to specify the context:

```properties
ksql.schema.registry.url=http://consolidated-sr:8081
ksql.schema.registry.context.name=team-a
```

When running ksqlDB queries that consume from topics owned by different teams, you may need to override the context at the query level if your version supports it. Consult your ksqlDB documentation for context override syntax.

---

## Limitations and Caveats

### Context Support Requirements

Not all Schema Registry versions support contexts. Contexts were introduced in Confluent Platform 7.0. Verify that both your Schema Registry version and your client libraries (serializers, deserializers, converters) support context-aware operations before planning a consolidation.

### Schema ID Uniqueness Across Contexts

Schema IDs are globally unique within a single Schema Registry instance, even across contexts. This means that the same Avro schema registered in two different contexts will receive two different schema IDs. Consumers must be configured with the correct context to resolve IDs properly. If a consumer reads a message produced under context `team-a`, it must query the registry using the `team-a` context to deserialize correctly.

### ID Preservation During Migration

When cloning schemas into a new context, schema IDs in the target may not match the IDs in the source. If your applications embed schema IDs in cached lookups or external systems, you will need to account for this remapping. Review [Migration via API](04-migration-via-api.md) for strategies to handle ID translation.

### Migration Complexity

Consolidating multiple registries is not a trivial operation. Consider the following:

- **Coordination**: All teams whose registries are being consolidated must be aligned on timing and context naming.
- **Rollback plan**: Keep source registries running in read-only mode until you have verified the consolidated instance and all clients have been updated.
- **Incremental migration**: Migrate one source registry at a time rather than attempting a big-bang cutover. Validate each context before proceeding to the next.
- **Monitoring**: After migration, monitor both the consolidated registry and the client applications for deserialization errors, schema resolution failures, or unexpected registration attempts against old endpoints.

### Cross-Context Schema References

If schemas in one context reference schemas in another context (for example, a shared domain type), you will need to use fully qualified subject references that include the context prefix. This adds complexity to schema design and should be planned carefully during the context naming phase.
