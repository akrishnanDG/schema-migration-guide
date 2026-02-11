# Migration from AWS Glue Schema Registry

This guide covers migrating from AWS Glue Schema Registry to Confluent Schema Registry (Cloud or Platform) with zero downtime using a four-phase approach.

**Tools used:**

- [glue-to-ccsr](https://github.com/akrishnanDG/glue-to-ccsr) -- Go CLI for one-time schema copy from Glue SR to Confluent SR.
- [aws-glue-confluent-sr-migration-demo](https://github.com/akrishnanDG/aws-glue-confluent-sr-migration-demo) -- Java demo showing zero-downtime consumer migration with the `secondary.deserializer` pattern.

---

## Key Differences Between Glue SR and Confluent SR

| Aspect | AWS Glue SR | Confluent SR |
|---|---|---|
| **Subject naming** | Schema name (not topic-aware) | Three strategies: TopicNameStrategy (`<topic>-key`, `<topic>-value`), RecordNameStrategy (`<fully.qualified.record.name>`), TopicRecordNameStrategy (`<topic>-<fully.qualified.record.name>`) |
| **Wire format** | `0x03` + schema version UUID | `0x00` + 4-byte schema ID |
| **Schema references** | Supported | Fully supported |
| **Compatibility modes** | BACKWARD, BACKWARD_ALL, FORWARD, FORWARD_ALL, FULL, FULL_ALL, NONE, DISABLED | BACKWARD, BACKWARD_TRANSITIVE, FORWARD, FORWARD_TRANSITIVE, FULL, FULL_TRANSITIVE, NONE |
| **API** | AWS SDK (Glue API) | REST API (HTTP) |
| **Authentication** | AWS IAM | API key/secret, OAuth/OIDC |

Note on compatibility mode mapping: Glue's `BACKWARD_ALL` is equivalent to Confluent's `BACKWARD_TRANSITIVE`, `FORWARD_ALL` to `FORWARD_TRANSITIVE`, and `FULL_ALL` to `FULL_TRANSITIVE`. Glue's `DISABLED` mode has no direct Confluent equivalent; use `NONE` on the Confluent side.

The wire format difference is the most significant operationally. During migration, consumers must handle both formats simultaneously -- this is what the `secondary.deserializer` pattern provides.

---

## Prerequisites

- **AWS credentials** with Glue SR read access (`glue:GetSchema`, `glue:ListSchemas`, `glue:GetSchemaVersion`, etc.). See [glue-to-ccsr docs](https://github.com/akrishnanDG/glue-to-ccsr) for the full IAM policy.
- **Confluent Cloud API key** with `Subject:Read/Write` and `Compatibility:Read/Write` permissions.
- **Network access** to both the AWS Glue API and Confluent Cloud SR endpoints.
- **glue-to-ccsr** installed (`go install github.com/akrishnanDG/glue-to-ccsr@latest` or via Docker).

---

## Migration Approach Overview

| Phase | Action | Downtime |
|-------|--------|----------|
| 1 | Copy schemas from Glue SR to Confluent SR | None |
| 2 | Enable dual-read on consumers (`secondary.deserializer`) | Minimal (consumer restart) |
| 3 | Migrate producers to Confluent serializer | Minimal (producer restart) |
| 4 | Switch consumers to Confluent-only | Minimal (consumer restart) |

During Phases 2--3, the topic contains messages in both wire formats. The `secondary.deserializer` detects the magic byte and routes to the correct deserializer.

---

## Phase 1: Schema Migration with glue-to-ccsr

Copy all schemas from Glue SR to Confluent SR. No client changes in this phase.

### Configuration

```yaml
aws:
  region: us-east-1

confluent:
  url: https://psrc-XXXXX.us-east-1.aws.confluent.cloud
  api_key: <KEY>
  api_secret: <SECRET>

naming:
  strategy: topic  # or record, llm, custom

migration:
  dry_run: false
  workers: 10
```

### Naming Strategies

Glue uses schema names; Confluent uses subject names governed by a `subject.name.strategy`. The `naming.strategy` in your `glue-to-ccsr` config controls the translation, and it must match the strategy your Kafka clients are configured with.

Confluent supports three subject naming strategies:

- **TopicNameStrategy** (default) -- Subjects are named `<topic>-key` and `<topic>-value`. All messages on a given topic must conform to the same schema.
- **RecordNameStrategy** -- Subjects are named using the fully qualified record name (e.g., `com.example.OrderEvent`). Allows multiple schema types per topic.
- **TopicRecordNameStrategy** -- Subjects are named `<topic>-<fully.qualified.record.name>` (e.g., `orders-com.example.OrderEvent`). Combines topic isolation with per-type schema evolution.

The `glue-to-ccsr` naming strategies map to these:

| Strategy | Description | Example |
|----------|-------------|---------|
| `topic` (default) | Maps to TopicNameStrategy subjects | `OrderEvent` -> `orders-value` |
| `record` | Maps to RecordNameStrategy subjects (fully qualified name) | `OrderEvent` -> `com.example.OrderEvent` |
| `llm` | AI-inferred topic and subject name | Context-dependent |
| `custom` | Go template for full control | User-defined |

Match the `naming.strategy` in your migration config to the `subject.name.strategy` configured on your Kafka clients.

### Context Mapping

| Mode | Description |
|------|-------------|
| `flat` (default) | All schemas in default context |
| `registry-based` | Each Glue registry maps to a Confluent context |
| `custom` | User-defined mapping |

### Running the Migration

```bash
# Preview changes
glue-to-ccsr migrate --config config.yaml --dry-run

# Execute
glue-to-ccsr migrate --config config.yaml
```

### Validation After Schema Copy

After the copy completes, verify the schemas arrived correctly:

```bash
# Check subject count on the target
srctl stats \
  --url https://psrc-XXXXX.confluent.cloud \
  --username <KEY> --password <SECRET>
```

Compare subject counts. Note that one Glue schema may produce both `-key` and `-value` subjects on the Confluent side. Spot-check a few subjects by retrieving the latest schema version and comparing it to the original Glue schema to confirm fidelity.

### Lock Glue SR to Read-Only

After confirming the schema copy is complete and correct, disable writes on the Glue Schema Registry to prevent any schema changes during the remainder of the migration. This ensures no new or updated schemas are registered in Glue while producers are being migrated to Confluent SR.

You can achieve this by:

- **IAM policy changes** -- Remove `glue:CreateSchema`, `glue:RegisterSchemaVersion`, and `glue:UpdateSchema` permissions from all producer roles and CI/CD pipelines.
- **Registry configuration** -- If using AWS Service Catalog or infrastructure-as-code, update the registry to a read-only state.

This guarantees that the schemas in Confluent SR remain the source of truth from this point forward.

---

## Phase 2: Enable Dual-Read on Consumers

Configure consumers to handle both Glue (`0x03`) and Confluent (`0x00`) wire formats.

### How secondary.deserializer Works

The Glue deserializer supports a `secondary.deserializer` property. It inspects the first byte of each message:

- `0x03` -- routed to the primary Glue deserializer.
- `0x00` -- routed to the secondary Confluent deserializer.

No application code changes required.

### Consumer Configuration

```java
// Primary: Glue deserializer (existing)
props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG,
    "com.amazonaws.services.schemaregistry.deserializers.GlueSchemaRegistryKafkaDeserializer");
props.put(AWSSchemaRegistryConstants.AWS_REGION, "us-east-1");
props.put(AWSSchemaRegistryConstants.AVRO_RECORD_TYPE, AvroRecordType.SPECIFIC_RECORD.getName());

// Secondary: Confluent deserializer (new)
props.put("secondary.deserializer",
    "io.confluent.kafka.serializers.KafkaAvroDeserializer");
props.put("schema.registry.url", "https://psrc-XXXXX.us-east-1.aws.confluent.cloud");
props.put("basic.auth.credentials.source", "USER_INFO");
props.put("basic.auth.user.info", "<API_KEY>:<API_SECRET>");
```

Deploy via rolling restart. Both old and new configurations can read Glue-format messages, so the restart is safe.

For a complete runnable demo, see the [aws-glue-confluent-sr-migration-demo](https://github.com/akrishnanDG/aws-glue-confluent-sr-migration-demo).

---

## Phase 3: Migrate Producers

With consumers handling both formats, switch producers from Glue to Confluent serializer one at a time. Each producer switch requires a restart or redeploy.

The AWS Glue client properties (`AWSSchemaRegistryConstants.*`, `aws.region`, `registry.name`, etc.) are completely different from Confluent client properties (`schema.registry.url`, `basic.auth.*`, etc.). This is not a matter of changing a URL -- you are replacing the entire set of serializer configuration properties.

**Before (Glue SR):**

```java
props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG,
    "com.amazonaws.services.schemaregistry.serializers.GlueSchemaRegistryKafkaSerializer");
props.put(AWSSchemaRegistryConstants.DATA_FORMAT, DataFormat.AVRO.name());
props.put(AWSSchemaRegistryConstants.AWS_REGION, "us-east-1");
props.put(AWSSchemaRegistryConstants.SCHEMA_NAME, "OrderEvent");
props.put(AWSSchemaRegistryConstants.REGISTRY_NAME, "my-registry");
```

**After (Confluent SR):**

```java
props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG,
    "io.confluent.kafka.serializers.KafkaAvroSerializer");
props.put("schema.registry.url", "https://psrc-XXXXX.us-east-1.aws.confluent.cloud");
props.put("basic.auth.credentials.source", "USER_INFO");
props.put("basic.auth.user.info", "<API_KEY>:<API_SECRET>");
props.put("auto.register.schemas", "true");
```

**Rollout order:** low-volume/non-critical producers first, then medium-volume, then high-volume. After each switch, verify consumers are deserializing successfully with no errors in logs.

---

## Phase 4: Switch Consumers to Confluent-Only

Once all producers use the Confluent serializer, simplify consumers by removing Glue dependencies.

**Before switching**, confirm:
- All producers are migrated (no new Glue-format messages).
- Consumer lag is zero (all historical Glue messages consumed).
- If using time-based retention, wait for the retention period to elapse.

The AWS Glue client properties (`AWSSchemaRegistryConstants.*`, `aws.region`, etc.) are completely different from Confluent client properties (`schema.registry.url`, `basic.auth.*`, etc.). When switching, you are removing the entire Glue property set and the `secondary.deserializer` bridge, leaving only Confluent properties.

**Before (dual-read):**

```java
props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG,
    "com.amazonaws.services.schemaregistry.deserializers.GlueSchemaRegistryKafkaDeserializer");
props.put("secondary.deserializer",
    "io.confluent.kafka.serializers.KafkaAvroDeserializer");
// ... AWS and Confluent connection properties
```

**After (Confluent-only):**

```java
props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG,
    "io.confluent.kafka.serializers.KafkaAvroDeserializer");
props.put("schema.registry.url", "https://psrc-XXXXX.us-east-1.aws.confluent.cloud");
props.put("basic.auth.credentials.source", "USER_INFO");
props.put("basic.auth.user.info", "<API_KEY>:<API_SECRET>");
```

Remove all `AWSSchemaRegistryConstants.*` properties, the `secondary.deserializer` property, and the Glue SR library dependency from your build configuration.

---

## Troubleshooting

- **IAM `AccessDeniedException`** -- Verify Glue permissions with `aws glue list-registries --region us-east-1`. See [glue-to-ccsr](https://github.com/akrishnanDG/glue-to-ccsr) for the IAM policy template.
- **Subject naming mismatches** -- Ensure `naming.strategy` in `config.yaml` matches your client's `subject.name.strategy`. Re-run with the correct strategy if needed.
- **HTTP 429 rate limiting** -- Reduce `migration.workers` in `config.yaml` (e.g., to 3).
- **Schema reference failures** -- Run `--dry-run` first. If cross-schema dependencies fail inference, register dependency schemas manually before the full migration.
- **`secondary.deserializer` not working** -- Confirm the Confluent deserializer JAR is on the classpath, `schema.registry.url` is correct, and auth properties are set. Verify schemas exist on Confluent SR with `srctl subjects list`.

---

## Post-Migration Validation

After all four phases are complete, perform Glue-specific validation to confirm the migration succeeded.

### Schema Validation

1. **Check subject count** on the target Confluent SR:

```bash
srctl stats \
  --url https://psrc-XXXXX.confluent.cloud \
  --username <KEY> --password <SECRET>
```

2. **Spot-check schemas** by retrieving a few subjects and comparing their schema definitions to the originals in Glue. Verify that field names, types, defaults, and logical types all match:

```bash
srctl subjects get <subject-name> \
  --url https://psrc-XXXXX.confluent.cloud \
  --username <KEY> --password <SECRET>
```

Note: The generic `srctl compare` command does not apply here because the source is AWS Glue (not another Confluent-compatible Schema Registry). Manual spot-checking or scripted comparison against the Glue API is the appropriate approach.

### End-to-End Functional Test

Produce a test message using the new Confluent serializer and consume it to verify the full pipeline works:

1. Produce a message to a test topic using `KafkaAvroSerializer` pointed at Confluent SR.
2. Consume the message using `KafkaAvroDeserializer` pointed at Confluent SR.
3. Verify the deserialized record matches the original.

### Wire Format Verification

Confirm no messages with the Glue `0x03` magic byte are still being written to any topic. If your monitoring supports it, sample recent messages from each topic and verify the first byte is `0x00` (Confluent format).

---

## Cutover and Decommissioning

The four-phase approach described above IS the cutover strategy. Unlike SR-to-SR migrations, there is no separate blue-green or canary cutover step -- the phased producer migration with dual-read consumers provides a gradual, safe transition.

Once all producers are on the Confluent serializer and all consumers have processed all historical Glue-format messages:

1. **Remove Glue deserializer dependencies** -- Switch all consumers to `KafkaAvroDeserializer` only (Phase 4 above). Remove the `secondary.deserializer` property.
2. **Remove Glue client libraries** -- Remove `aws-glue-schema-registry` and related AWS SDK dependencies from all application builds.
3. **Decommission Glue SR** -- After consumers are stable for 72+ hours on Confluent-only configuration:
   - Remove or disable the Glue Schema Registry.
   - Remove Glue SR IAM policies and roles.
   - Update infrastructure-as-code to remove Glue SR resources.
4. **Clean up AWS credentials** -- Remove any AWS credentials that were only used for Glue SR access.

---

## References

- [glue-to-ccsr](https://github.com/akrishnanDG/glue-to-ccsr) -- Schema migration CLI
- [aws-glue-confluent-sr-migration-demo](https://github.com/akrishnanDG/aws-glue-confluent-sr-migration-demo) -- Zero-downtime demo
- [Multiple Schema Registries and Contexts](05-multi-sr-and-contexts.md)
- [Troubleshooting](07-troubleshooting.md)
