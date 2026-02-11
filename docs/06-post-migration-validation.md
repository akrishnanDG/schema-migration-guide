# Post-Migration Validation and Cutover

This document covers the steps required to validate a completed Schema Registry
migration, reconfigure downstream clients, execute a cutover strategy, and
prepare a rollback plan. It assumes schemas have already been migrated using
the procedures described in earlier sections of this guide.

For troubleshooting any issues encountered during validation or cutover, see
[docs/07-troubleshooting.md](07-troubleshooting.md).

---

## 1. Schema Validation

### 1.1 Primary Validation with `srctl compare`

The `srctl compare` command is the primary tool for verifying that the target
Schema Registry contains all subjects, versions, and schema content from the
source. Run the following command once the migration has completed:

```bash
srctl compare \
  --url http://source-sr:8081 \
  --target-url https://target-sr.confluent.cloud \
  --target-username <API_KEY> \
  --target-password <API_SECRET>
```

This command performs a comprehensive comparison and will report differences
across the following dimensions.

### 1.2 Subject Count Comparison

The compare output begins with a summary of total subject counts on the source
and target registries. A mismatch here indicates that one or more subjects
were not migrated or were created erroneously on the target. Example output:

```
Source subjects: 142
Target subjects: 142
Status: MATCH
```

If counts differ, re-run the migration for missing subjects or investigate
whether extra subjects on the target need to be removed.

### 1.3 Version Count per Subject

For every subject present on both registries, `srctl compare` checks that the
number of schema versions matches. A version count mismatch for a given
subject means that some versions were dropped during migration or that
additional versions were registered on the target after the initial sync.

```
Subject: orders-value
  Source versions: 5
  Target versions: 5
  Status: MATCH

Subject: users-value
  Source versions: 3
  Target versions: 2
  Status: MISMATCH (missing versions on target)
```

### 1.4 Schema Content Hash Comparison

Beyond version counts, `srctl compare` computes a content hash for each schema
version and verifies that the source and target schemas are byte-for-byte
identical. This catches subtle issues such as whitespace differences,
field reordering, or encoding mismatches that would not be apparent from
version counts alone.

### 1.5 Schema ID Preservation Check

Schema IDs are critical because serialized messages embed the schema ID in
their wire format. If IDs are not preserved, consumers will fail to
deserialize messages that were produced before the migration. The compare
output flags any ID mismatches:

```
Subject: orders-value, Version: 1
  Source ID: 100042
  Target ID: 100042
  Status: MATCH

Subject: orders-value, Version: 2
  Source ID: 100087
  Target ID: 100099
  Status: MISMATCH
```

If IDs do not match, you must re-run the migration with ID preservation
enabled. Do not proceed with cutover until all IDs match.

### 1.6 Compatibility Configuration Comparison

Each subject can have a compatibility level configured (e.g., BACKWARD,
FORWARD, FULL, NONE). The compare command verifies that these settings have
been carried over to the target. Mismatched compatibility settings can cause
schema evolution to behave differently on the target, leading to unexpected
registration failures or overly permissive changes.

### 1.7 Detailed Per-Subject Reports

For a more granular, scriptable validation report, use the provided validation
script:

```bash
./scripts/validate-migration.sh \
  --source-url http://source-sr:8081 \
  --target-url https://target-sr.confluent.cloud \
  --target-username <API_KEY> \
  --target-password <API_SECRET>
```

This script produces a per-subject CSV report that can be reviewed manually
or fed into automated checks in a CI/CD pipeline. See
`scripts/validate-migration.sh` for usage details and available flags.

---

## 2. Client Reconfiguration

Once validation confirms that the target Schema Registry is a faithful copy
of the source, the next step is to point all clients at the new registry.

### 2.1 Producer Configuration

Update producer application properties to reference the target Schema Registry
and supply the appropriate credentials:

```properties
schema.registry.url=https://target-sr.confluent.cloud
basic.auth.credentials.source=USER_INFO
basic.auth.user.info=<API_KEY>:<API_SECRET>
```

These properties apply to any producer using the Confluent serializers
(e.g., `KafkaAvroSerializer`, `KafkaProtobufSerializer`,
`KafkaJsonSchemaSerializer`). Replace `<API_KEY>` and `<API_SECRET>` with
the credentials provisioned for the target registry.

### 2.2 Consumer Configuration

Consumers require the same configuration changes as producers:

```properties
schema.registry.url=https://target-sr.confluent.cloud
basic.auth.credentials.source=USER_INFO
basic.auth.user.info=<API_KEY>:<API_SECRET>
```

These properties apply to any consumer using the Confluent deserializers
(e.g., `KafkaAvroDeserializer`, `KafkaProtobufDeserializer`,
`KafkaJsonSchemaDeserializer`). Ensure that schema ID preservation was
verified (Section 1.5) before switching consumers, as deserialization depends
on matching IDs.

### 2.3 Kafka Connect Configuration

Kafka Connect requires updates at two levels:

