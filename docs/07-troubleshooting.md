# Troubleshooting

This guide covers common issues encountered during Schema Registry migrations, organized by symptom. Each entry describes the problem, its underlying cause, and a practical solution with exact commands where applicable.

---

## 1. Schema ID Conflicts

**Problem**

When importing schemas into the target Schema Registry, registration fails with an error indicating that the schema ID already exists but maps to different content.

```
Error: Schema ID 1042 already exists with different content
```

**Cause**

The target Schema Registry already has schemas registered (possibly from a previous partial migration or from independent development), and those existing IDs collide with the IDs you are trying to import.

**Solution**

Before starting the migration, audit the target registry for conflicting IDs:

```bash
srctl subjects list --url http://target-sr:8081

srctl schemas list --url http://target-sr:8081 --output json | jq '.[].id' | sort -n > target_ids.txt
srctl schemas list --url http://source-sr:8081 --output json | jq '.[].id' | sort -n > source_ids.txt
comm -12 source_ids.txt target_ids.txt
```

If conflicts exist, you have two options:

1. **Clean target first.** If the target registry is disposable, delete all subjects and perform a hard reset before importing.
2. **Remap IDs.** If the target has schemas that must be preserved, use `srctl export` with `--remap-ids` to assign new, non-conflicting IDs on import. Note that this changes schema IDs, so downstream consumers must be updated or must rely on subject-based resolution rather than ID-based resolution.

---

## 2. Schema Registration Failures (Incompatible Schema)

**Problem**

Schema registration on the target fails with a compatibility error:

```
Error: Schema being registered is incompatible with an earlier schema; error code 409
```

**Cause**

The target Schema Registry has a compatibility mode set (e.g., `BACKWARD`, `FULL`) that rejects the incoming schema. This commonly happens when schemas are imported out of order, or when the target has a stricter compatibility policy than the source.

**Solution**

Temporarily set the target compatibility to `NONE` for the duration of the migration, then restore it afterward:

```bash
# Set compatibility to NONE globally
srctl compatibility set NONE --global --url http://target-sr:8081

# Run the migration
srctl import --source http://source-sr:8081 --target http://target-sr:8081

# Restore original compatibility level
srctl compatibility set BACKWARD --global --url http://target-sr:8081
```

Alternatively, set compatibility per subject if you only need to override specific subjects:

```bash
srctl compatibility set NONE --subject my-topic-value --url http://target-sr:8081
```

---

## 3. "Schema too large" Errors

**Problem**

Schema registration fails with a size limit error, typically when migrating to Confluent Cloud:

```
Error: Schema size exceeds maximum allowed size (1048576 bytes)
```

**Cause**

Confluent Cloud enforces a 1 MB limit on individual schema payloads. Monolithic schemas or schemas with deeply nested inline definitions can exceed this limit.

**Solution**

Use `srctl split` to break large schemas into smaller, referenced sub-schemas:

```bash
# Analyze the schema to see its size and structure
srctl schema inspect --subject my-large-schema-value --version latest --url http://source-sr:8081

# Split the schema into smaller referenced schemas
srctl split --subject my-large-schema-value --url http://source-sr:8081 --output ./split-schemas/

# Review the generated sub-schemas
ls -la ./split-schemas/

# Register the split schemas on the target (references first, then the root)
srctl import --from-dir ./split-schemas/ --target http://target-sr:8081
```

After splitting, verify that consumers can still resolve the schema correctly by testing deserialization against the target registry.

---

## 4. Reference Resolution Failures

**Problem**

Schema registration fails because a referenced schema cannot be found on the target:

```
Error: Reference not found: subject "com.example.Address" version 1
```

**Cause**

Schemas with references (Protobuf imports, JSON Schema `$ref`, or Avro named types registered as separate subjects) must be registered in dependency order. If a parent schema is imported before its references exist in the target, registration fails.

**Solution**

