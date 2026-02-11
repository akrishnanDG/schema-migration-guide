# Migration via srctl

Use `srctl` when you need a REST API-based migration — for example, when the
built-in Schema Exporter is unavailable, you are crossing incompatible SR
versions, migrating to Confluent Cloud, or you need selective control over which
subjects to migrate.

`srctl` handles dependency ordering, ID preservation, IMPORT/READWRITE mode
transitions, and error recovery automatically.

### Installation

```bash
go install github.com/akrishnanDG/srctl@latest

# Or download a prebuilt binary:
# https://github.com/akrishnanDG/srctl/releases
```

---

## Choose Your srctl Option

| Option | Command | Best for |
|---|---|---|
| **clone** (recommended) | `srctl clone` | Direct registry-to-registry copy; simplest path |
| **export + import** | `srctl export` / `srctl import` | Air-gapped environments or when you need to inspect schemas before importing |
| **backup + restore** | `srctl backup` / `srctl restore` | Full state replication including configs, modes, and tags |

---

### Option A: clone (recommended)

Live copy from source to target in a single command.

```bash
srctl clone \
  --url http://source-sr:8081 \
  --target-url https://target-sr.confluent.cloud \
  --target-username <API_KEY> \
  --target-password <API_SECRET>
```

Useful flags:

| Flag | Purpose |
|---|---|
| `--workers N` | Parallel registration (default 1) |
| `--dry-run` | Preview without making changes |
| `--subjects "pattern.*"` | Include only matching subjects |
| `--exclude-subjects "internal.*"` | Exclude matching subjects |
| `--skip-mode-switch` | Skip automatic IMPORT/READWRITE toggle |

---

### Option B: export + import (air-gapped)

Two-phase migration with a portable archive in between.

```bash
# Phase 1 — export from source
srctl export --url http://source-sr:8081 --output schemas.tar.gz

# Phase 2 — import to target
srctl import \
  --url https://target-sr.confluent.cloud \
  --username <API_KEY> --password <API_SECRET> \
  --input schemas.tar.gz
```

The archive contains all subjects, versions, compatibility configs, and mode
settings. You can inspect it (`tar tzf schemas.tar.gz`) or store it in version
control before importing.

---

### Option C: backup + restore (full state)

Captures everything — schemas, configs, modes, and tags.

```bash
# Backup
srctl backup --url http://source-sr:8081 --output full-backup.tar.gz

# Restore
srctl restore \
  --url https://target-sr.confluent.cloud \
  --username <API_KEY> --password <API_SECRET> \
  --input full-backup.tar.gz \
  --preserve-ids
```

Additional flags: `--restore-configs`, `--restore-modes`.

---

## Handling References

Schemas that reference other schemas (Protobuf imports, JSON Schema `$ref`, Avro
named-type references) must be registered in dependency order. All three `srctl`
options handle this automatically by building a dependency graph and performing a
topological sort before registration. No manual intervention is required.

## Preserving Schema IDs

ID preservation is critical: serialized Kafka messages embed the schema ID, and
consumers use it to fetch the correct schema. If IDs drift, deserialization
breaks.

`srctl clone` and `srctl restore --preserve-ids` handle this automatically by
placing the target in IMPORT mode, registering schemas with their original IDs,
and restoring READWRITE mode when finished. Use `--dry-run` to detect ID
conflicts before making changes.

---

## Confluent Cloud Specifics

**Authentication.** Create a Schema Registry API key (`confluent api-key create
--resource <SR_CLUSTER_ID>`) and pass it via `--username` / `--password` (or
`--target-username` / `--target-password` for `clone`).

**Endpoint URL.** Your SR endpoint follows the pattern
`https://psrc-XXXXX.region.aws.confluent.cloud`. Find it in the Cloud Console or
via `confluent schema-registry cluster describe`.

**Rate limits.** Confluent Cloud enforces API rate limits. `srctl` retries
automatically with backoff on HTTP 429 responses. Use a moderate `--workers`
value (4-8) for large registries. Contact Confluent support for a temporary
limit increase during large migrations.

**IMPORT mode permissions.** Your API key must have the **ResourceOwner** role
binding on the SR cluster to toggle IMPORT mode. Standard DeveloperRead/Write
roles are not sufficient.

---

## Using the REST API Directly

If you cannot install `srctl`, the same migration can be performed using `curl`
and `jq` against the Schema Registry REST API. The process involves exporting
subjects and configs, setting the target to IMPORT mode, registering schemas with
preserved IDs in dependency order, and restoring READWRITE mode. See
[Appendix B: REST API Reference](appendix-b-rest-api-reference.md) for endpoint
details and example requests.

---

## Next Steps

Proceed to [Post-Migration Validation](06-post-migration-validation.md) to
verify schemas, IDs, configurations, and modes on the target.
