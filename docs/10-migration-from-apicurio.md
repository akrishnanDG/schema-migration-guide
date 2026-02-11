# Migration from Apicurio Registry

Migrate from Apicurio Registry to Confluent Schema Registry (Platform or Cloud) using [apicurio-to-confluent-sr](https://github.com/akrishnanDG/apicurio-to-confluent-sr).

---

## Key Differences

| Concept | Apicurio Registry | Confluent Schema Registry |
|---|---|---|
| Schema organization | Artifact groups and artifact IDs | Subjects (optionally with contexts) |
| Supported types | Avro, Protobuf, JSON Schema, OpenAPI, AsyncAPI, GraphQL | Avro, Protobuf, JSON Schema |
| Compatibility rules | Per-artifact and global rules (validity + compatibility) | Per-subject and global compatibility levels |
| Native REST API | `/apis/registry/v2` (2.x) or `/apis/registry/v3` (3.x) | `/subjects/...`, `/schemas/...` |
| Confluent-compatible API | `/apis/ccompat/v6` (2.x), `/apis/ccompat/v7` and `/v8` (3.x) | Native |
| Schema IDs | Global ID (int64) and content ID (int64) | Schema ID (int32) |

---

## Apicurio v2 vs v3: SerDe Defaults

This is critical for migration planning — the defaults are very different between versions:

| Aspect | Apicurio 2.x | Apicurio 3.x |
|--------|-------------|-------------|
| **Default ID size** | **8 bytes** (`DefaultIdHandler`) — NOT Confluent-compatible | **4 bytes** (`Default4ByteIdHandler`) — Confluent-compatible |
| **Default ID type** | `globalId` | `contentId` |
| **Headers mode** | `true` — ID sent in Kafka headers, NOT in payload | `false` — ID sent in payload (Confluent-compatible) |
| **`as-confluent` property** | Available (`apicurio.registry.as-confluent=true`) | **Removed** — not needed since defaults are already Confluent-compatible |
| **Confluent-compatible handler** | `Legacy4ByteIdHandler` (opt-in) | `Default4ByteIdHandler` (the default) |
| **8-byte handler** | `DefaultIdHandler` (the default) | `Legacy8ByteIdHandler` (opt-in for backward compat) |
| **Migration handler** | N/A | `OptimisticFallbackIdHandler` — reads both 4-byte and 8-byte |
| **CCompat API** | v6, v7 | v7, v8 |
| **Protobuf via ccompat** | Avro only | Avro, JSON Schema, Protobuf |

**Bottom line:** Apicurio 3.x is Confluent-compatible out of the box. Apicurio 2.x requires explicit configuration (`as-confluent=true` and `headers.enabled=false`) to produce Confluent-compatible wire format.

---

## Confluent SerDe Compatibility

Apicurio Registry (both v2 and v3) exposes a **Confluent-compatible REST API** at `/apis/ccompat/v7`. Standard Confluent SerDes (`KafkaAvroSerializer` / `KafkaAvroDeserializer`) work directly against Apicurio by pointing `schema.registry.url` to the ccompat endpoint:

```java
// Confluent SerDes working against Apicurio Registry
props.put("schema.registry.url", "http://apicurio-registry:8080/apis/ccompat/v7");
```

When using Confluent SerDes against Apicurio, messages use the standard Confluent wire format (`0x00` + 4-byte ID).

---

## Wire Format and Migration Strategies

Your migration strategy depends on which SerDe and version your applications are currently using.

### Scenario A: Applications already use Confluent SerDes against Apicurio (via ccompat API)

Messages are already in Confluent wire format. Migration is: copy schemas → point `schema.registry.url` to Confluent SR → done. No wire format changes needed.

### Scenario B: Apicurio 3.x with native SerDe (default config)

3.x defaults are Confluent-compatible (4-byte IDs, payload-based). The Confluent `KafkaAvroDeserializer` can read these messages if you set `apicurio.registry.use-id=globalId` on the Apicurio serializer (since Confluent looks up schemas by globalId via the ccompat layer).

**Dual-read during migration:** Use the Confluent `KafkaAvroDeserializer` pointed at the new Confluent SR. It can read both existing 3.x messages (4-byte, Confluent-compatible) and new Confluent-serialized messages. Migrate producers one at a time.

### Scenario C: Apicurio 2.x with native SerDe (default config)

This is the most complex case. The 2.x defaults are NOT Confluent-compatible:
- IDs are 8 bytes (Confluent expects 4)
- IDs are sent in Kafka headers (Confluent expects them in the payload)

**Phase 1: Copy schemas** using `apicurio-to-confluent-sr`.

**Phase 2: Switch consumers to Apicurio deserializer with Confluent compatibility mode.** Configure the Apicurio 2.x deserializer to read both old (8-byte, headers) and new (4-byte, payload) messages:

```java
// Apicurio 2.x deserializer with Confluent compatibility — reads BOTH formats
props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG,
    "io.apicurio.registry.serde.avro.AvroKafkaDeserializer");
props.put("apicurio.registry.url", "http://apicurio-registry:8080/apis/registry/v2");
props.put("apicurio.registry.as-confluent", "true");
```

> **Note:** The Apicurio 2.x deserializer with `as-confluent=true` can read messages written with either the old 8-byte/headers format or the new 4-byte/payload format because it inspects the wire format at read time.

**Phase 3: Switch producers** to Confluent `KafkaAvroSerializer` pointed at the new Confluent SR, one at a time:

```java
props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG,
    "io.confluent.kafka.serializers.KafkaAvroSerializer");
props.put("schema.registry.url", "https://psrc-XXXXX.confluent.cloud");
props.put("basic.auth.credentials.source", "USER_INFO");
props.put("basic.auth.user.info", "<API_KEY>:<API_SECRET>");
```

**Phase 4: Switch consumers** to Confluent `KafkaAvroDeserializer` once all producers are migrated and historical Apicurio-format messages are consumed.

### Scenario D: Apicurio 2.x with `as-confluent=true` already enabled

If your 2.x environment was already configured with `apicurio.registry.as-confluent=true` and `apicurio.registry.headers.enabled=false`, the wire format is already Confluent-compatible (4-byte, payload-based). Migration follows Scenario A — copy schemas, change URL.

### Fallback: Planned cutover (no dual-read)

If none of the above dual-read approaches work for your environment:

- **Big-bang** — all producers and consumers for a topic switch simultaneously during a maintenance window.
- **Blue-green** — deploy parallel consumer group with Confluent SerDe, switch traffic, then switch producers.
- **Topic-by-topic** — migrate one topic at a time with a brief pause.

---

## Prerequisites

- [apicurio-to-confluent-sr](https://github.com/akrishnanDG/apicurio-to-confluent-sr) installed (`go build -o schema-migrate .`)
- Network access to both Apicurio Registry and Confluent SR
- Credentials for both registries (if auth is enabled)
- Know which scenario above applies to your environment (check your current SerDe config)

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

This step is **essential**. Apicurio and Confluent have fundamentally different naming models (artifact groups/IDs vs. subjects), so the mapping must be reviewed before any schemas are written. Naming conventions also differ between Apicurio v2 and v3, so always verify with `--dry-run` regardless of version.

```bash
./schema-migrate migrate --dry-run
```

This produces:

1. A mapping table showing each Apicurio artifact and its proposed Confluent subject name.
2. A `mapping.json` file on disk.
3. **Collision detection** — if multiple artifacts from different groups map to the same subject.

| Status | Meaning |
|--------|---------|
| `NEW` | Will be created in Confluent |
| `EXISTS (same)` | Already exists with identical content — skipped |
| `EXISTS (different)` | Subject exists but content differs — new version created |
| `COLLISION` | Multiple artifacts map to the same subject — must be resolved |

---

## Step 3: Review the Mapping

Open `mapping.json` and verify every entry. Fix collisions using one of:

- **`topic_map` in config** — explicit subject names per artifact
- **`--subject-format`** — Go template (e.g., `'{{.Group}}-{{.ArtifactId}}-{{.Type}}'`)
- **Edit `mapping.json` directly** — change the `confluent_subject` field

Re-run `--dry-run` after fixing to confirm no collisions remain.

---

## Step 4: Migrate

```bash
./schema-migrate migrate --mapping-file mapping.json

# For Confluent Cloud, add rate limiting
./schema-migrate migrate --mapping-file mapping.json --rate-limit 5
```

The tool handles IMPORT mode on the destination automatically for ID preservation.

| Flag | Purpose |
|------|---------|
| `--all-versions` | Migrate all versions, not just latest |
| `--copy-compatibility` | Copy compatibility levels from Apicurio (default: true) |
| `--fail-fast` | Stop on first error |
| `--rate-limit N` | Limit to N requests/sec (recommended for Cloud) |
| `--subject-format` | Custom subject naming (Go template) |
| `--mapping-file` | Path to a reviewed `mapping.json` |

The migration is idempotent — re-running skips already-registered schemas.

---

## Step 5: Verify

```bash
./schema-migrate compare
```

All entries should show `MATCH` (semantic comparison via Confluent's schema check API).

---

## Step 6: Update Clients

Replace Apicurio SerDe with Confluent SerDe. See the [Wire Format and Migration Strategies](#wire-format-and-migration-strategies) section above for phased vs. cutover approaches.

**Maven dependency change:**

```xml
<!-- Remove -->
<dependency>
    <groupId>io.apicurio</groupId>
    <artifactId>apicurio-registry-serdes-avro-serde</artifactId>
</dependency>

<!-- Add -->
<dependency>
    <groupId>io.confluent</groupId>
    <artifactId>kafka-avro-serializer</artifactId>
    <version>7.x.x</version>
</dependency>
```

**Producer config — before (Apicurio) → after (Confluent):**

```java
// Before
props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG,
    "io.apicurio.registry.serde.avro.AvroKafkaSerializer");
props.put("apicurio.registry.url", "http://apicurio:8080/apis/registry/v2");
props.put("apicurio.registry.auto-register", "true");

// After
props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG,
    "io.confluent.kafka.serializers.KafkaAvroSerializer");
props.put("schema.registry.url", "https://psrc-XXXXX.confluent.cloud");
props.put("basic.auth.credentials.source", "USER_INFO");
props.put("basic.auth.user.info", "<API_KEY>:<API_SECRET>");
props.put("auto.register.schemas", "true");
```

**Consumer config — before (Apicurio) → after (Confluent):**

```java
// Before
props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG,
    "io.apicurio.registry.serde.avro.AvroKafkaDeserializer");
props.put("apicurio.registry.url", "http://apicurio:8080/apis/registry/v2");

// After
props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG,
    "io.confluent.kafka.serializers.KafkaAvroDeserializer");
props.put("schema.registry.url", "https://psrc-XXXXX.confluent.cloud");
props.put("basic.auth.credentials.source", "USER_INFO");
props.put("basic.auth.user.info", "<API_KEY>:<API_SECRET>");
```

Remove all `apicurio.registry.*` properties.

---

## Step 7: Lock Down the Source

1. **Set Apicurio to read-only** — configure `registry.readonly` mode or remove write permissions.
2. **Monitor for stragglers** — watch Apicurio access logs for remaining connections.
3. **Decommission** — after 72+ hours with no Apicurio traffic.

---

## Troubleshooting

- **"Schema being registered is incompatible"** — temporarily set compatibility to `NONE` on the target, or use a different subject name.
- **Subject name collisions** — fix via `topic_map`, `--subject-format`, or `mapping.json` edits.
- **Rate limiting (HTTP 429)** — use `--rate-limit 5` for Confluent Cloud.
- **IMPORT mode errors** — the tool handles this automatically, but ensure no other process is modifying the target concurrently.
- **Partial failure** — re-run; idempotent.
- **v2 vs v3 listing differences** — verify `api_version` in config matches your Apicurio version.
- **Consumer deserialization errors after migration** — check which wire format scenario applies. If 2.x with default config, use `as-confluent=true` for dual-read during transition.
- **Headers-mode messages** — if Apicurio 2.x was running with default `headers.enabled=true`, the Confluent deserializer cannot read these messages. Use the Apicurio deserializer with `as-confluent=true` as a bridge during migration.

---

## References

- [apicurio-to-confluent-sr](https://github.com/akrishnanDG/apicurio-to-confluent-sr) — Migration tool
- [Apicurio ccompat API docs](https://www.apicur.io/registry/docs/apicurio-registry/2.6.x/getting-started/assembly-confluent-schema-registry-compatibility.html)
- [Post-Migration Validation](06-post-migration-validation.md)
- [Multiple SRs & Contexts](05-multi-sr-and-contexts.md) — if the target already has schemas
- [Troubleshooting](07-troubleshooting.md)
