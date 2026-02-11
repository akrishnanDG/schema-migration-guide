# Migration from Apicurio Registry

Migrate from Apicurio Registry to Confluent Schema Registry (Platform or Cloud) using [apicurio-to-confluent-sr](https://github.com/akrishnanDG/apicurio-to-confluent-sr).

---

## Key Differences

| Concept | Apicurio Registry | Confluent Schema Registry |
|---|---|---|
| Schema organization | Artifact groups and artifact IDs | Subjects (optionally with contexts) |
| Supported types | Avro, Protobuf, JSON Schema, OpenAPI, AsyncAPI, GraphQL | Avro, Protobuf, JSON Schema |
| Compatibility rules | Per-artifact and global rules (validity + compatibility) | Per-subject and global compatibility levels |
| REST API | `/apis/registry/v2/...` or `/apis/registry/v3/...` | `/subjects/...`, `/schemas/...` |
| Wire format | Custom SerDe (content ID or global ID encoded differently) | Magic byte `0x0` + 4-byte schema ID |
| Schema IDs | Global ID (int64) and content ID (int64) | Schema ID (int32) |

### Wire Format and Dual-Read with Confluent Compatibility Mode

By default, Apicurio SerDe uses its own wire format (8-byte global ID or content ID), which is incompatible with Confluent's wire format (magic byte `0x00` + 4-byte schema ID). However, Apicurio SerDe provides a **Confluent compatibility mode** that can enable dual-read during migration.

**Apicurio's `apicurio.registry.as-confluent` property** configures the serializer/deserializer to use the Confluent-compatible 4-byte integer ID format instead of the default 8-byte long. When enabled, Apicurio SerDe reads and writes messages in a format the Confluent `KafkaAvroDeserializer` can understand.

#### Migration Strategy: Dual-Read via Confluent Compatibility Mode

If your Apicurio producers are currently using the **default wire format** (8-byte IDs), follow this phased approach:

1. **Phase 1: Copy schemas** from Apicurio to Confluent SR (using `apicurio-to-confluent-sr`).
2. **Phase 2: Switch consumers to Apicurio deserializer with Confluent compatibility mode.** Configure the Apicurio deserializer to point at the **Confluent SR** and enable Confluent-compatible ID handling:

   ```java
   // Use Apicurio deserializer with Confluent compatibility mode
   props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG,
       "io.apicurio.registry.serde.avro.AvroKafkaDeserializer");
   // Point at the new Confluent SR
   props.put("apicurio.registry.url", "https://psrc-XXXXX.confluent.cloud/apis/ccompat/v7");
   props.put("apicurio.registry.as-confluent", "true");
   props.put("apicurio.auth.username", "<API_KEY>");
   props.put("apicurio.auth.password", "<API_SECRET>");
   ```

   This consumer can read **both** existing messages (Apicurio 8-byte format) and new messages (Confluent 4-byte format) by detecting the ID format at the wire level.

3. **Phase 3: Switch producers** to the Confluent `KafkaAvroSerializer` one at a time (same as the Glue migration pattern).
4. **Phase 4: Switch consumers** to the standard Confluent `KafkaAvroDeserializer` once all producers are migrated and historical Apicurio-format messages are consumed.

#### If Your Apicurio Producers Already Use Confluent Compatibility Mode

If your Apicurio environment was already configured with `apicurio.registry.as-confluent=true`, the wire format is already Confluent-compatible. In this case:

- Messages use the same 4-byte ID format as Confluent.
- The Confluent `KafkaAvroDeserializer` can read these messages directly after schema migration.
- Migration is straightforward: copy schemas, switch consumer config to Confluent SR, switch producer config to Confluent SR.

#### Fallback: Planned Cutover (No Dual-Read)

If the Apicurio `as-confluent` compatibility mode does not work for your environment (e.g., you use content IDs instead of global IDs, or your Apicurio version does not support it), the migration requires a planned cutover:

- **Big-bang** -- All producers and consumers for a topic switch at the same time during a maintenance window.
- **Blue-green** -- Deploy a parallel consumer group with Confluent SerDe, route traffic, then switch producers.
- **Topic-by-topic** -- Migrate one topic at a time with a brief pause per topic.

Plan your cutover strategy before starting the schema migration.

---

## Apicurio v2 vs v3 Differences

The tool supports both Apicurio Registry v2 and v3. Set `api_version` in your config accordingly.

| Aspect | Apicurio v2 | Apicurio v3 |
|---|---|---|
| API path | `/apis/registry/v2/...` | `/apis/registry/v3/...` |
| Schema organization | Artifact groups + artifact IDs | Same, but adds group-level operations |
| Content negotiation | Standard `Accept` headers | Different content negotiation; version-specific media types |
| Listing artifacts | `GET /apis/registry/v2/search/artifacts` | `GET /apis/registry/v3/groups/{group}/artifacts` |
| Config setting | `api_version: v2` | `api_version: v3` |

Naming conventions differ between v2 and v3. For example, v3 has stricter group handling and different default behaviors for artifact metadata. Because of these differences, you **must** use the tool's `--dry-run` mode to generate the mapping and review it before migrating. Do not assume the mapping will be the same between v2 and v3 sources -- always verify.

---

## Prerequisites

- [apicurio-to-confluent-sr](https://github.com/akrishnanDG/apicurio-to-confluent-sr) installed (`go build -o schema-migrate .`)
- Network access to both Apicurio Registry and Confluent SR
- Credentials for both registries (if auth is enabled)
- A cutover plan for producers and consumers (see Wire Format section above)

---

## Step 1: Configure

```yaml
# config.yaml
apicurio:
  url: https://your-apicurio-registry:8080
  api_version: v2          # v2 or v3 -- must match your Apicurio deployment

confluent:
  url: https://psrc-XXXXX.confluent.cloud
  auth_type: api-key
  api_key: "<API_KEY>"
  api_secret: "<API_SECRET>"
  # For Confluent Platform use auth_type: basic with username/password
```

---

## Step 2: Dry Run -- Generate the Mapping

This step is **essential**. Apicurio and Confluent have fundamentally different naming models (artifact groups/IDs vs. subjects), so the mapping between them is non-trivial and must be reviewed before any schemas are written to the destination.

```bash
./schema-migrate migrate --dry-run
```

This produces:

1. A mapping table printed to stdout showing each Apicurio artifact and its proposed Confluent subject name.
2. A `mapping.json` file on disk.
3. **Collision detection** -- if multiple Apicurio artifacts from different groups would map to the same Confluent subject, the tool flags them as collisions. These must be resolved before proceeding.

| Status | Meaning |
|--------|---------|
| `NEW` | Will be created in Confluent |
| `EXISTS (same)` | Already exists with identical content -- skipped |
| `EXISTS (different)` | Subject exists but content differs -- new version created |
| `COLLISION` | Multiple artifacts map to the same subject -- must be resolved |

---

## Step 3: Review the Mapping

Open `mapping.json` and verify every entry. The file looks like this:

```json
[
  {
    "apicurio_group": "payments",
    "apicurio_artifact_id": "OrderCreated",
    "apicurio_versions": [1, 2, 3],
    "confluent_subject": "OrderCreated-value",
    "schema_type": "AVRO",
    "status": "NEW"
  },
  {
    "apicurio_group": "payments",
    "apicurio_artifact_id": "OrderKey",
    "apicurio_versions": [1],
    "confluent_subject": "OrderKey-value",
    "schema_type": "AVRO",
    "status": "NEW"
  }
]
```

### Fixing Collisions

If two artifacts from different groups produce the same subject name, you have several options:

**Option 1: Use `topic_map` in config** to assign explicit subject names:

```yaml
mapping:
  strategy: topic-name
  topic_map:
    payments/OrderCreated: payments-orders-value
    inventory/OrderCreated: inventory-orders-value
```

**Option 2: Use `--subject-format`** to include the group in the subject name:

```bash
./schema-migrate migrate --dry-run --subject-format '{{.Group}}-{{.ArtifactId}}-{{.Type}}'
```

**Option 3: Edit `mapping.json` directly** -- change the `confluent_subject` field for colliding entries, then pass the file explicitly in Step 4.

After fixing collisions, re-run `--dry-run` (or verify your edited `mapping.json`) to confirm no collisions remain.

---

## Step 4: Migrate

```bash
# Using the reviewed mapping file (recommended)
./schema-migrate migrate --mapping-file mapping.json

# Or using auto-generated mapping (if you reviewed it via --dry-run and made no edits)
./schema-migrate migrate

# For Confluent Cloud, add rate limiting to avoid HTTP 429 errors
./schema-migrate migrate --mapping-file mapping.json --rate-limit 5
```

The tool automatically handles **IMPORT mode** on the Confluent destination when it needs to preserve schema IDs. It enables IMPORT mode, registers the schema with the specified ID, and then disables IMPORT mode. This ensures schema IDs from Apicurio are preserved where possible, which simplifies client migration.

Useful flags:

| Flag | Purpose |
|------|---------|
| `--all-versions` | Migrate all versions, not just latest |
| `--copy-compatibility` | Copy compatibility levels from Apicurio (default: true) |
| `--fail-fast` | Stop on first error |
| `--rate-limit N` | Limit to N requests/sec (recommended for Cloud) |
| `--subject-format` | Custom subject naming (Go template, e.g., `'{{.Group}}.{{.ArtifactId}}-{{.Type}}'`) |
| `--mapping-file` | Path to a reviewed `mapping.json` from a prior `--dry-run` |

The migration is idempotent -- re-running skips already-registered schemas and retries failures.

---

## Step 5: Verify

```bash
./schema-migrate compare
```

All entries should show `MATCH`. The tool uses Confluent's schema check API for semantic comparison (ignores whitespace and field ordering differences).

If any entries show `MISMATCH`, investigate the specific schema. Common causes include Apicurio-specific schema features (like OpenAPI or AsyncAPI types that have no Confluent equivalent) or version ordering differences.

---

## Step 6: Update Clients

Switch producers and consumers from Apicurio SerDe to Confluent SerDe. This requires both a dependency change and a configuration change.

### Replace SerDe Libraries

Remove the Apicurio SerDe dependency and add the Confluent equivalent.

**Maven -- Before (Apicurio):**

```xml
<dependency>
    <groupId>io.apicurio</groupId>
    <artifactId>apicurio-registry-serdes-avro-serde</artifactId>
    <version>2.x.x</version>
</dependency>
```

**Maven -- After (Confluent):**

```xml
<dependency>
    <groupId>io.confluent</groupId>
    <artifactId>kafka-avro-serializer</artifactId>
    <version>7.x.x</version>
</dependency>
```

### Update Producer Configuration

**Before (Apicurio SerDe):**

```java
props.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG,
    "io.apicurio.registry.serde.avro.AvroKafkaSerializer");
props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG,
    "io.apicurio.registry.serde.avro.AvroKafkaSerializer");
props.put("apicurio.registry.url", "https://your-apicurio-registry:8080/apis/registry/v2");
props.put("apicurio.registry.auto-register", "true");
props.put("apicurio.registry.artifact.group-id", "payments");
```

**After (Confluent SerDe):**

```java
props.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG,
    "io.confluent.kafka.serializers.KafkaAvroSerializer");
props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG,
    "io.confluent.kafka.serializers.KafkaAvroSerializer");
props.put("schema.registry.url", "https://psrc-XXXXX.confluent.cloud");
props.put("basic.auth.credentials.source", "USER_INFO");
props.put("basic.auth.user.info", "<API_KEY>:<API_SECRET>");
props.put("auto.register.schemas", "true");
```

### Update Consumer Configuration

**Before (Apicurio SerDe):**

```java
props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG,
    "io.apicurio.registry.serde.avro.AvroKafkaDeserializer");
props.put("apicurio.registry.url", "https://your-apicurio-registry:8080/apis/registry/v2");
```

**After (Confluent SerDe):**

```java
props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG,
    "io.confluent.kafka.serializers.KafkaAvroDeserializer");
props.put("schema.registry.url", "https://psrc-XXXXX.confluent.cloud");
props.put("basic.auth.credentials.source", "USER_INFO");
props.put("basic.auth.user.info", "<API_KEY>:<API_SECRET>");
```

### Key Points

- Remove all `apicurio.registry.*` properties from your configuration.
- Verify that the `subject.name.strategy` on your Confluent serializers matches the subject names you chose during the mapping step.
- Because there is no dual-read capability, **all producers and consumers for a given topic must switch at the same time** (see the Wire Format section above for cutover strategies).

---

## Step 7: Lock Down the Source Registry

After migration is complete and all clients are using Confluent SR:

1. **Set Apicurio to read-only** -- configure Apicurio's `registry.readonly` mode or remove write permissions from all service accounts. This prevents accidental schema registration against the old registry.
2. **Monitor for stragglers** -- watch Apicurio access logs for any clients still connecting. Track these down and migrate them.
3. **Decommission** -- after a stabilization period (72+ hours with no Apicurio traffic), decommission the Apicurio instance and remove it from infrastructure-as-code.

---

## Subject Name Mapping

Apicurio organizes schemas by group/artifact; Confluent uses flat subjects. The tool supports several mapping strategies:

- **Default** -- artifact ID becomes the subject name (e.g., `OrderCreated-value`)
- **Topic map** -- explicit mapping in config:
  ```yaml
  mapping:
    strategy: topic-name
    topic_map:
      payments/OrderCreated: orders
      payments/OrderKey: orders
  ```
- **Custom format** -- Go template: `--subject-format '{{.Group}}-{{.ArtifactId}}-{{.Type}}'`
- **Manual** -- edit `mapping.json` from a `--dry-run`

---

## Troubleshooting

- **"Schema being registered is incompatible"** -- subject exists in Confluent with incompatible content. Temporarily set compatibility to `NONE` or use a different subject name in `mapping.json`.
- **Subject name collisions** -- two Apicurio artifacts from different groups map to the same subject. Fix via `topic_map` in config, editing `mapping.json`, or using `--subject-format` with group prefix.
- **Rate limiting (HTTP 429)** -- use `--rate-limit 5` for Confluent Cloud.
- **IMPORT mode errors** -- the tool manages IMPORT mode automatically, but if another process is modifying the destination registry concurrently, IMPORT mode toggling may fail. Ensure no other schema operations are running during migration.
- **Partial failure** -- re-run the migration. It is idempotent and will skip completed schemas.
- **v2 vs v3 listing differences** -- if the tool reports fewer artifacts than expected, verify `api_version` in your config matches your Apicurio deployment version. A v2 tool config against a v3 registry (or vice versa) will produce incomplete results.

---

## References

- [apicurio-to-confluent-sr](https://github.com/akrishnanDG/apicurio-to-confluent-sr) -- Migration tool
- [Post-Migration Validation](06-post-migration-validation.md)
- [Multiple SRs & Contexts](05-multi-sr-and-contexts.md) -- if the target already has schemas
- [Troubleshooting](07-troubleshooting.md)
