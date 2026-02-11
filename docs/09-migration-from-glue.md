# Migration from AWS Glue Schema Registry

This guide provides a complete, step-by-step procedure for migrating from
AWS Glue Schema Registry to Confluent Schema Registry (Cloud or Platform).
It covers the tooling, configuration, and operational steps required to
execute the migration with zero downtime using a phased approach.

The migration relies on two purpose-built tools:

- **[glue-to-ccsr](https://github.com/akrishnanDG/glue-to-ccsr)** -- a Go
  CLI for one-time schema copy from Glue SR to Confluent Cloud SR.
- **[aws-glue-confluent-sr-migration-demo](https://github.com/akrishnanDG/aws-glue-confluent-sr-migration-demo)** --
  a Java demo application showing zero-downtime consumer migration using
  the `secondary.deserializer` pattern.

---

## Overview

### Why Migrate from Glue SR to Confluent

AWS Glue Schema Registry provides basic schema management for Kafka
workloads on AWS, but organizations frequently outgrow it as their
streaming platforms mature. Common drivers for migration include:

- **Feature gaps.** Confluent Schema Registry supports schema references,
  data contracts, metadata tagging, schema linking, and compatibility
  rules that Glue SR does not offer.
- **Multi-cloud and hybrid.** Glue SR is tightly coupled to AWS. Confluent
  Schema Registry runs on any cloud provider, on-premises, or as a fully
  managed service on Confluent Cloud.
- **Ecosystem breadth.** Confluent's serializers and deserializers integrate
  natively with Kafka Connect, ksqlDB, Kafka Streams, and the broader
  Confluent ecosystem.
- **Governance.** Confluent Cloud Stream Governance provides schema
  discovery, lineage, quality rules, and audit logging that are unavailable
  with Glue SR.

### Key Differences Between Glue SR and Confluent SR

Understanding the technical differences between the two registries is
critical for planning a successful migration.

| Aspect | AWS Glue SR | Confluent SR |
|---|---|---|
| **Subject naming** | Uses the schema name (registry-level, not topic-aware) | Uses topic-based naming by default (`<topic>-key`, `<topic>-value`) |
| **Wire format magic byte** | `0x03` (Glue-specific header with compression and schema version UUID) | `0x00` (Confluent wire format with 4-byte schema ID) |
| **Schema types** | Avro, JSON Schema, Protobuf (limited) | Avro, JSON Schema, Protobuf (full support with references and imports) |
| **Schema references** | Not supported | Fully supported (cross-subject references, imports) |
| **Compatibility modes** | BACKWARD, FORWARD, FULL, NONE, DISABLED | BACKWARD, BACKWARD_TRANSITIVE, FORWARD, FORWARD_TRANSITIVE, FULL, FULL_TRANSITIVE, NONE |
| **API** | AWS SDK (Glue API) | REST API (HTTP) |
| **Authentication** | AWS IAM | API key/secret, mTLS, OAuth/OIDC |

The wire format difference is the most operationally significant. Messages
serialized with the Glue serializer start with byte `0x03` and embed a
schema version UUID. Messages serialized with the Confluent serializer
start with byte `0x00` and embed a 4-byte integer schema ID. This means
that during migration, consumers must be able to handle both wire formats
simultaneously -- this is what the `secondary.deserializer` pattern
provides.

---

## Prerequisites

Before starting the migration, ensure the following are in place.

### AWS Credentials

You need AWS credentials with read access to Glue Schema Registry. The
required IAM permissions are:

- `glue:GetRegistry`
- `glue:ListRegistries`
- `glue:GetSchema`
- `glue:ListSchemas`
- `glue:GetSchemaVersion`
- `glue:ListSchemaVersions`

For a complete IAM policy example, see the
[glue-to-ccsr repository documentation](https://github.com/akrishnanDG/glue-to-ccsr).

Credentials can be provided via environment variables, AWS CLI profile,
or IAM role (when running on EC2 or ECS).

### Confluent Cloud API Key

You need a Confluent Cloud API key and secret with permissions to write
schemas and manage subjects on the target Schema Registry cluster. The
API key must have the following resource-level permissions:

- `Subject:Read`, `Subject:Write`
- `Compatibility:Read`, `Compatibility:Write`

Generate an API key via the Confluent Cloud Console or CLI:

```bash
confluent api-key create --resource <schema-registry-cluster-id>
```

### glue-to-ccsr CLI

Install the `glue-to-ccsr` CLI using one of the following methods:

```bash
# Option 1: Go install
go install github.com/akrishnanDG/glue-to-ccsr@latest

# Option 2: Docker
docker pull ghcr.io/akrishnandg/glue-to-ccsr:latest
```

For additional installation options, see the
[glue-to-ccsr README](https://github.com/akrishnanDG/glue-to-ccsr).

### Network Access

The machine running the migration must have:

- Outbound HTTPS access to the AWS Glue API endpoint in your region
  (e.g., `glue.us-east-1.amazonaws.com`).
- Outbound HTTPS access to the Confluent Cloud Schema Registry endpoint
  (e.g., `psrc-XXXXX.us-east-1.aws.confluent.cloud` on port 443).

---

## Migration Approach Overview

The migration follows a four-phase, zero-downtime strategy. Each phase
is designed to be independently reversible.

| Phase | Action | Downtime |
|-------|--------|----------|
| 1 | Copy schemas from Glue SR to Confluent SR | None |
| 2 | Enable dual-read on consumers (`secondary.deserializer`) | Minimal (consumer restart) |
| 3 | Migrate producers gradually | None |
| 4 | Switch consumers to Confluent-only | Minimal (consumer restart) |

The key insight behind this approach is that during the transition period
(Phases 2 and 3), the Kafka topic will contain messages in both wire
formats: older messages with the Glue `0x03` header and newer messages
with the Confluent `0x00` header. The `secondary.deserializer`
configuration on consumers handles this transparently by detecting the
magic byte and routing to the appropriate deserializer.

---

## Phase 1: Schema Migration with glue-to-ccsr

Phase 1 copies all schemas from AWS Glue Schema Registry to Confluent
Schema Registry. No producers or consumers are modified during this phase.

### Configuration

Create a configuration file (`config.yaml`) for `glue-to-ccsr`:

```yaml
aws:
  region: us-east-1
  # credentials are resolved via the standard AWS credential chain:
  # environment variables, shared credentials file, IAM role, etc.

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

### Key Features

The `glue-to-ccsr` tool provides the following capabilities:

- **Multi-format support.** Handles Avro, JSON Schema, and Protobuf
  schemas from Glue SR.
- **Parallel processing.** Configurable worker pool (up to 100 workers)
  for high-throughput schema migration.
- **Schema reference handling.** Automatically detects and rewrites schema
  references to match Confluent SR's reference model.
- **Key/value schema detection.** Identifies key and value schemas and
  maps them to the appropriate Confluent subject suffixes (`-key`,
  `-value`).
- **Dry-run mode.** Preview all changes without writing to the target
  registry.
- **Resume capability.** Checkpoint-based resumption allows interrupted
  migrations to continue from where they left off.

### Naming Strategies

Glue SR uses schema names that are not topic-aware. Confluent SR uses
topic-based subject names by default. The `naming.strategy` configuration
controls how Glue schema names are translated to Confluent subject names.

| Strategy | Description | Example |
|----------|-------------|---------|
| `topic` (default) | Maps Glue schema names to topic-based subject names | `OrderEvent` becomes `orders-value` |
| `record` | Uses the fully qualified record name as the subject | `OrderEvent` becomes `com.example.OrderEvent` |
| `llm` | AI-powered naming that analyzes schema content to infer the correct topic and subject name | Context-dependent |
| `custom` | Go template-based naming for full control | User-defined template |

Choose the strategy that matches your Confluent SR subject naming
convention. If your Kafka clients use `TopicNameStrategy` (the default),
use the `topic` strategy. If your clients use `RecordNameStrategy`, use
the `record` strategy.

### Context Mapping

When migrating into a Confluent SR instance that uses contexts (see
[Multiple Schema Registries and Contexts](05-multi-sr-and-contexts.md)),
you can control how Glue registries map to Confluent contexts:

| Context Mode | Description |
|--------------|-------------|
| `flat` (default) | All schemas are placed in the default context |
| `registry-based` | Each Glue registry maps to a separate Confluent context |
| `custom` | User-defined context mapping rules |

### Running the Migration

Execute the migration:

```bash
glue-to-ccsr migrate --config config.yaml
```

For a preview without making changes:

```bash
glue-to-ccsr migrate --config config.yaml --dry-run
```

Using Docker:

```bash
docker run --rm \
  -v $(pwd)/config.yaml:/config.yaml \
  -v $HOME/.aws:/root/.aws:ro \
  ghcr.io/akrishnandg/glue-to-ccsr:latest \
  migrate --config /config.yaml
```

### Validation After Phase 1

After the migration completes, verify that all schemas arrived on the
Confluent SR:

```bash
# Check subject count and schema stats on the target
srctl stats \
  --url https://psrc-XXXXX.confluent.cloud \
  --username <KEY> \
  --password <SECRET>
```

Spot-check individual subjects to confirm schema content is correct:

```bash
srctl subjects list \
  --url https://psrc-XXXXX.confluent.cloud \
  --username <KEY> \
  --password <SECRET>
```

Compare the number of subjects on the Confluent target against the number
of schemas in Glue SR. Account for the fact that Confluent SR may have
more subjects than Glue SR has schemas, because a single Glue schema may
map to both a `-key` and `-value` subject on the Confluent side.

---

## Phase 2: Enable Dual-Read on Consumers

Phase 2 configures consumers to read messages serialized with either
the Glue wire format or the Confluent wire format. This is the critical
step that enables zero-downtime migration.

### How secondary.deserializer Works

The AWS Glue Schema Registry deserializer supports a
`secondary.deserializer` configuration property. When set, the
deserializer inspects the first byte of each message payload:

- If the magic byte is `0x03`, the message was serialized with the Glue
  serializer. The primary Glue deserializer handles it.
- If the magic byte is `0x00`, the message was serialized with the
  Confluent serializer. The secondary Confluent deserializer handles it.

This allows consumers to transparently process messages in both formats
without any application code changes.

### Consumer Configuration Changes (Java)

Add the `secondary.deserializer` property and the Confluent Schema
Registry connection details to your consumer configuration:

```java
// Existing Glue SR consumer properties
props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG,
    "com.amazonaws.services.schemaregistry.deserializers.GlueSchemaRegistryKafkaDeserializer");
props.put(AWSSchemaRegistryConstants.AWS_REGION, "us-east-1");
props.put(AWSSchemaRegistryConstants.AVRO_RECORD_TYPE, AvroRecordType.SPECIFIC_RECORD.getName());

// Add secondary deserializer for Confluent wire format
props.put("secondary.deserializer",
    "io.confluent.kafka.serializers.KafkaAvroDeserializer");

// Confluent SR connection properties (used by the secondary deserializer)
props.put("schema.registry.url", "https://psrc-XXXXX.us-east-1.aws.confluent.cloud");
props.put("basic.auth.credentials.source", "USER_INFO");
props.put("basic.auth.user.info", "<API_KEY>:<API_SECRET>");
```

### Dependencies

Ensure your project includes both the Glue and Confluent deserializer
dependencies. For Maven:

```xml
<!-- Glue SR deserializer (existing) -->
<dependency>
    <groupId>software.amazon.glue</groupId>
    <artifactId>schema-registry-serde</artifactId>
    <version>1.1.20</version>
</dependency>

<!-- Confluent SR deserializer (new) -->
<dependency>
    <groupId>io.confluent</groupId>
    <artifactId>kafka-avro-serializer</artifactId>
    <version>7.6.0</version>
</dependency>
```

### Deployment

Roll out the updated consumer configuration via a rolling restart. Each
consumer instance picks up the new configuration as it restarts. During
the restart window, there is a brief period where some instances use the
old configuration and some use the new one -- this is safe because both
configurations can read Glue-format messages.

After all consumer instances are running with the `secondary.deserializer`
configured, the consumer group can handle messages in both wire formats.

### Working Example

For a complete, runnable demo of the `secondary.deserializer` pattern, see
the [aws-glue-confluent-sr-migration-demo](https://github.com/akrishnanDG/aws-glue-confluent-sr-migration-demo)
repository. It includes:

- A producer writing Glue-format messages
- A consumer configured with `secondary.deserializer`
- A producer writing Confluent-format messages
- End-to-end verification that both wire formats are deserialized
  correctly

---

## Phase 3: Migrate Producers

With consumers now able to read both wire formats, producers can be
switched from the Glue serializer to the Confluent serializer one at a
time. There is no ordering requirement -- each producer can be migrated
independently.

### Producer Configuration Changes

Remove the Glue serializer and replace it with the Confluent serializer.

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

### Gradual Rollout

Migrate producers in the following order to minimize risk:

1. **Low-volume, non-critical producers first.** Start with internal or
   development topics to build confidence.
2. **Medium-volume producers.** Migrate business-critical producers one at
   a time, monitoring consumer success rates after each switch.
3. **High-volume producers last.** These carry the most risk and should be
   migrated only after the pattern has been validated at lower volumes.

After switching each producer, verify that:

- Messages are being serialized with the Confluent wire format (`0x00`
  magic byte).
- Consumers are successfully deserializing the new messages via the
  `secondary.deserializer` path.
- No serialization or deserialization errors appear in application logs.

---

## Phase 4: Switch Consumers to Confluent-Only

Once all producers have been migrated to the Confluent serializer, no new
messages are being written in the Glue wire format. At this point, you can
simplify consumer configurations by removing the Glue deserializer
entirely.

### Timing

Before executing Phase 4, ensure that:

- All producers have been confirmed migrated (no Glue-format messages are
  being produced).
- Consumers have processed all remaining Glue-format messages in the topic.
  The safest approach is to wait until consumer lag reaches zero on all
  partitions, confirming that all historical Glue-format messages have been
  consumed.
- If topic retention is time-based, wait until the retention period has
  elapsed so that all Glue-format messages have been expired.

### Consumer Configuration Changes

Replace the Glue deserializer with the standard Confluent deserializer:

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

Remove all AWS Glue SR properties (`AWSSchemaRegistryConstants.*`) and the
`secondary.deserializer` property. The Glue SR deserializer dependency can
also be removed from your project.

### Decommission Glue SR Resources

After all consumers have been switched to Confluent-only and have been
stable for an observation period (recommended: 72 hours minimum):

1. Remove the Glue Schema Registry from your AWS account or disable the
   schemas.
2. Remove IAM policies that granted access to the Glue SR.
3. Remove the `aws-glue-schema-registry` client library dependencies from
   all application builds.
4. Update infrastructure-as-code (Terraform, CloudFormation, CDK) to
   remove Glue SR resource definitions.

---

## Troubleshooting

### AWS IAM Permission Errors

**Symptom:** `glue-to-ccsr` fails with `AccessDeniedException` or
`UnauthorizedAccess` errors when reading from Glue SR.

**Solution:** Verify that the AWS credentials in use have the required Glue
SR permissions listed in the Prerequisites section. Test with a direct
AWS CLI call:

```bash
aws glue list-registries --region us-east-1
aws glue list-schemas --registry-id RegistryName=default --region us-east-1
```

If these commands fail, the IAM policy is missing required permissions.
See the [glue-to-ccsr repository](https://github.com/akrishnanDG/glue-to-ccsr)
for a complete IAM policy template.

### Subject Naming Mismatches

**Symptom:** After Phase 1, consumers or producers cannot find schemas on
Confluent SR because subject names do not match what the client expects.

**Solution:** This occurs when the naming strategy used by `glue-to-ccsr`
does not match the `subject.name.strategy` configured on your Kafka
clients.

1. Check what naming strategy your clients use:
   ```bash
   # Look for this in your client configuration
   value.subject.name.strategy=io.confluent.kafka.serializers.subject.TopicNameStrategy
   ```

2. Re-run `glue-to-ccsr` with the matching naming strategy in
   `config.yaml`:
   ```yaml
   naming:
     strategy: topic   # for TopicNameStrategy
     # or
     strategy: record  # for RecordNameStrategy
   ```

3. If you need custom mapping, use the `custom` strategy with a Go
   template or provide an explicit mapping file.

### Rate Limiting

**Symptom:** `glue-to-ccsr` reports HTTP 429 errors or throttling when
writing to Confluent Cloud SR.

**Solution:** Reduce the worker count in the migration configuration:

```yaml
migration:
  workers: 3  # reduce from default
```

For very large schema registries, consider running the migration in
batches using registry or prefix filters.

### Schema Reference Resolution Failures

**Symptom:** `glue-to-ccsr` fails with errors about unresolved references
when migrating schemas that depend on other schemas.

**Solution:** The tool handles references automatically in most cases.
If failures occur:

1. Run in dry-run mode first to identify problematic schemas:
   ```bash
   glue-to-ccsr migrate --config config.yaml --dry-run
   ```

2. Check that all referenced schemas exist in the Glue registry.
   Glue SR does not support formal schema references, so cross-schema
   dependencies are inferred from the schema content. If inference fails,
   you may need to register the dependency schemas manually on the
   Confluent SR before running the full migration.

### secondary.deserializer Not Working

**Symptom:** Consumers with `secondary.deserializer` configured still fail
to deserialize Confluent-format messages.

**Solution:**

1. Verify that the Confluent deserializer dependency is on the classpath.
2. Confirm the `schema.registry.url` property is set and points to the
   correct Confluent SR endpoint.
3. Confirm authentication properties (`basic.auth.credentials.source`,
   `basic.auth.user.info`) are present.
4. Check that the schemas were successfully migrated in Phase 1 by
   querying the Confluent SR directly:
   ```bash
   srctl subjects list \
     --url https://psrc-XXXXX.confluent.cloud \
     --username <KEY> \
     --password <SECRET>
   ```

For a working reference implementation, see the
[aws-glue-confluent-sr-migration-demo](https://github.com/akrishnanDG/aws-glue-confluent-sr-migration-demo).

---

## Post-Migration Validation

After completing all four phases, perform a comprehensive validation to
confirm the migration is complete and stable. Follow the procedures
documented in [Post-Migration Validation and Cutover](06-post-migration-validation.md),
which covers:

- Schema content and ID verification with `srctl compare`
- Functional testing (produce and consume end-to-end)
- Schema evolution testing on the target registry
- Rollback planning and decision criteria

Additionally, for the Glue-specific migration, confirm the following:

- No new messages are being written with the Glue wire format (`0x03`
  magic byte). Monitor consumer logs for any activity on the primary
  Glue deserializer path.
- All Glue SR IAM roles and policies have been audited and are ready for
  decommissioning.
- Application build configurations no longer include Glue SR dependencies.
- Infrastructure-as-code has been updated to remove Glue SR resources.

---

## References

- [glue-to-ccsr](https://github.com/akrishnanDG/glue-to-ccsr) --
  Go CLI for schema migration from AWS Glue SR to Confluent Cloud SR
- [aws-glue-confluent-sr-migration-demo](https://github.com/akrishnanDG/aws-glue-confluent-sr-migration-demo) --
  Java demo for zero-downtime consumer migration with `secondary.deserializer`
- [Post-Migration Validation and Cutover](06-post-migration-validation.md)
- [Multiple Schema Registries and Contexts](05-multi-sr-and-contexts.md)
- [Troubleshooting](07-troubleshooting.md)
