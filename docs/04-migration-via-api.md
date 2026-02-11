# Migration via srctl

Use `srctl` for migrating schemas between Schema Registry instances -- whether
crossing SR versions, migrating to Confluent Cloud, or needing selective control
over which subjects to migrate.

`srctl` handles dependency ordering, ID preservation, IMPORT/READWRITE mode
transitions, and error recovery automatically.

### Installation

```bash
go install github.com/akrishnanDG/srctl@latest

# Or download a prebuilt binary:
# https://github.com/akrishnanDG/srctl/releases
```

---

## srctl clone

`srctl clone` is the primary migration command. It performs a live,
registry-to-registry copy in a single step.

```bash
srctl clone \
  --url http://source-sr:8081 \
  --target-url https://target-sr.confluent.cloud \
  --target-username <API_KEY> \
  --target-password <API_SECRET> \
  --workers 100
```

Useful flags:

| Flag | Purpose |
|---|---|
| `--workers N` | Parallel registration (default 1; use 100 for large registries) |
| `--dry-run` | Preview without making changes |
| `--subjects "pattern.*"` | Include only matching subjects |
| `--exclude-subjects "internal.*"` | Exclude matching subjects |
| `--skip-mode-switch` | Skip automatic IMPORT/READWRITE toggle |

### Other srctl commands

**export + import** -- Use `srctl export` and `srctl import` when the source and
target registries cannot communicate directly (air-gapped environments). Export
produces a portable archive that can be transferred to the target network before
importing.

```bash
# Phase 1 -- export from source
srctl export --url http://source-sr:8081 --output schemas.tar.gz

# Phase 2 -- import to target
srctl import \
  --url https://target-sr.confluent.cloud \
  --username <API_KEY> --password <API_SECRET> \
  --input schemas.tar.gz \
  --workers 100
```

**backup + restore** -- Use `srctl backup` and `srctl restore` for disaster
recovery. Backup captures everything -- schemas, configs, modes, and tags -- so
you can restore a registry to a known good state.

```bash
# Backup
srctl backup --url http://source-sr:8081 --output full-backup.tar.gz

# Restore
srctl restore \
  --url https://target-sr.confluent.cloud \
  --username <API_KEY> --password <API_SECRET> \
  --input full-backup.tar.gz \
  --preserve-ids \
  --workers 100
```

Additional flags: `--restore-configs`, `--restore-modes`.

---

## Migration Flow

The full migration flow using `srctl clone`:

### 1. Clone schemas to the destination

Run `srctl clone`. The command automatically:

- Sets the destination registry to **IMPORT** mode.
- Clones all schemas in dependency order with their original IDs preserved.
- Sets the destination registry back to **READWRITE** mode.

```bash
srctl clone \
  --url http://source-sr:8081 \
  --target-url https://target-sr.confluent.cloud \
  --target-username <API_KEY> \
  --target-password <API_SECRET> \
  --workers 100
```

### 2. Set the source registry to READONLY

After the clone completes, set the source registry to READONLY to prevent
further schema changes while you cut over clients:

```bash
srctl mode --url http://source-sr:8081 --set READONLY
```

### 3. Point CI/CD and schema-registering clients to the new registry

Update any CI/CD pipelines, schema registration scripts, or applications that
register new schemas so they target the new registry. This ensures all new schema
changes go to the destination from this point forward.

### 4. Update consumer and producer configs

Reconfigure consumers and producers to read from the new registry. Because
schema IDs are preserved, serialized messages continue to deserialize correctly
against the same IDs on the destination.

---

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

**Authentication.** Confluent Cloud supports two authentication methods:

- **API keys.** Create a Schema Registry API key (`confluent api-key create
  --resource <SR_CLUSTER_ID>`) and pass it via `--username` / `--password` (or
  `--target-username` / `--target-password` for `clone`).
- **OAuth.** Configure OAuth tokens via `--bearer-token` or
  `--target-bearer-token`.

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
[Appendix](08-appendix.md) for endpoint
details and example requests.

---

## Next Steps

Proceed to [Post-Migration Validation](06-post-migration-validation.md) to
verify schemas, IDs, configurations, and modes on the target.