**Worker-level configuration** (in the Connect worker properties file or
environment variables):

```properties
key.converter.schema.registry.url=https://target-sr.confluent.cloud
value.converter.schema.registry.url=https://target-sr.confluent.cloud
key.converter.basic.auth.credentials.source=USER_INFO
key.converter.basic.auth.user.info=<API_KEY>:<API_SECRET>
value.converter.basic.auth.credentials.source=USER_INFO
value.converter.basic.auth.user.info=<API_KEY>:<API_SECRET>
```

**Connector-level configuration** (in individual connector JSON configs):

If individual connectors override the worker-level Schema Registry URL, each
connector configuration must also be updated. Use the Connect REST API to
update running connectors:

```bash
curl -X PUT http://connect-host:8083/connectors/<connector-name>/config \
  -H "Content-Type: application/json" \
  -d '{
    "value.converter.schema.registry.url": "https://target-sr.confluent.cloud",
    "value.converter.basic.auth.credentials.source": "USER_INFO",
    "value.converter.basic.auth.user.info": "<API_KEY>:<API_SECRET>"
  }'
```

After updating, restart affected connectors and verify that they transition
to a RUNNING state.

### 2.4 ksqlDB Server Configuration

ksqlDB servers reference the Schema Registry via the
`ksql.schema.registry.url` property. Update the ksqlDB server configuration
file:

```properties
ksql.schema.registry.url=https://target-sr.confluent.cloud
ksql.schema.registry.basic.auth.credentials.source=USER_INFO
ksql.schema.registry.basic.auth.user.info=<API_KEY>:<API_SECRET>
```

A restart of the ksqlDB server is required for this change to take effect.
After restarting, verify that existing persistent queries resume without
errors and that new queries can reference schemas on the target registry.

### 2.5 Kafka Streams Application Configuration

Kafka Streams applications that use the Confluent Serde classes require the
Schema Registry URL to be set in the `StreamsConfig`:

```java
Properties props = new Properties();
props.put("schema.registry.url", "https://target-sr.confluent.cloud");
props.put("basic.auth.credentials.source", "USER_INFO");
props.put("basic.auth.user.info", "<API_KEY>:<API_SECRET>");
```

Or equivalently in a properties file:

```properties
schema.registry.url=https://target-sr.confluent.cloud
basic.auth.credentials.source=USER_INFO
basic.auth.user.info=<API_KEY>:<API_SECRET>
```

Rolling restarts of Kafka Streams applications will pick up the new
configuration. Monitor the application logs during the restart to confirm
that state store restoration and rebalancing complete successfully.

---

## 3. Functional Testing

Before executing the cutover across the full fleet, perform functional tests
against the target Schema Registry to confirm end-to-end operation.

### 3.1 Produce a Test Message

Using a test producer configured to point at the target registry, produce a
message to a test topic using an existing schema subject:

```bash
kafka-avro-console-producer \
  --broker-list <BROKER_LIST> \
  --topic test-migration-topic \
  --property schema.registry.url=https://target-sr.confluent.cloud \
  --property basic.auth.credentials.source=USER_INFO \
  --property basic.auth.user.info=<API_KEY>:<API_SECRET> \
  --property value.schema.id=<KNOWN_SCHEMA_ID>
```

Type a valid JSON payload and confirm that the message is accepted without
serialization errors.

### 3.2 Consume Existing Messages

Using a test consumer pointed at the target registry, consume messages from
a topic that was populated before the migration:

```bash
kafka-avro-console-consumer \
  --bootstrap-server <BROKER_LIST> \
  --topic existing-topic \
  --from-beginning \
  --max-messages 10 \
  --property schema.registry.url=https://target-sr.confluent.cloud \
  --property basic.auth.credentials.source=USER_INFO \
  --property basic.auth.user.info=<API_KEY>:<API_SECRET>
```

Confirm that messages deserialize correctly. If deserialization fails with
schema-not-found errors, revisit the schema ID preservation check in
Section 1.5.

### 3.3 Schema Evolution Test

Verify that the target registry correctly enforces compatibility rules by
registering a new schema version. First, validate the evolved schema without
actually registering it:

```bash
srctl validate --file evolved-schema.avsc --subject my-subject \
  --url https://target-sr.confluent.cloud \
  --username <API_KEY> --password <API_SECRET>
```

If validation passes, register the new version and confirm that the version
number increments as expected. If validation fails, confirm that the
compatibility level on the target matches the source (Section 1.6) and that
the evolved schema is genuinely compatible.

---

## 4. Cutover Strategies

Choose a cutover strategy based on your risk tolerance, fleet size, and
operational maturity.

### 4.1 Blue-Green Cutover

In a blue-green approach, both the source and target Schema Registries remain
operational simultaneously. Clients are switched in batches:

1. **Prepare**: Confirm that the target registry passes all validation checks
   (Section 1). Ensure both registries are accessible from all client
   environments.
