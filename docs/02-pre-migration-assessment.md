# Pre-Migration Assessment

Before migrating, run a quick assessment to catch issues that could block the migration. `srctl` handles most migration mechanics automatically (dependency ordering, compatibility preservation, ID preservation), so this assessment focuses on things that need human attention.

---

## Registry Overview

Get a summary of your registry — total subjects, schema types, and version counts:

```bash
srctl stats --url http://source-sr:8081 --workers 100
```

Review the subject list for anything no longer in use. Dead subjects add unnecessary risk — delete them before migration if possible. Schema Registry requires a soft-delete before a hard-delete:

```bash
# Step 1: Soft-delete the subject (marks it as deleted but retains it internally)
srctl delete --subject <name> --url http://source-sr:8081

# Step 2: Hard-delete the subject (permanently removes it)
srctl delete --subject <name> --url http://source-sr:8081 --permanent
```

List all subjects with version details:

```bash
srctl list --url http://source-sr:8081 --versions --workers 100
```

---

## Schema Size

Confluent Cloud enforces a 1 MB maximum schema size. Self-managed registries have no default limit, so oversized schemas may exist in your source.

```bash
srctl stats --url http://source-sr:8081 --size --workers 100
```

If any schemas exceed the limit, use `srctl split` to break them into smaller referenced subjects:

```bash
srctl split analyze --subject my-large-schema --url http://source-sr:8081
srctl split extract --subject my-large-schema --url http://source-sr:8081 --dry-run
```

---

## Dangling References

A dangling reference is a schema that references another schema that does not exist or has been deleted. These will cause migration failures.

```bash
srctl dangling --url http://source-sr:8081
```

Fix all dangling references before proceeding — either re-register the missing schema, update the reference, or delete the orphaned schema.

---

## Security and Authentication

Identify the auth mechanism on the source (none, HTTP Basic, mTLS, RBAC, OAuth) and document the target model. If migrating to Confluent Cloud, auth uses API keys or OAuth — all client configs will need credential updates when you point clients to the new registry after migration.

---

## Client Inventory

Every application that connects to Schema Registry must be reconfigured during cutover. Common client types: Kafka producers/consumers, Kafka Connect, ksqlDB, Kafka Streams, and custom REST clients.

For each, document:
- Current `schema.registry.url`
- Cutover strategy (blue-green, canary, or rolling)

> **Note:** Credential updates happen AFTER the schema copy is complete and validated, when you point clients to the new registry. Do not change client configurations before the migration is finished.

---

## Network Connectivity

Verify that the machine running `srctl` can reach both registries:

```bash
srctl health --url http://source-sr:8081
srctl health --url https://target-sr-endpoint
```

For on-prem to Cloud migrations, ensure outbound HTTPS (443) is allowed to `*.confluent.cloud`.

---

## Post-Migration: Lock Down the Source

After the migration is complete, validated, and clients are pointed to the new registry:

1. **Set source to READONLY** -- prevents any further schema registrations on the old registry.
2. **Update CI/CD pipelines** -- point all schema-registering pipelines (CI/CD, Kafka Connect schema auto-registration, etc.) to the new registry.
3. **Decommission timeline** -- keep the source registry running in READONLY for 48-72 hours as a rollback safety net before decommissioning.

---

Once all blocking issues (oversized schemas, dangling references) are resolved, proceed to [Migration via srctl](04-migration-via-api.md).
