# Migration from Apicurio Registry

Migrate from Apicurio Registry to Confluent Schema Registry (Platform or Cloud) using [apicurio-to-confluent-sr](https://github.com/akrishnanDG/apicurio-to-confluent-sr).

---

## Key Differences

| Concept | Apicurio Registry | Confluent Schema Registry |
|---|---|---|
| Schema organization | Artifact groups + artifact IDs | Subjects |
| Supported types | Avro, Protobuf, JSON Schema, OpenAPI, AsyncAPI, GraphQL | Avro, Protobuf, JSON Schema |
| Compatibility rules | Per-artifact rules (validity + compatibility) | Per-subject compatibility levels |
| Subject naming | Group/artifact-based | TopicNameStrategy, RecordNameStrategy, TopicRecordNameStrategy |

### Subject Naming

Apicurio organizes schemas as `group/artifactId`. Confluent uses subject naming strategies:

| Strategy | Pattern | When to use |
|----------|---------|-------------|
| `TopicNameStrategy` | `<topic>-key`, `<topic>-value` | Default. One schema type per topic. |
| `RecordNameStrategy` | `<fully.qualified.record.name>` | Multiple schema types per topic. Maps well to Apicurio's artifact-based model. |
| `TopicRecordNameStrategy` | `<topic>-<record.name>` | Per-topic, per-record evolution. |

`RecordNameStrategy` is often the best fit for Apicurio migrations because Apicurio's artifact IDs are typically record names, not topic names. Use the tool's `--dry-run` to generate and review the mapping before migrating.

---

## Apicurio v2 vs v3: SerDe Defaults

The defaults are very different between versions — this determines your migration strategy:

| Aspect | Apicurio 2.x | Apicurio 3.x |
|--------|-------------|-------------|
| **Default ID size** | 8 bytes — NOT Confluent-compatible | 4 bytes — Confluent-compatible |
| **Default ID type** | `globalId` | `contentId` |
| **Headers mode** | `true` — ID in Kafka headers, NOT payload | `false` — ID in payload (Confluent-compatible) |
| **`as-confluent` property** | Available | Removed (not needed) |
| **CCompat API** | v6, v7 | v7, v8 |
| **Protobuf via ccompat** | Avro only | Avro, JSON Schema, Protobuf |

**3.x** is Confluent wire-format compatible out of the box (4-byte IDs in payload).

**2.x** requires `apicurio.registry.as-confluent=true` and `apicurio.registry.headers.enabled=false` for Confluent-compatible wire format.

---

## Wire Format and Client Migration

### If already using Confluent SerDes against Apicurio (via ccompat API)

Messages are already in Confluent wire format. Copy schemas, change `schema.registry.url` to the new Confluent SR, done.

### If using Apicurio 3.x native SerDe

Wire format is Confluent-compatible (4-byte, payload-based). The Confluent `KafkaAvroDeserializer` can read these messages directly. Migrate producers one at a time; consumers can read both old and new messages without changes.

### If using Apicurio 2.x native SerDe (most common)

2.x defaults (8-byte IDs, headers mode) are NOT Confluent-compatible. Use this phased approach:

1. **Copy schemas** using `apicurio-to-confluent-sr`.
2. **Switch consumers** to Apicurio deserializer with `as-confluent=true` — this reads both old 2.x format and new Confluent format:
   ```java
   props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG,
       "io.apicurio.registry.serde.avro.AvroKafkaDeserializer");
   props.put("apicurio.registry.url", "http://apicurio:8080/apis/registry/v2");
   props.put("apicurio.registry.as-confluent", "true");
   ```
3. **Switch producers** to Confluent SerDe one at a time.
4. **Switch consumers** to Confluent SerDe once all producers are migrated and old messages are consumed.

### If 2.x with `as-confluent=true` already enabled

Wire format is already Confluent-compatible. Same as the Confluent SerDe scenario — copy schemas, change URL.

### Fallback: planned cutover

If dual-read is not feasible, switch all producers and consumers for a topic together (big-bang, blue-green, or topic-by-topic).

---

## Step 1: Configure

```yaml
apicurio:
  url: https://your-apicurio-registry:8080
  api_version: v2          # v2 or v3

confluent:
  url: https://psrc-XXXXX.confluent.cloud
  auth_type: api-key
  api_key: "<API_KEY>"
  api_secret: "<API_SECRET>"
```

## Step 2: Dry Run

```bash
./schema-migrate migrate --dry-run
```

Review the mapping table and `mapping.json`. Fix any collisions (multiple artifacts mapping to the same subject) using `topic_map` in config, `--subject-format`, or direct edits to `mapping.json`.

## Step 3: Migrate

```bash
./schema-migrate migrate --mapping-file mapping.json --rate-limit 5
```

The tool handles IMPORT mode automatically for ID preservation. The migration is idempotent.

| Flag | Purpose |
|------|---------|
| `--all-versions` | Migrate all versions, not just latest |
| `--copy-compatibility` | Copy compatibility levels (default: true) |
| `--fail-fast` | Stop on first error |
| `--rate-limit N` | Requests/sec limit (recommended for Cloud) |
| `--subject-format` | Custom naming (Go template, e.g., `'{{.Group}}-{{.ArtifactId}}-{{.Type}}'`) |

## Step 4: Verify

```bash
./schema-migrate compare
```

## Step 5: Update Clients

Replace Apicurio SerDe with Confluent SerDe (see [Wire Format and Client Migration](#wire-format-and-client-migration) for phased vs. cutover approaches):

**Before (Apicurio):**
```java
props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG,
    "io.apicurio.registry.serde.avro.AvroKafkaSerializer");
props.put("apicurio.registry.url", "http://apicurio:8080/apis/registry/v2");
props.put("apicurio.registry.auto-register", "true");
```

**After (Confluent):**
```java
props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG,
    "io.confluent.kafka.serializers.KafkaAvroSerializer");
props.put("schema.registry.url", "https://psrc-XXXXX.confluent.cloud");
props.put("basic.auth.credentials.source", "USER_INFO");
props.put("basic.auth.user.info", "<API_KEY>:<API_SECRET>");
props.put("auto.register.schemas", "true");
```

Remove all `apicurio.registry.*` properties.

## Step 6: Lock Down Source

1. Set Apicurio to read-only (`registry.readonly` or remove write permissions).
2. Monitor for straggler connections.
3. Decommission after 72+ hours with no traffic.

---

## Troubleshooting

- **Subject name collisions** — fix via `topic_map`, `--subject-format`, or `mapping.json`.
- **"Schema being registered is incompatible"** — temporarily set compatibility to `NONE` on the target.
- **Rate limiting (HTTP 429)** — use `--rate-limit 5`.
- **v2 vs v3 listing differences** — verify `api_version` matches your Apicurio version.
- **Consumer deserialization errors** — check your wire format scenario above. 2.x with headers mode requires the `as-confluent=true` bridge.

---

## References

- [apicurio-to-confluent-sr](https://github.com/akrishnanDG/apicurio-to-confluent-sr)
- [Multiple SRs & Contexts](05-multi-sr-and-contexts.md) — if the target already has schemas
- [Post-Migration Validation](06-post-migration-validation.md)
