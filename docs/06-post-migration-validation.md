# Post-Migration Validation and Cutover

Validate the migration, reconfigure clients, cut over, and prepare rollback.
For troubleshooting, see [07-troubleshooting.md](07-troubleshooting.md).

---

## 1. Validate with `srctl compare`

A single command validates subjects, versions, content hashes, schema IDs, and compatibility settings between source and target:

```bash
srctl compare \
  --url http://source-sr:8081 \
  --target-url https://target-sr.confluent.cloud \
  --target-username <API_KEY> \
  --target-password <API_SECRET> \
  --workers 100
```

All checks must pass before proceeding. If schema IDs do not match, re-run the migration with ID preservation enabled -- deserialization depends on matching IDs.

### Verify destination mode

After `srctl clone` completes, confirm the destination registry is in READWRITE mode and not still in IMPORT mode:

```bash
srctl mode get --global \
  --url https://target-sr.confluent.cloud \
  --username <API_KEY> --password <API_SECRET> \
  --workers 100
```

If the mode is still IMPORT, set it to READWRITE before proceeding:

```bash
srctl mode set READWRITE --global \
  --url https://target-sr.confluent.cloud \
  --username <API_KEY> --password <API_SECRET> \
  --workers 100
```

---

## 2. Client Reconfiguration

Update the following properties for each client type to point at the target registry.

**Producers and Consumers:**

```properties
schema.registry.url=https://target-sr.confluent.cloud
basic.auth.credentials.source=USER_INFO
basic.auth.user.info=<API_KEY>:<API_SECRET>
```

**Kafka Connect** (worker-level -- prefix with `key.converter.` / `value.converter.`):

```properties
key.converter.schema.registry.url=https://target-sr.confluent.cloud
value.converter.schema.registry.url=https://target-sr.confluent.cloud
key.converter.basic.auth.credentials.source=USER_INFO
key.converter.basic.auth.user.info=<API_KEY>:<API_SECRET>
value.converter.basic.auth.credentials.source=USER_INFO
value.converter.basic.auth.user.info=<API_KEY>:<API_SECRET>
```

**ksqlDB:**

```properties
ksql.schema.registry.url=https://target-sr.confluent.cloud
ksql.schema.registry.basic.auth.credentials.source=USER_INFO
ksql.schema.registry.basic.auth.user.info=<API_KEY>:<API_SECRET>
```

**Kafka Streams:**

```properties
schema.registry.url=https://target-sr.confluent.cloud
basic.auth.credentials.source=USER_INFO
basic.auth.user.info=<API_KEY>:<API_SECRET>
```

ksqlDB and Connect require restarts after configuration changes. Kafka Streams applications pick up changes on rolling restart.

---

## 3. Functional Testing

**Compatibility check.** Verify the target enforces compatibility rules correctly:

```bash
srctl validate --file evolved-schema.avsc --subject my-subject \
  --url https://target-sr.confluent.cloud \
  --username <API_KEY> --password <API_SECRET>
```

**Produce/consume test.** Produce a message to a test topic using a known schema ID against the target registry, then consume from an existing topic and confirm deserialization succeeds. Schema-not-found errors indicate an ID preservation problem -- revisit `srctl compare` output.

---

## 4. Cutover and Rollback

### 4a. Cutover from `srctl replicate` (Continuous Replication)

If you used `srctl replicate` for continuous sync, the cutover process differs from a one-time clone:

1. **Verify replication is caught up** -- Check that the replicator CLI status shows stable offset with zero errors. Run `srctl compare` to confirm source and target are in sync.

2. **Set the source to READONLY**:
   ```bash
   srctl mode set READONLY --global --url http://source-sr:8081
   ```

3. **Wait for drain** -- The replicator processes the READONLY mode event and any in-flight schemas. Watch the status output until the offset stabilizes.

4. **Run final validation**:
   ```bash
   srctl compare \
     --url http://source-sr:8081 \
     --target-url https://target-sr.confluent.cloud \
     --target-username <API_KEY> --target-password <API_SECRET> \
     --workers 100
   ```

5. **Stop the replicator** -- Send SIGINT (Ctrl+C) or SIGTERM. The replicator commits final offsets, restores target registry mode, and prints a summary.

6. **Update client configurations** (see section 2 above).

7. **Keep the source in READONLY for 72+ hours.** If you need to roll back, restart the replicator (it resumes from the last offset) and point clients back to the source.

### 4b. Cutover from `srctl clone` (One-Time Copy)

After `srctl clone` completes and `srctl compare` passes, perform a one-time cutover:

1. **Set the source registry to READONLY** to prevent any further schema registrations:

   ```bash
   srctl mode set READONLY --global \
     --url http://source-sr:8081
   ```

2. **Set the destination registry to READWRITE** so it can accept new schemas going forward:

   ```bash
   srctl mode set READWRITE --global \
     --url https://target-sr.confluent.cloud \
     --username <API_KEY> --password <API_SECRET>
   ```

3. **Point CI/CD pipelines and schema-registering clients to the new registry first.** These are the systems that write new schemas, so they must move before consumers and producers. Update pipeline configs, schema registration scripts, and any automation that calls the Schema Registry write APIs.

4. **Update producer and consumer configs** to read from the new registry. Roll out in batches, starting with low-risk applications. Monitor error rates between batches. See section 2 above for the client configuration properties.

5. **Keep the source registry running in READONLY for 72+ hours** as a rollback window. During this period, monitor all clients for schema resolution errors. Run a final `srctl compare` at the end of the window to confirm no drift.

**To roll back**, revert client configurations to point at the source registry and restart affected services. If new schema versions were registered on the target after cutover, register them on the source before completing the rollback to prevent deserialization failures. Set the source back to READWRITE and the target back to READONLY (or IMPORT) as needed.

After 72+ hours with no issues and a clean final `srctl compare`, decommission the source registry.
