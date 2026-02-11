# Schema Registry Migration Guide

Migrate to **Confluent Platform Schema Registry** or **Confluent Cloud Schema Registry** from:

- Community (open-source) Confluent Schema Registry
- AWS Glue Schema Registry
- Apicurio Registry *(coming soon)*

## Prerequisites

| Tool | Purpose |
|------|---------|
| [`srctl`](https://github.com/akrishnanDG/srctl) | Primary CLI for SR operations — export, import, clone, compare, validate, split |
| `confluent` CLI | Confluent Cloud operations (Cloud migrations only) |

For AWS Glue migrations:

| Tool | Purpose |
|------|---------|
| [`glue-to-ccsr`](https://github.com/akrishnanDG/glue-to-ccsr) | Migrate schemas from AWS Glue SR to Confluent Cloud SR |

## Quick Start

```bash
# 1. Assess your current environment
srctl stats --url http://source-sr:8081

# 2. Migrate (one command)
srctl clone \
  --url http://source-sr:8081 \
  --target-url https://target-sr.confluent.cloud \
  --target-username <API_KEY> \
  --target-password <API_SECRET>

# 3. Validate
srctl compare --url http://source-sr:8081 --target-url https://target-sr.confluent.cloud

# 4. Cut over clients to the new Schema Registry
```

Not sure which approach to use? See the **[Decision Tree](docs/01-overview.md#decision-tree)**.

## Table of Contents

### Community SR Migration

| # | Document | Description |
|---|----------|-------------|
| 1 | [Migration Overview](docs/01-overview.md) | Migration paths, decision tree, and high-level phases |
| 2 | [Pre-Migration Assessment](docs/02-pre-migration-assessment.md) | Inventory, compatibility checks, and readiness analysis |
| 3 | [Migration via srctl](docs/04-migration-via-api.md) | Migration using srctl clone, export/import, backup/restore |
| 4 | [Multiple SRs & Contexts](docs/05-multi-sr-and-contexts.md) | Consolidating multiple Schema Registries using contexts |
| 5 | [Post-Migration Validation](docs/06-post-migration-validation.md) | Verification, client reconfiguration, and cutover |
| 6 | [Troubleshooting](docs/07-troubleshooting.md) | Common issues and resolutions |
| 7 | [Appendix](docs/08-appendix.md) | API reference, configuration keys, limits, and glossary |

### AWS Glue SR Migration

| # | Document | Description |
|---|----------|-------------|
| 9 | [Migration from AWS Glue SR](docs/09-migration-from-glue.md) | End-to-end guide using glue-to-ccsr |

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