First, check for dangling references in your source registry:

```bash
srctl dangling --url http://source-sr:8081
```

This reports any schemas that reference subjects or versions that do not exist. Fix these in the source before migrating.

For the migration itself, ensure dependency ordering:

```bash
# Export with dependency resolution (srctl handles ordering automatically)
srctl export --url http://source-sr:8081 --output ./export/ --resolve-references

# Import in the correct order
srctl import --from-dir ./export/ --target http://target-sr:8081
```

If you need to manually register referenced schemas first:

```bash
# Register the referenced schema
srctl schema register --subject com.example.Address --url http://target-sr:8081 --file ./address.avsc

# Then register the schema that references it
srctl schema register --subject my-topic-value --url http://target-sr:8081 --file ./order.avsc \
  --reference "com.example.Address:com.example.Address:1"
```

---

## 5. Exporter Lag / Stuck Exporter

**Problem**

When using Schema Registry exporter (schema linking), the exporter status shows increasing lag or reports errors:

```bash
srctl exporter status --name my-exporter --url http://source-sr:8081
# Output: status=RUNNING, lag=5042, errors=3
```

**Cause**

The exporter may be stuck due to:

- Network issues between source and target
- Authentication failures on the target
- Schema incompatibility on the target
- Target registry in the wrong mode (not set to IMPORT)

**Solution**

Check the exporter status and logs for specific error details:

```bash
# Get detailed exporter status
srctl exporter status --name my-exporter --url http://source-sr:8081 --verbose

# Check exporter configuration
srctl exporter describe --name my-exporter --url http://source-sr:8081
```

If the exporter is stuck, try resetting it:

```bash
# Pause the exporter
srctl exporter pause --name my-exporter --url http://source-sr:8081

# Resume from the current position
srctl exporter resume --name my-exporter --url http://source-sr:8081
```

If the problem persists, delete and re-create the exporter. Before doing so, verify that the target is reachable, in IMPORT mode, and has the correct credentials configured.

---

## 6. Authentication/Authorization Errors

**Problem**

API calls to the target Schema Registry return `401 Unauthorized` or `403 Forbidden`:

```
Error: 401 Unauthorized - Authentication credentials missing or invalid
Error: 403 Forbidden - Not authorized to access this resource
```

**Cause**

- **401**: The API key, credentials, or bearer token is missing, expired, or malformed.
- **403**: The principal is authenticated but lacks the required permissions (e.g., missing `Subject:Write` or `Schema:Write` ACLs in Confluent Cloud).

**Solution**

Verify credentials are correct and have the necessary permissions:

```bash
# Test authentication with a simple read operation
srctl subjects list --url http://target-sr:8081 \
  --auth-key <API_KEY> --auth-secret <API_SECRET>

# For Confluent Cloud, verify the API key has the correct resource scopes
confluent api-key list --resource <schema-registry-cluster-id>
```

Ensure the service account or API key has the following permissions on the target:

- `Subject:Read`, `Subject:Write` (all subjects, or specific subjects being migrated)
- `Compatibility:Read`, `Compatibility:Write`
- `Mode:Read`, `Mode:Write` (needed to set IMPORT mode)

For `srctl` commands, pass credentials explicitly or set environment variables:

```bash
export SRCTL_TARGET_AUTH_KEY="your-api-key"
export SRCTL_TARGET_AUTH_SECRET="your-api-secret"

srctl import --source http://source-sr:8081 --target http://target-sr:8081
```

---

## 7. Network Connectivity Issues

**Problem**

Commands fail with connection errors when trying to reach the target Schema Registry:

```
Error: dial tcp 10.0.1.50:8081: connect: connection timed out
Error: no such host: target-sr.example.com
```

**Cause**

The machine running the migration tool cannot reach the target Schema Registry due to DNS resolution failure, firewall rules, VPN requirements, or incorrect URLs.

**Solution**

Verify connectivity step by step:

