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
  --target-password <API_SECRET>
```

All checks must pass before proceeding. If schema IDs do not match, re-run the migration with ID preservation enabled -- deserialization depends on matching IDs.

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

## 4. Cutover Strategies

**Blue-green.** Keep both registries running. Switch clients in batches, starting with low-risk applications. Soak 24-48 hours between batches. Decommission the source only after all clients are stable on the target.

**Canary.** Migrate a single representative application that exercises both produce and consume paths. Monitor for 48-72 hours before proceeding with a broader rollout.

**Rolling.** Update the Schema Registry URL in your central config store (ConfigMaps, Consul, environment variables) and trigger rolling restarts across the fleet. Halt the rollout if error rates spike.

---

## 5. Rollback

**Keep the source registry running** until all clients have been stable on the target for at least 72 hours and a final `srctl compare` confirms no drift.

**To roll back**, revert client configurations to point at the source registry and restart affected services. If new schema versions were registered on the target after cutover, register them on the source before completing the rollback to prevent deserialization failures.

---

## Checklist

- [ ] `srctl compare` -- all checks pass (subjects, versions, hashes, IDs, compatibility)
- [ ] Test producer and consumer against the target registry
- [ ] `srctl validate` -- compatibility enforcement confirmed
- [ ] Cutover strategy selected and executed
- [ ] Clients monitored for errors during and after cutover
- [ ] Source registry kept running through observation period
- [ ] Final `srctl compare` confirms no drift
- [ ] Source registry decommissioned after full validation
