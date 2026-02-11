# Migration from Apicurio Registry

Migrate from Apicurio Registry to Confluent Schema Registry (Platform or Cloud) using [apicurio-to-confluent-sr](https://github.com/akrishnanDG/apicurio-to-confluent-sr).

---

## Key Differences

| Concept | Apicurio Registry | Confluent Schema Registry |
|---|---|---|
| Schema organization | Artifact groups and artifact IDs | Subjects (optionally with contexts) |
| Supported types | Avro, Protobuf, JSON Schema, OpenAPI, AsyncAPI, GraphQL | Avro, Protobuf, JSON Schema |
| Compatibility rules | Per-artifact and global rules (validity + compatibility) | Per-subject and global compatibility levels |
| REST API | `/apis/registry/v2/...` or `/v3/...` | `/subjects/...`, `/schemas/...` |
| Wire format | Custom SerDe (content ID or global ID encoded differently) | Magic byte `0x0` + 4-byte schema ID |

The wire format difference means all producers and consumers must switch from Apicurio SerDe libraries to Confluent SerDe libraries during migration.

---

## Prerequisites

- [apicurio-to-confluent-sr](https://github.com/akrishnanDG/apicurio-to-confluent-sr) installed (`go build -o schema-migrate .`)
- Network access to both Apicurio Registry and Confluent SR
- Credentials for both registries (if auth is enabled)

---

## Step 1: Configure

```yaml
# config.yaml
apicurio:
  url: https://your-apicurio-registry:8080
  api_version: v2          # v2 or v3

confluent:
  url: https://psrc-XXXXX.confluent.cloud
  auth_type: api-key
  api_key: "<API_KEY>"
  api_secret: "<API_SECRET>"
  # For Confluent Platform use auth_type: basic with username/password
```

---

## Step 2: Dry Run

Preview the migration to see how Apicurio artifacts will map to Confluent subjects:

```bash
./schema-migrate migrate --dry-run
```

This produces a mapping table and a `mapping.json` file. The tool detects collisions (multiple Apicurio artifacts mapping to the same Confluent subject) and warns you.

| Status | Meaning |
|--------|---------|
| `NEW` | Will be created in Confluent |
| `EXISTS (same)` | Already exists with identical content — skipped |
| `EXISTS (different)` | Subject exists but content differs — new version created |

Review `mapping.json` and fix any collisions or subject name mismatches before proceeding.

---

## Step 3: Migrate

```bash
# Using auto-generated mapping
./schema-migrate migrate

# Or with a reviewed mapping file
./schema-migrate migrate --mapping-file mapping.json

# For Confluent Cloud, add rate limiting
./schema-migrate migrate --rate-limit 5
```

Useful flags:

| Flag | Purpose |
|------|---------|
| `--all-versions` | Migrate all versions, not just latest |
| `--copy-compatibility` | Copy compatibility levels from Apicurio (default: true) |
| `--fail-fast` | Stop on first error |
| `--rate-limit N` | Limit to N requests/sec (recommended for Cloud) |
| `--subject-format` | Custom subject naming (Go template, e.g., `'{{.Group}}.{{.ArtifactId}}-{{.Type}}'`) |

The migration is idempotent — re-running skips already-registered schemas and retries failures.

---

## Step 4: Verify

```bash
./schema-migrate compare
```

All entries should show `MATCH`. The tool uses Confluent's schema check API for semantic comparison (ignores whitespace and field ordering differences).

---

## Step 5: Update Clients

Switch producers and consumers from Apicurio SerDe to Confluent SerDe:

1. **Change `schema.registry.url`** from Apicurio to Confluent
2. **Update authentication** to use Confluent API key/secret or OAuth
3. **Replace SerDe libraries** — remove Apicurio SerDe dependency, add Confluent Avro/Protobuf/JSON Schema serializer
4. **Verify subject names** match what your serializers expect (depends on your `subject.name.strategy`)

---

## Subject Name Mapping

Apicurio organizes schemas by group/artifact; Confluent uses flat subjects. The tool supports several mapping strategies:

- **Default** — artifact ID becomes the subject name (e.g., `OrderCreated-value`)
- **Topic map** — explicit mapping in config:
  ```yaml
  mapping:
    strategy: topic-name
    topic_map:
      payments/OrderCreated: orders
      payments/OrderKey: orders
  ```
- **Custom format** — Go template: `--subject-format '{{.Group}}-{{.ArtifactId}}-{{.Type}}'`
- **Manual** — edit `mapping.json` from a `--dry-run`

---

## Troubleshooting

- **"Schema being registered is incompatible"** — subject exists in Confluent with incompatible content. Temporarily set compatibility to `NONE` or use a different subject name in `mapping.json`.
- **Subject name collisions** — two Apicurio artifacts from different groups map to the same subject. Fix via `topic_map` in config, editing `mapping.json`, or using `--subject-format` with group prefix.
- **Rate limiting (HTTP 429)** — use `--rate-limit 5` for Confluent Cloud.
- **Partial failure** — re-run the migration. It's idempotent and will skip completed schemas.

---

## References

- [apicurio-to-confluent-sr](https://github.com/akrishnanDG/apicurio-to-confluent-sr) — Migration tool
- [Post-Migration Validation](06-post-migration-validation.md)
- [Multiple SRs & Contexts](05-multi-sr-and-contexts.md) — if the target already has schemas
- [Troubleshooting](07-troubleshooting.md)
