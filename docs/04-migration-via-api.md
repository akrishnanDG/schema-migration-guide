# Migration via REST API and srctl

This document covers two approaches for migrating schemas between Schema Registry
instances using the REST API layer. Both approaches work across versions, across
vendors, and between self-managed and Confluent Cloud environments.

| Approach | Best For |
|---|---|
| **srctl** (Recommended) | Most migrations -- automated, safe, handles edge cases |
| **curl/jq scripts** | Environments where installing a CLI is not possible, or when you need full manual control |

---

## When to Use This Approach

Use a REST API-based migration when any of the following apply:

- **No Schema Exporter available.** Your source Schema Registry version does not
  support the built-in Exporter feature (versions prior to Confluent Platform 7.0),
  or the Exporter is not enabled.
- **Cross-version migration.** You are moving between incompatible Schema Registry
  versions where the internal `_schemas` topic format has changed.
- **Migrating to Confluent Cloud.** Cloud-managed Schema Registry does not expose
  the underlying Kafka topic, so you must use the REST API.
- **You want more control.** You need to selectively migrate specific subjects,
  transform schemas in flight, or run the migration in stages.

---

## Approach 1: Using srctl (Recommended)

[srctl](https://github.com/akrishnanDG/srctl) is a Go CLI tool purpose-built for
Schema Registry operations. It handles dependency ordering, ID preservation, mode
transitions, and error recovery automatically.

### Installation

```bash
# Install via go install
go install github.com/akrishnanDG/srctl@latest

# Or download a prebuilt binary from the releases page
# https://github.com/akrishnanDG/srctl/releases
```

Verify the installation:

```bash
srctl version
```

---

### Option A: srctl clone (Direct Registry-to-Registry Copy)

The `clone` command performs a direct, live copy from one Schema Registry to another
in a single operation. This is the fastest and simplest path for most migrations.

```bash
# Clone all schemas from source to target with ID preservation
srctl clone \
  --url http://source-sr:8081 \
  --target-url https://target-sr.confluent.cloud \
  --target-username <API_KEY> \
  --target-password <API_SECRET>
```

**What `clone` does automatically:**

1. Reads all subjects and schema versions from the source registry.
2. Builds a dependency graph and performs a topological sort so that referenced
   schemas (e.g., Protobuf imports, Avro schema references) are registered before
   the schemas that depend on them.
3. Sets the target registry to **IMPORT** mode.
4. Registers each schema on the target, preserving the original schema ID by
   including the `id` field in the registration request.
5. Restores per-subject compatibility settings and mode configurations.
6. Sets the target registry back to **READWRITE** mode.

**Useful flags:**

| Flag | Description |
|---|---|
| `--workers N` | Number of parallel workers for multi-threaded registration (default: 1). Increase for large registries. |
| `--dry-run` | Show what would be migrated without making changes. |
| `--subjects "prefix.*"` | Filter subjects by regex pattern. |
| `--exclude-subjects "internal.*"` | Exclude subjects matching a pattern. |
| `--skip-mode-switch` | Do not automatically toggle IMPORT/READWRITE mode on the target (useful if you manage mode externally). |

**Example with parallel workers and subject filtering:**

```bash
srctl clone \
  --url http://source-sr:8081 \
  --target-url http://target-sr:8081 \
  --workers 8 \
  --subjects "orders-.*" \
  --dry-run
```

Remove `--dry-run` once you have confirmed the plan looks correct.

---

### Option B: srctl export + import (Two-Phase with Intermediate Files)

The export/import workflow splits the migration into two discrete steps with a
portable archive file in between. This is ideal for air-gapped environments, for
auditing schemas before importing, or when source and target cannot communicate
directly.

**Phase 1: Export**

```bash
# Export all schemas to a tar.gz archive
srctl export --url http://source-sr:8081 --output schemas-backup.tar.gz
```

The archive contains:

- All subjects and their schema versions (in JSON format).
- Per-subject compatibility configurations.
- Mode settings (global and per-subject).
- Metadata needed to preserve schema IDs on import.

You can inspect the contents before proceeding:

```bash
tar tzf schemas-backup.tar.gz
```

**Phase 2: Import**

```bash
# Import to target
srctl import --url https://target-sr.confluent.cloud \
  --username <API_KEY> --password <API_SECRET> \
  --input schemas-backup.tar.gz
```

The import phase performs automatic dependency ordering (topological sort) to ensure
referenced schemas are registered before dependent schemas.

**When to use export + import instead of clone:**

- The source and target environments are network-isolated (air-gapped).
- You want to inspect, review, or transform the exported schemas before importing.
- You need a portable backup file that can be stored in version control or artifact
  storage.
- The migration must be performed by different teams at different times (one team
  exports, another imports).

---

### Option C: srctl backup + restore (Full Backup Including Configs, Modes, Tags)

The `backup` and `restore` commands capture the complete state of a Schema Registry,
including not just schemas but also all configuration, mode settings, and tags. This
is the most comprehensive option.

```bash
# Full backup
srctl backup --url http://source-sr:8081 --output full-backup.tar.gz

# Full restore to target
srctl restore --url https://target-sr.confluent.cloud \
  --username <API_KEY> --password <API_SECRET> \
  --input full-backup.tar.gz \
  --preserve-ids
```

| Flag | Description |
|---|---|
| `--preserve-ids` | Preserve original schema IDs on the target (sets IMPORT mode automatically). |
| `--restore-configs` | Restore global and per-subject compatibility configurations. |
| `--restore-modes` | Restore global and per-subject mode settings. |

Use `backup + restore` when you need a complete, faithful replica of the source
registry state, including all metadata.

---

## Approach 2: Using REST API / Scripts

If you cannot install `srctl` or need full manual control, you can perform the
migration using `curl` and `jq` against the Schema Registry REST API directly.

The process follows these steps:

1. Export all subjects and schemas from the source.
2. Export global and per-subject compatibility configurations.
3. Export mode settings.
4. Set the target registry to IMPORT mode.
5. Register schemas in correct version order, preserving IDs.
6. Restore compatibility and mode settings on the target.
7. Set the target back to READWRITE mode.
8. Validate.

Reference scripts are provided at `scripts/export-schemas.sh` and
`scripts/import-schemas.sh`. The curl examples below illustrate each step
individually.

### Step 1: Export All Subjects and Schemas

Retrieve the full list of subjects:

```bash
# List all subjects
curl -s http://source-sr:8081/subjects | jq .
```

For each subject, retrieve all versions and their schemas:

```bash
# Get all versions for a subject
SUBJECT="orders-value"
VERSIONS=$(curl -s "http://source-sr:8081/subjects/${SUBJECT}/versions")

# For each version, get the full schema (including ID and references)
for VERSION in $(echo "$VERSIONS" | jq -r '.[]'); do
  curl -s "http://source-sr:8081/subjects/${SUBJECT}/versions/${VERSION}" | \
    jq '{subject: .subject, version: .version, id: .id, schemaType: .schemaType, schema: .schema, references: .references}' \
    >> schemas-export.json
done
```

A complete export script that iterates over all subjects:

```bash
#!/usr/bin/env bash
# scripts/export-schemas.sh

SOURCE_URL="${1:-http://localhost:8081}"
OUTPUT_DIR="exported-schemas"
mkdir -p "$OUTPUT_DIR"

# Export all subjects and their versions
SUBJECTS=$(curl -s "${SOURCE_URL}/subjects" | jq -r '.[]')

for SUBJECT in $SUBJECTS; do
  echo "Exporting subject: ${SUBJECT}"
  VERSIONS=$(curl -s "${SOURCE_URL}/subjects/${SUBJECT}/versions" | jq -r '.[]')

  for VERSION in $VERSIONS; do
    SCHEMA_DATA=$(curl -s "${SOURCE_URL}/subjects/${SUBJECT}/versions/${VERSION}")
    SAFE_SUBJECT=$(echo "$SUBJECT" | tr '/' '_')
    echo "$SCHEMA_DATA" > "${OUTPUT_DIR}/${SAFE_SUBJECT}_v${VERSION}.json"
  done
done

# Export global compatibility config
curl -s "${SOURCE_URL}/config" | jq . > "${OUTPUT_DIR}/_global_config.json"

# Export per-subject compatibility configs
for SUBJECT in $SUBJECTS; do
  CONFIG=$(curl -s "${SOURCE_URL}/config/${SUBJECT}" 2>/dev/null)
  if echo "$CONFIG" | jq -e '.compatibilityLevel' > /dev/null 2>&1; then
    SAFE_SUBJECT=$(echo "$SUBJECT" | tr '/' '_')
    echo "$CONFIG" > "${OUTPUT_DIR}/${SAFE_SUBJECT}_config.json"
  fi
done

# Export global mode
curl -s "${SOURCE_URL}/mode" | jq . > "${OUTPUT_DIR}/_global_mode.json"

echo "Export complete. Files written to ${OUTPUT_DIR}/"
```

### Step 2: Export Compatibility Configuration

```bash
# Global compatibility level
curl -s http://source-sr:8081/config | jq .

# Per-subject compatibility level
curl -s "http://source-sr:8081/config/${SUBJECT}" | jq .
```

### Step 3: Export Mode Settings

```bash
# Global mode
curl -s http://source-sr:8081/mode | jq .

# Per-subject mode (if set)
curl -s "http://source-sr:8081/mode/${SUBJECT}" | jq .
```

### Step 4: Set Target to IMPORT Mode

The target registry must be in IMPORT mode to accept schemas with specific IDs.
Without this, the target will assign new IDs and you will lose ID alignment with
your Kafka data.

```bash
# Set global mode to IMPORT on the target
curl -s -X PUT \
  -H "Content-Type: application/json" \
  -d '{"mode": "IMPORT"}' \
  https://target-sr:8081/mode

# Verify
curl -s https://target-sr:8081/mode | jq .
# Expected: {"mode": "IMPORT"}
```

For Confluent Cloud targets, include authentication:

```bash
curl -s -X PUT \
  -u "<API_KEY>:<API_SECRET>" \
  -H "Content-Type: application/json" \
  -d '{"mode": "IMPORT"}' \
  "https://psrc-XXXXX.region.aws.confluent.cloud/mode"
```

### Step 5: Register Schemas Preserving IDs

Register each schema on the target with the original ID by including the `id` field
in the request body. Schemas must be registered in version order within each subject,
and dependency schemas must be registered before schemas that reference them.

```bash
# Register a schema with a specific ID
SUBJECT="orders-value"
SCHEMA_ID=42

# Read the schema string from the exported file
SCHEMA=$(cat exported-schemas/orders-value_v1.json | jq -r '.schema')
SCHEMA_TYPE=$(cat exported-schemas/orders-value_v1.json | jq -r '.schemaType // "AVRO"')
REFERENCES=$(cat exported-schemas/orders-value_v1.json | jq -c '.references // []')

curl -s -X POST \
  -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  -d "{
    \"schema\": $(echo "$SCHEMA" | jq -R .),
    \"schemaType\": \"${SCHEMA_TYPE}\",
    \"id\": ${SCHEMA_ID},
    \"references\": ${REFERENCES}
  }" \
  "https://target-sr:8081/subjects/${SUBJECT}/versions"
```

**Important:** The `id` field in the POST body tells the registry to assign that
specific ID to the schema. This only works when the registry is in IMPORT mode.

A complete import script:

```bash
#!/usr/bin/env bash
# scripts/import-schemas.sh

TARGET_URL="${1:-http://localhost:8081}"
INPUT_DIR="${2:-exported-schemas}"
AUTH_HEADER=""

# If credentials provided, set auth header
if [ -n "$SR_USERNAME" ] && [ -n "$SR_PASSWORD" ]; then
  AUTH_HEADER="-u ${SR_USERNAME}:${SR_PASSWORD}"
fi

# Step 1: Set target to IMPORT mode
echo "Setting target to IMPORT mode..."
curl -s -X PUT $AUTH_HEADER \
  -H "Content-Type: application/json" \
  -d '{"mode": "IMPORT"}' \
  "${TARGET_URL}/mode"

# Step 2: Restore global compatibility config
if [ -f "${INPUT_DIR}/_global_config.json" ]; then
  COMPAT=$(cat "${INPUT_DIR}/_global_config.json" | jq -r '.compatibilityLevel')
  curl -s -X PUT $AUTH_HEADER \
    -H "Content-Type: application/json" \
    -d "{\"compatibility\": \"${COMPAT}\"}" \
    "${TARGET_URL}/config"
fi

# Step 3: Register schemas in order (sort by version)
for SCHEMA_FILE in $(ls "${INPUT_DIR}"/*.json | grep -v '_config\|_mode\|_global' | sort -t'v' -k2 -n); do
  SUBJECT=$(cat "$SCHEMA_FILE" | jq -r '.subject')
  VERSION=$(cat "$SCHEMA_FILE" | jq -r '.version')
  SCHEMA_ID=$(cat "$SCHEMA_FILE" | jq -r '.id')
  SCHEMA=$(cat "$SCHEMA_FILE" | jq -r '.schema')
  SCHEMA_TYPE=$(cat "$SCHEMA_FILE" | jq -r '.schemaType // "AVRO"')
  REFERENCES=$(cat "$SCHEMA_FILE" | jq -c '.references // []')

  echo "Registering ${SUBJECT} v${VERSION} (ID: ${SCHEMA_ID})..."

  RESPONSE=$(curl -s -X POST $AUTH_HEADER \
    -H "Content-Type: application/vnd.schemaregistry.v1+json" \
    -d "{
      \"schema\": $(echo "$SCHEMA" | jq -R .),
      \"schemaType\": \"${SCHEMA_TYPE}\",
      \"id\": ${SCHEMA_ID},
      \"references\": ${REFERENCES}
    }" \
    "${TARGET_URL}/subjects/${SUBJECT}/versions")

  echo "  Response: ${RESPONSE}"
done

# Step 4: Restore per-subject compatibility configs
for CONFIG_FILE in $(ls "${INPUT_DIR}"/*_config.json 2>/dev/null | grep -v '_global'); do
  SUBJECT=$(echo "$CONFIG_FILE" | sed 's|.*/||; s|_config\.json||' | tr '_' '/')
  COMPAT=$(cat "$CONFIG_FILE" | jq -r '.compatibilityLevel')
  echo "Setting compatibility for ${SUBJECT}: ${COMPAT}"

  curl -s -X PUT $AUTH_HEADER \
    -H "Content-Type: application/json" \
    -d "{\"compatibility\": \"${COMPAT}\"}" \
    "${TARGET_URL}/config/${SUBJECT}"
done

# Step 5: Set target back to READWRITE mode
echo "Setting target back to READWRITE mode..."
curl -s -X PUT $AUTH_HEADER \
  -H "Content-Type: application/json" \
  -d '{"mode": "READWRITE"}' \
  "${TARGET_URL}/mode"

echo "Import complete."
```

### Step 6: Restore Compatibility and Mode Settings

```bash
# Restore global compatibility
curl -s -X PUT \
  -H "Content-Type: application/json" \
  -d '{"compatibility": "BACKWARD"}' \
  https://target-sr:8081/config

# Restore per-subject compatibility
curl -s -X PUT \
  -H "Content-Type: application/json" \
  -d '{"compatibility": "FULL_TRANSITIVE"}' \
  "https://target-sr:8081/config/${SUBJECT}"
```

### Step 7: Set Target Back to READWRITE

```bash
curl -s -X PUT \
  -H "Content-Type: application/json" \
  -d '{"mode": "READWRITE"}' \
  https://target-sr:8081/mode

# Verify
curl -s https://target-sr:8081/mode | jq .
# Expected: {"mode": "READWRITE"}
```

### Step 8: Validate

See [Post-Migration Validation](06-post-migration-validation.md) for the full
validation checklist. A quick sanity check:

```bash
# Compare subject counts
SOURCE_COUNT=$(curl -s http://source-sr:8081/subjects | jq 'length')
TARGET_COUNT=$(curl -s https://target-sr:8081/subjects | jq 'length')
echo "Source subjects: ${SOURCE_COUNT}, Target subjects: ${TARGET_COUNT}"

# Spot-check a specific schema ID
curl -s http://source-sr:8081/schemas/ids/1 | jq .schema > /tmp/source-schema.json
curl -s https://target-sr:8081/schemas/ids/1 | jq .schema > /tmp/target-schema.json
diff /tmp/source-schema.json /tmp/target-schema.json
```

---

## Handling Schema References

Schemas can reference other schemas. This is common with:

- **Protobuf:** `import` statements that pull in other `.proto` definitions.
- **JSON Schema:** `$ref` pointers to external schema documents.
- **Avro:** Named types referenced across schemas (using the `references` field in
  Confluent Schema Registry).

When a schema has references, the referenced schema must already exist in the target
registry before the dependent schema can be registered. Registering in the wrong
order will produce a `422 Unprocessable Entity` error.

### How srctl Handles References

`srctl` automatically builds a directed acyclic graph (DAG) of schema dependencies
and performs a topological sort before registration. No manual intervention is
required. This is one of the primary advantages of using `srctl` over manual scripts.

### Manual Ordering for REST API Scripts

If you are using the manual REST API approach, you must determine the correct
registration order yourself. The process is:

1. For each schema version, inspect the `references` field in the GET response:

   ```bash
   curl -s "http://source-sr:8081/subjects/orders-value/versions/1" | jq '.references'
   ```

   A schema with references will return something like:

   ```json
   [
     {
       "name": "com.example.Address",
       "subject": "address-value",
       "version": 1
     }
   ]
   ```

2. Build a dependency list. For the example above, `address-value` version 1 must
   be registered on the target before `orders-value` version 1.

3. Sort all schemas topologically: schemas with no references come first, then
   schemas whose references are already satisfied, and so on.

4. Register in topological order.

A simple approach when the number of schemas is small: attempt to register all
schemas in a loop, retrying failures. Schemas that fail because their references
are missing will succeed in a subsequent pass once the dependencies have been
registered. Repeat until all schemas are registered or no progress is made.

```bash
# Naive retry loop for dependency ordering
MAX_PASSES=10
PASS=1
REMAINING=$(ls exported-schemas/*.json | grep -v '_config\|_mode\|_global')

while [ -n "$REMAINING" ] && [ $PASS -le $MAX_PASSES ]; do
  echo "Pass ${PASS}..."
  FAILED=""

  for SCHEMA_FILE in $REMAINING; do
    # Attempt registration (same curl as Step 5 above)
    RESPONSE=$(curl -s -X POST ... "${TARGET_URL}/subjects/${SUBJECT}/versions")

    ERROR_CODE=$(echo "$RESPONSE" | jq -r '.error_code // empty')
    if [ -n "$ERROR_CODE" ]; then
      FAILED="${FAILED} ${SCHEMA_FILE}"
    fi
  done

  REMAINING="$FAILED"
  PASS=$((PASS + 1))
done

if [ -n "$REMAINING" ]; then
  echo "ERROR: The following schemas could not be registered:"
  echo "$REMAINING"
  exit 1
fi
```

---

## Preserving Schema IDs

Preserving schema IDs across the migration is **critical** for SerDe (serializer /
deserializer) compatibility. Here is why:

- When a Kafka producer serializes a message using the Confluent Avro/Protobuf/JSON
  Schema serializer, the serialized payload includes a **magic byte** (0x0) followed
  by the **4-byte schema ID**.
- When a consumer deserializes the message, it uses that schema ID to fetch the
  schema from the Schema Registry.
- If schema IDs on the target registry do not match the IDs embedded in existing
  Kafka messages, consumers will either fail to deserialize or fetch the wrong schema.

### IMPORT Mode

Schema Registry must be placed in **IMPORT mode** to accept schema registrations
with caller-specified IDs. In the default READWRITE mode, the registry assigns IDs
automatically and ignores the `id` field in the request body.

```bash
# Enable IMPORT mode
curl -s -X PUT \
  -H "Content-Type: application/json" \
  -d '{"mode": "IMPORT"}' \
  https://target-sr:8081/mode
```

### The id Field in Registration Requests

When IMPORT mode is active, include the `id` field in the POST body:

```json
{
  "schema": "{\"type\": \"record\", \"name\": \"Order\", ...}",
  "schemaType": "AVRO",
  "id": 42
}
```

The registry will assign ID 42 to this schema. If ID 42 is already taken by a
different schema, the request will fail with a conflict error.

### When IDs Cannot Be Preserved

In some cases, ID preservation may not be possible:

- The target registry already contains schemas with conflicting IDs.
- You are merging schemas from multiple source registries into a single target.

In these situations, you will need to re-serialize existing Kafka data or accept
that consumers must be restarted with the new registry (and only process messages
produced after the migration).

`srctl clone` will detect ID conflicts during `--dry-run` and report them before
making any changes.

---

## Confluent Cloud Specifics

When migrating to or from Confluent Cloud Schema Registry, note the following
differences from self-managed deployments.

### Authentication

Confluent Cloud Schema Registry uses API key pairs for authentication. Create a
Schema Registry API key in the Confluent Cloud Console or via the CLI:

```bash
confluent api-key create --resource <SR_CLUSTER_ID>
```

Use the key and secret with HTTP Basic Auth:

```bash
# With curl
curl -u "<API_KEY>:<API_SECRET>" https://psrc-XXXXX.region.aws.confluent.cloud/subjects

# With srctl
srctl clone \
  --url http://source-sr:8081 \
  --target-url https://psrc-XXXXX.region.aws.confluent.cloud \
  --target-username <API_KEY> \
  --target-password <API_SECRET>
```

### Endpoint URLs

Confluent Cloud Schema Registry endpoints follow this pattern:

```
https://psrc-XXXXX.region.aws.confluent.cloud
```

Find your endpoint in the Confluent Cloud Console under your environment's Schema
Registry settings, or via the CLI:

```bash
confluent schema-registry cluster describe
```

### Rate Limits

Confluent Cloud imposes rate limits on the Schema Registry API. When migrating
large registries (hundreds or thousands of schemas), you may encounter HTTP 429
(Too Many Requests) responses.

Recommendations:

- **With srctl:** Use a moderate `--workers` value (4-8). `srctl` handles HTTP 429
  responses with automatic backoff and retry.
- **With manual scripts:** Add a delay between registration calls:

  ```bash
  # Add a 200ms delay between registrations
  sleep 0.2
  ```

- If you encounter persistent rate limiting, contact Confluent support to request
  a temporary rate limit increase during the migration window.

### Confluent Cloud Mode Restrictions

To set Confluent Cloud Schema Registry to IMPORT mode, your API key must have the
**ResourceOwner** role binding on the Schema Registry cluster. Standard
DeveloperRead/DeveloperWrite roles are not sufficient.

```bash
# Assign ResourceOwner role (requires Organization Admin or Environment Admin)
confluent iam rbac role-binding create \
  --principal User:<service_account_id> \
  --role ResourceOwner \
  --resource "Topic:*" \
  --schema-registry-cluster <SR_CLUSTER_ID>
```

---

## Comparison: srctl vs. Manual Scripts

| Capability | srctl | Manual curl/jq |
|---|---|---|
| Dependency ordering (topological sort) | Automatic | Manual or retry loop |
| ID preservation | Automatic (`clone`, `restore --preserve-ids`) | Must include `id` field and set IMPORT mode manually |
| IMPORT/READWRITE mode management | Automatic | Manual |
| Parallel registration | `--workers` flag | Must implement manually |
| Dry run / preview | `--dry-run` | Not available |
| Error handling and retry | Built-in with backoff | Must implement manually |
| Air-gapped support | `export` + `import` | Must implement file handling |
| Partial / filtered migration | `--subjects`, `--exclude-subjects` | Must filter manually |
| Confluent Cloud auth | `--username` / `--password` flags | `-u` flag with curl |

---

## Next Steps

After completing the migration using either approach, proceed to
[Post-Migration Validation](06-post-migration-validation.md) to verify that all
schemas, IDs, configurations, and modes have been transferred correctly.