2. **Switch batch 1**: Reconfigure a subset of non-critical applications
   (e.g., internal dashboards, low-priority consumers) to point at the
   target registry. Monitor for errors.
3. **Switch batch 2**: After a soak period (recommended: 24-48 hours with
   no errors), reconfigure the next batch of applications, including
   higher-priority consumers and producers.
4. **Switch batch 3**: Migrate remaining applications, including Kafka
   Connect clusters, ksqlDB servers, and Kafka Streams applications.
5. **Decommission**: Once all clients are on the target and a final
   validation pass confirms no traffic to the source, decommission the
   source registry.

This strategy provides the safest rollback path because the source registry
remains fully operational throughout the transition.

### 4.2 Canary Cutover

The canary approach migrates a single representative application first:

1. **Select a canary**: Choose an application that exercises both production
   and consumption paths and covers the most common schema subjects.
2. **Reconfigure the canary**: Point it at the target registry and deploy.
3. **Monitor**: Watch the canary application for a defined observation period
   (recommended: 48-72 hours). Check for serialization/deserialization
   errors, latency changes, and schema registration failures.
4. **Proceed or abort**: If the canary succeeds, proceed with a broader
   rollout using one of the other strategies. If it fails, roll back the
   canary and investigate.

This strategy is well suited for teams that want high confidence before
committing to a full fleet migration.

### 4.3 Rolling Cutover

In a rolling cutover, configuration changes are propagated across the fleet
gradually, typically through a configuration management system or deployment
pipeline:

1. **Update configuration source**: Change the Schema Registry URL in your
   central configuration store (e.g., environment variables, Consul,
   Kubernetes ConfigMaps, or Helm values).
2. **Roll out incrementally**: Trigger rolling restarts across your
   application fleet. Each instance picks up the new configuration as it
   restarts.
3. **Monitor continuously**: Track error rates, deserialization failures, and
   Schema Registry request latencies throughout the rollout.
4. **Pause if needed**: If error rates spike, halt the rollout and investigate
   before continuing.

This strategy works well in Kubernetes environments where rolling deployments
are natively supported. It requires confidence that the target registry is
fully validated before beginning.

---

## 5. Rollback Plan

Always have a rollback plan ready before initiating cutover. The source
Schema Registry must remain operational until the migration is fully
validated and all clients have been stable on the target for a sufficient
observation period.

### 5.1 Keep the Source Registry Running

Do not shut down, scale down, or decommission the source Schema Registry
until the following conditions are met:

- All clients have been migrated to the target registry.
- No errors related to schema resolution have been observed for at least
  72 hours (adjust based on your traffic patterns and SLAs).
- A final `srctl compare` run confirms the target is still in sync
  (no drift has occurred).

### 5.2 Client Configuration Rollback

If issues are discovered after switching clients to the target registry,
revert client configurations to point back at the source:

```properties
schema.registry.url=http://source-sr:8081
```

Remove or comment out the cloud authentication properties if they are not
needed for the source registry:

```properties
# basic.auth.credentials.source=USER_INFO
# basic.auth.user.info=<API_KEY>:<API_SECRET>
```

For Kafka Connect, revert the worker and connector configurations and
restart. For ksqlDB, revert `ksql.schema.registry.url` and restart the
server. For Kafka Streams applications, revert the properties and perform
a rolling restart.

### 5.3 Handling Schemas Registered After Cutover

If new schema versions were registered on the target registry after the
cutover (because producers evolved their schemas), those versions will not
exist on the source. Before rolling back:

1. Identify any new schemas registered on the target since the cutover began.
2. Manually register those schemas on the source registry to prevent
   deserialization failures for messages produced after the cutover.
3. Verify that the source registry has the new versions before completing
   the rollback.

### 5.4 Rollback Decision Criteria

Consider rolling back if any of the following are observed:

- Deserialization errors in consumers that correlate with the cutover.
- Schema registration failures in producers due to compatibility mismatches
  that did not exist on the source.
- Elevated latency to the target Schema Registry that impacts producer or
  consumer throughput.
- Missing schemas or schema IDs that were expected to be present on the
  target.

For detailed troubleshooting of these and other issues, see
[docs/07-troubleshooting.md](07-troubleshooting.md).

---

## Summary Checklist

Use this checklist to track progress through the post-migration process:

- [ ] Run `srctl compare` and confirm all checks pass (subjects, versions,
      content hashes, IDs, compatibility configs).
- [ ] Run `scripts/validate-migration.sh` for detailed per-subject report.
- [ ] Reconfigure and test a single producer against the target registry.
- [ ] Reconfigure and test a single consumer against the target registry.
- [ ] Perform a schema evolution test with `srctl validate`.
- [ ] Select and execute a cutover strategy.
- [ ] Monitor all clients for errors during and after cutover.
- [ ] Keep source registry running for the defined observation period.
- [ ] Run a final `srctl compare` to confirm no drift.
- [ ] Decommission the source registry only after full validation.
