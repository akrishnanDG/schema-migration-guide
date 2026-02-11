# Troubleshooting

Common issues during Schema Registry migrations, organized by symptom.

---

## 1. Schema ID Conflicts

**Problem:** Import fails with `Schema ID 1042 already exists with different content`.

**Cause:** The target registry already has schemas whose IDs collide with the source.

**Solution:** Audit for conflicts, then either clean the target or remap IDs:
```bash
comm -12 <(srctl schemas list --url http://source-sr:8081 --output json | jq '.[].id' | sort -n) \
         <(srctl schemas list --url http://target-sr:8081 --output json | jq '.[].id' | sort -n)
srctl export --remap-ids --url http://source-sr:8081 --output ./export/ --workers 100
```

---

## 2. Schema Registration Failures (Incompatible Schema)

**Problem:** Registration fails with `incompatible with an earlier schema; error code 409`.

**Cause:** The target's compatibility mode rejects the incoming schema (out-of-order import or stricter policy).

**Solution:** Temporarily disable compatibility, migrate, then restore:
```bash
srctl compatibility set NONE --global --url http://target-sr:8081
srctl import --source http://source-sr:8081 --target http://target-sr:8081 --workers 100
srctl compatibility set BACKWARD --global --url http://target-sr:8081
```

---

## 3. "Schema too large" Errors

**Problem:** Registration fails with `Schema size exceeds maximum allowed size` (1 MB limit on Confluent Cloud).

**Cause:** Monolithic or deeply nested schemas exceed the size limit.

**Solution:** Split into smaller referenced sub-schemas:
```bash
srctl split --subject my-large-schema-value --url http://source-sr:8081 --output ./split-schemas/
srctl import --from-dir ./split-schemas/ --target http://target-sr:8081 --workers 100
```

---

## 4. Reference Resolution Failures

**Problem:** Registration fails with `Reference not found: subject "com.example.Address" version 1`.

**Cause:** The source registry contains dangling references (subjects that reference schemas that no longer exist or were never registered).

**Solution:** Check for dangling references, then export with dependency resolution:
```bash
srctl dangling --url http://source-sr:8081
srctl export --url http://source-sr:8081 --output ./export/ --resolve-references --workers 100
srctl import --from-dir ./export/ --target http://target-sr:8081 --workers 100
```

---

## 5. Authentication/Authorization Errors

**Problem:** API calls return `401 Unauthorized` or `403 Forbidden`.

**Cause:** Missing/expired credentials (401) or insufficient permissions such as `Subject:Write` (403).

**Solution:** Verify credentials and pass them to srctl:
```bash
srctl subjects list --url http://target-sr:8081 --auth-key <API_KEY> --auth-secret <API_SECRET>
# Or use environment variables:
export SRCTL_TARGET_AUTH_KEY="your-api-key"
export SRCTL_TARGET_AUTH_SECRET="your-api-secret"
```

---

## 6. Network Connectivity Issues

**Problem:** Commands fail with `connection timed out` or `no such host`.

**Cause:** DNS failure, firewall rules, VPN requirements, or incorrect URLs.

**Solution:** Verify connectivity step by step:
```bash
nslookup target-sr.example.com
nc -zv target-sr.example.com 8081
curl -s -o /dev/null -w "%{http_code}" https://psrc-xxxxx.us-east-2.aws.confluent.cloud
```

---

## 7. Client Deserialization Failures After Migration

**Problem:** Consumers fail with `Error retrieving Avro schema for id 42` after cutover.

**Cause:** Schema IDs were not preserved during migration; Kafka message headers reference the old IDs.

**Solution:** Re-import with ID preservation in IMPORT mode:
```bash
srctl mode set IMPORT --global --url http://target-sr:8081
srctl import --source http://source-sr:8081 --target http://target-sr:8081 --preserve-ids --workers 100
srctl mode set READWRITE --global --url http://target-sr:8081
```

> **Note:** This typically happens when the destination was not in IMPORT mode during migration. `srctl clone` handles this automatically, but if you used manual methods, ensure the destination was in IMPORT mode.

---

## 8. "Mode is not IMPORT" Errors

**Problem:** Import fails with `Mode is not IMPORT for subject "my-topic-value"`.

**Cause:** The target must be in IMPORT mode to accept schemas with explicit IDs (default is READWRITE).

> **Important:** `srctl clone` handles IMPORT mode automatically. This error only occurs with manual REST API migration.

**Solution:** Set IMPORT mode before migration, restore afterward:
```bash
srctl mode set IMPORT --global --url http://target-sr:8081
# ... run migration ...
srctl mode set READWRITE --global --url http://target-sr:8081
```

---

## 9. Rate Limiting on Confluent Cloud

**Problem:** Bulk operations fail with `429 Too Many Requests`.

**Cause:** Confluent Cloud rate limits are exceeded by high-parallelism migrations.

**Solution:** Reduce workers and add request delays:
```bash
srctl import --source http://source-sr:8081 --target https://psrc-xxxxx.confluent.cloud \
  --workers 3 --request-delay 500ms --auth-key <API_KEY> --auth-secret <API_SECRET>
```

---

## 10. Subject Name Mismatches

**Problem:** Clients cannot find schemas because subject names differ between source and target.

**Cause:** Source and target use different naming strategies (TopicNameStrategy vs RecordNameStrategy).

**Solution:** Remap subjects during export with a mapping file:
```bash
srctl export --url http://source-sr:8081 --output ./export/ --subject-map ./subject-mapping.json --workers 100
# subject-mapping.json: {"com.example.User": "users-topic-value", ...}
```

---

## 11. Duplicate Schema Versions

**Problem:** A subject has more versions than expected, with identical content under multiple version numbers.

**Cause:** Migration ran multiple times, or schemas were registered in both IMPORT and READWRITE modes.

**Solution:** Detect duplicates, then clean the target and re-import:
```bash
srctl schemas deduplicate --url http://target-sr:8081 --dry-run
srctl subjects delete-all --url http://target-sr:8081 --permanent
srctl mode set IMPORT --global --url http://target-sr:8081
srctl import --source http://source-sr:8081 --target http://target-sr:8081 --preserve-ids --workers 100
srctl mode set READWRITE --global --url http://target-sr:8081
```