```bash
# Check DNS resolution
nslookup target-sr.example.com

# Test TCP connectivity
nc -zv target-sr.example.com 8081

# Test HTTPS connectivity (for Confluent Cloud)
curl -s -o /dev/null -w "%{http_code}" https://psrc-xxxxx.us-east-2.aws.confluent.cloud

# If behind a proxy, ensure proxy settings are configured
export HTTPS_PROXY=http://proxy.example.com:8080
```

For Confluent Cloud targets, ensure outbound HTTPS (port 443) is allowed to `*.confluent.cloud`. For on-premises targets, verify that the required ports (typically 8081 or 8082) are open between the migration host and the target.

If using a VPN or private link, confirm the connection is active before running the migration.

---

## 8. Client Deserialization Failures After Migration

**Problem**

After completing the migration and cutting over consumers to the new Schema Registry, consumers fail with deserialization errors:

```
org.apache.kafka.common.errors.SerializationException:
  Error retrieving Avro schema for id 42
```

**Cause**

The most common cause is that schema IDs were not preserved during migration. Kafka messages contain the schema ID in their binary header (bytes 1-4 of the payload). If the same schema was registered with a different ID on the target, consumers looking up the ID from the message will either get the wrong schema or no schema at all.

**Solution**

Verify that schema IDs match between source and target:

```bash
# Compare a specific schema ID between source and target
srctl schema get --id 42 --url http://source-sr:8081
srctl schema get --id 42 --url http://target-sr:8081
```

If IDs do not match, you must re-import with ID preservation. This requires the target to be in IMPORT mode:

```bash
srctl mode set IMPORT --global --url http://target-sr:8081

# Re-import with explicit ID preservation
srctl import --source http://source-sr:8081 --target http://target-sr:8081 --preserve-ids

srctl mode set READWRITE --global --url http://target-sr:8081
```

If re-import is not possible, an alternative is to configure consumers to use subject-based schema lookup instead of ID-based lookup by setting:

```properties
# Consumer configuration
use.latest.version=true
```

However, this approach may not be suitable for all use cases, particularly those involving schema evolution across messages in the same topic.

---

## 9. "Mode is not IMPORT" Errors

**Problem**

Schema import fails because the target registry rejects writes with preserved IDs:

```
Error: Mode is not IMPORT for subject "my-topic-value"
```

**Cause**

The target Schema Registry must be in `IMPORT` mode to accept schemas with specific IDs. By default, Schema Registry operates in `READWRITE` mode, which auto-assigns IDs and does not allow clients to specify them.

**Solution**

Set the target to IMPORT mode before starting the migration:

```bash
# Set IMPORT mode globally
srctl mode set IMPORT --global --url http://target-sr:8081

# Verify the mode is set
srctl mode get --global --url http://target-sr:8081
```

After the migration is complete, set the mode back to READWRITE:

```bash
srctl mode set READWRITE --global --url http://target-sr:8081
```

If you only want IMPORT mode for specific subjects:

```bash
srctl mode set IMPORT --subject my-topic-value --url http://target-sr:8081
```

Note: While in IMPORT mode, normal producer-driven schema registration is disabled. Plan the IMPORT window accordingly and communicate it to application teams.

---

## 10. Rate Limiting on Confluent Cloud

**Problem**

Bulk operations against Confluent Cloud fail intermittently with HTTP 429 responses:

```
Error: 429 Too Many Requests - Rate limit exceeded, retry after 1s
```

**Cause**

Confluent Cloud enforces rate limits on Schema Registry API calls. Running a migration with high parallelism or a large number of schemas can exceed these limits.

**Solution**

Reduce the concurrency of the migration by lowering the `--workers` count in `srctl`:

```bash
# Default may be too aggressive; reduce to 2-5 workers
srctl import --source http://source-sr:8081 --target https://psrc-xxxxx.confluent.cloud \
  --workers 3 \
  --auth-key <API_KEY> --auth-secret <API_SECRET>
```

