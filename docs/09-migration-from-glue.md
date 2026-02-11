# Migration from AWS Glue Schema Registry

This guide covers migrating from AWS Glue Schema Registry to Confluent Schema Registry (Cloud or Platform) with zero downtime using a four-phase approach.

**Tools used:**

- [glue-to-ccsr](https://github.com/akrishnanDG/glue-to-ccsr) -- Go CLI for one-time schema copy from Glue SR to Confluent SR.
- [aws-glue-confluent-sr-migration-demo](https://github.com/akrishnanDG/aws-glue-confluent-sr-migration-demo) -- Java demo showing zero-downtime consumer migration with the `secondary.deserializer` pattern.

---

## Key Differences Between Glue SR and Confluent SR

| Aspect | AWS Glue SR | Confluent SR |
|---|---|---|
| **Subject naming** | Schema name (not topic-aware) | Topic-based (`<topic>-key`, `<topic>-value`) |
| **Wire format** | `0x03` + schema version UUID | `0x00` + 4-byte schema ID |
| **Schema references** | Not supported | Fully supported |
| **Compatibility modes** | BACKWARD, FORWARD, FULL, NONE | All of the above + transitive variants |
| **API** | AWS SDK (Glue API) | REST API (HTTP) |
| **Authentication** | AWS IAM | API key/secret, mTLS, OAuth/OIDC |

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
| 3 | Migrate producers to Confluent serializer | None |
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

Glue uses schema names; Confluent uses topic-based subjects. The `naming.strategy` controls the translation:

| Strategy | Description | Example |
|----------|-------------|---------|
| `topic` (default) | Maps to topic-based subjects | `OrderEvent` -> `orders-value` |
| `record` | Uses fully qualified record name | `OrderEvent` -> `com.example.OrderEvent` |
| `llm` | AI-inferred topic and subject name | Context-dependent |
| `custom` | Go template for full control | User-defined |

Match this to your client's `subject.name.strategy` setting.

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

### Validation

```bash
srctl stats \
  --url https://psrc-XXXXX.confluent.cloud \
  --username <KEY> --password <SECRET>
```

Compare subject counts. Note that one Glue schema may produce both `-key` and `-value` subjects on the Confluent side.

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

With consumers handling both formats, switch producers from Glue to Confluent serializer one at a time.

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

Remove all `AWSSchemaRegistryConstants.*` properties, the `secondary.deserializer` property, and the Glue SR library dependency.

### Decommission Glue SR

After consumers are stable for 72+ hours:

1. Remove or disable the Glue Schema Registry.
2. Remove Glue SR IAM policies.
3. Remove `aws-glue-schema-registry` dependencies from builds.
4. Update infrastructure-as-code to remove Glue SR resources.

---

## Troubleshooting

- **IAM `AccessDeniedException`** -- Verify Glue permissions with `aws glue list-registries --region us-east-1`. See [glue-to-ccsr](https://github.com/akrishnanDG/glue-to-ccsr) for the IAM policy template.
- **Subject naming mismatches** -- Ensure `naming.strategy` in `config.yaml` matches your client's `subject.name.strategy`. Re-run with the correct strategy if needed.
- **HTTP 429 rate limiting** -- Reduce `migration.workers` in `config.yaml` (e.g., to 3).
- **Schema reference failures** -- Run `--dry-run` first. If cross-schema dependencies fail inference, register dependency schemas manually before the full migration.
- **`secondary.deserializer` not working** -- Confirm the Confluent deserializer JAR is on the classpath, `schema.registry.url` is correct, and auth properties are set. Verify schemas exist on Confluent SR with `srctl subjects list`.

---

## Post-Migration Validation

Follow [Post-Migration Validation and Cutover](06-post-migration-validation.md) for schema content verification, functional testing, and rollback planning.

Additionally confirm:
- No messages with Glue `0x03` magic byte are being written.
- Glue SR IAM roles are ready for decommissioning.
- Build configs no longer include Glue SR dependencies.

---

## References

- [glue-to-ccsr](https://github.com/akrishnanDG/glue-to-ccsr) -- Schema migration CLI
- [aws-glue-confluent-sr-migration-demo](https://github.com/akrishnanDG/aws-glue-confluent-sr-migration-demo) -- Zero-downtime demo
- [Post-Migration Validation and Cutover](06-post-migration-validation.md)
- [Multiple Schema Registries and Contexts](05-multi-sr-and-contexts.md)
- [Troubleshooting](07-troubleshooting.md)
