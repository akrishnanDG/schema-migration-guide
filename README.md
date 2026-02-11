# Schema Registry Migration Guide

Migrate to **Confluent Platform Schema Registry** or **Confluent Cloud Schema Registry** from:

- Community (open-source) Confluent Schema Registry
- AWS Glue Schema Registry
- Apicurio Registry *(coming soon)*

## Who Is This For?

This guide is for platform engineers, Kafka administrators, and DevOps teams who need to migrate their schema management to a supported Confluent offering. It covers both on-premises (Confluent Platform) and fully managed (Confluent Cloud) targets.

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| [`srctl`](https://github.com/akrishnanDG/srctl) | Latest | Primary CLI for SR operations — export, import, clone, compare, validate |
| `curl` | 7.x+ | REST API calls (alternative to srctl) |
| `jq` | 1.6+ | JSON processing |
| `bash` | 4.x+ | Running migration scripts |
| `confluent` CLI | Latest | Confluent Cloud operations (Cloud migrations only) |

For AWS Glue migrations, you will additionally need:

| Tool | Version | Purpose |
|------|---------|---------|
| [`glue-to-ccsr`](https://github.com/akrishnanDG/glue-to-ccsr) | Latest | Migrate schemas from AWS Glue SR to Confluent Cloud SR |
| AWS CLI | 2.x+ | AWS authentication and configuration |

You will also need:

- Network access from your workstation to both source and target Schema Registries
- Credentials for both source and target registries (if authentication is enabled)
- Sufficient permissions to read all subjects on the source and write/admin on the target

## Quick Start

Not sure which migration approach to use? Start with the **[Decision Tree](docs/01-overview.md#decision-tree)** to determine the best path for your environment.

For most Community SR migrations, the workflow is:

```
Assess → Plan → Migrate → Validate → Cutover
```

1. **Run the pre-check** to assess your current environment:
   ```bash
   # Using srctl (recommended)
   srctl stats --url http://source-sr:8081

   # Or using the pre-check script
   ./scripts/pre-check.sh --sr-url http://source-sr:8081
   ```
2. **Review the assessment** and choose your migration approach
3. **Execute the migration** using srctl clone, Schema Exporter, or the API method
4. **Validate** that all schemas migrated correctly:
   ```bash
   srctl compare --url http://source-sr:8081 --target-url http://target-sr:8081
   ```
5. **Cut over** client applications to the new Schema Registry

## Table of Contents

### Community SR Migration

| # | Document | Description |
|---|----------|-------------|
| 1 | [Migration Overview](docs/01-overview.md) | Migration paths, decision tree, and high-level phases |
| 2 | [Pre-Migration Assessment](docs/02-pre-migration-assessment.md) | Inventory, compatibility checks, and readiness analysis |
| 3 | [Migration via Schema Exporter](docs/03-migration-via-exporter.md) | Using the built-in Exporter (Confluent Platform 7.x+) |
| 4 | [Migration via REST API](docs/04-migration-via-api.md) | Manual migration using the REST API and srctl |
| 5 | [Multiple SRs & Contexts](docs/05-multi-sr-and-contexts.md) | Consolidating multiple Schema Registries using contexts |
| 6 | [Post-Migration Validation](docs/06-post-migration-validation.md) | Verification, client reconfiguration, and cutover strategies |
| 7 | [Troubleshooting](docs/07-troubleshooting.md) | Common issues and resolutions |
| 8 | [Appendix](docs/08-appendix.md) | API reference, configuration keys, limits, and glossary |

### AWS Glue SR Migration

| # | Document | Description |
|---|----------|-------------|
| 9 | [Migration from AWS Glue SR](docs/09-migration-from-glue.md) | End-to-end guide for Glue → Confluent migration |

### Apicurio Registry Migration

| # | Document | Description |
|---|----------|-------------|
| 10 | [Migration from Apicurio](docs/10-migration-from-apicurio.md) | *(Coming soon)* |

## Tools

| Tool | Source | Purpose |
|------|--------|---------|
| [srctl](https://github.com/akrishnanDG/srctl) | CLI (Go) | Schema Registry operations — export, import, clone, compare, split, validate |
| [glue-to-ccsr](https://github.com/akrishnanDG/glue-to-ccsr) | CLI (Go) | One-time schema copy from AWS Glue SR to Confluent Cloud SR |
| [aws-glue-confluent-sr-migration-demo](https://github.com/akrishnanDG/aws-glue-confluent-sr-migration-demo) | Java Demo | Zero-downtime migration demo using `secondary.deserializer` |

## Scripts

These scripts provide lightweight alternatives to srctl for environments where installing a Go binary is not feasible.

| Script | Description |
|--------|-------------|
| [`pre-check.sh`](scripts/pre-check.sh) | Automated pre-migration assessment |
| [`export-schemas.sh`](scripts/export-schemas.sh) | Export all schemas from source Schema Registry |
| [`import-schemas.sh`](scripts/import-schemas.sh) | Import schemas to target Schema Registry |
| [`validate-migration.sh`](scripts/validate-migration.sh) | Post-migration validation |

## License

This guide and associated scripts are provided as-is for migration assistance purposes.