If rate limiting persists even at low concurrency, add a delay between requests:

```bash
srctl import --source http://source-sr:8081 --target https://psrc-xxxxx.confluent.cloud \
  --workers 1 \
  --request-delay 500ms \
  --auth-key <API_KEY> --auth-secret <API_SECRET>
```

For very large migrations (thousands of subjects), consider breaking the migration into batches by subject prefix or by exporting subsets:

```bash
# Export only subjects matching a pattern
srctl export --url http://source-sr:8081 --output ./batch1/ --subject-prefix "team-a."

# Import the batch
srctl import --from-dir ./batch1/ --target https://psrc-xxxxx.confluent.cloud --workers 2
```

---

## 11. Subject Name Mismatches

**Problem**

After migration, producers or consumers cannot find schemas because the subject names do not match what the client expects:

```
Error: Subject 'my-topic-value' not found
```

Or schemas are registered under unexpected subject names on the target.

**Cause**

Source and target environments may use different subject naming strategies. The three standard strategies are:

- **TopicNameStrategy** (default): `<topic>-key`, `<topic>-value`
- **RecordNameStrategy**: `<fully.qualified.record.name>`
- **TopicRecordNameStrategy**: `<topic>-<fully.qualified.record.name>`

If the source uses `RecordNameStrategy` but the target clients expect `TopicNameStrategy`, the subject names will not align.

**Solution**

First, identify the naming strategy used on the source:

```bash
srctl subjects list --url http://source-sr:8081 --output json | jq -r '.[].subject' | head -20
```

If the subjects follow a pattern like `com.example.User`, the source likely uses `RecordNameStrategy`. If they follow `my-topic-value`, it is `TopicNameStrategy`.

To remap subjects during migration:

```bash
# Export with a subject name mapping file
srctl export --url http://source-sr:8081 --output ./export/ --subject-map ./subject-mapping.json
```

Where `subject-mapping.json` maps source subjects to target subjects:

```json
{
  "com.example.User": "users-topic-value",
  "com.example.Order": "orders-topic-value"
}
```

Alternatively, update the client configuration on the target environment to use the same naming strategy as the source:

```properties
value.subject.name.strategy=io.confluent.kafka.serializers.subject.RecordNameStrategy
```

---

## 12. Duplicate Schema Versions

**Problem**

After migration, a subject has more versions than expected, or the same schema content appears under multiple version numbers:

```bash
srctl schema list --subject my-topic-value --url http://target-sr:8081
# Shows versions 1, 2, 3 where versions 1 and 3 have identical content
```

**Cause**

This typically occurs when:

- The migration was run multiple times without cleaning the target first.
- Schemas were registered both via IMPORT mode (with explicit IDs) and via normal READWRITE mode (with auto-assigned IDs).
- The source itself had duplicate versions due to soft-delete and re-registration cycles.

**Solution**

Check for duplicates on the target:

```bash
srctl schemas deduplicate --url http://target-sr:8081 --dry-run
```

If duplicates are confirmed and the target has not yet been put into production, the simplest fix is to clean the target and re-run the migration:

```bash
# Delete all subjects on the target (permanent delete)
srctl subjects delete-all --url http://target-sr:8081 --permanent

# Set IMPORT mode and re-run
srctl mode set IMPORT --global --url http://target-sr:8081
srctl import --source http://source-sr:8081 --target http://target-sr:8081 --preserve-ids
srctl mode set READWRITE --global --url http://target-sr:8081
```

If the target is already in production and you cannot do a full reset, selectively soft-delete the duplicate versions:

```bash
# Delete a specific version
srctl schema delete --subject my-topic-value --version 3 --url http://target-sr:8081
```

To prevent duplicates in future migrations, always ensure the target is in IMPORT mode before starting, and avoid running the migration more than once without verifying the target state first.
