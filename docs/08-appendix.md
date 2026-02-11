# Appendix

This appendix provides quick-reference tables, command references, configuration properties, and a glossary of terms relevant to Schema Registry migration.

---

## Confluent Cloud Schema Registry Limits

Understanding the limits of Confluent Cloud Schema Registry is critical for planning a migration, especially when migrating large registries or registries with deeply versioned subjects.

| Limit | Value | Notes |
|---|---|---|
| Max schema size | 1 MB (default) | Can be increased via support ticket for Enterprise plans. Schemas exceeding this limit will be rejected on registration. |
| Max number of schemas | Varies by plan | Essentials and Standard plans have lower caps; Enterprise and Dedicated plans support significantly higher counts. Check your plan details. |
| API rate limits | Varies by plan | Essentials: lower rate limits. Standard/Enterprise: higher rate limits. Burst limits also apply. Throttled requests receive HTTP 429. |
| Max versions per subject | 10,000 (default) | Subjects exceeding this limit may need version cleanup or subject restructuring before migration. |
| Max number of subjects | Varies by plan | Enterprise plans support tens of thousands of subjects. Check quota usage via the Confluent Cloud console. |
| Max exporters | Varies by plan | Exporter feature availability depends on your Confluent Cloud plan tier. |
| Request timeout | 60 seconds | Long-running registration or lookup calls may time out under heavy load. |

---

## REST API Endpoint Reference

The following table lists the Schema Registry REST API endpoints most relevant to migration activities. The base URL is your Schema Registry endpoint (e.g., `https://<sr-endpoint>`).

| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/subjects` | List all subjects in the registry. Supports `?subjectPrefix=` for filtering and `?deleted=true` to include soft-deleted subjects. |
| `GET` | `/subjects/{subject}/versions` | List all version numbers registered under a given subject. |
| `GET` | `/subjects/{subject}/versions/{version}` | Retrieve a specific version of a schema under a subject. Use `latest` as the version to get the most recent. Returns subject, version, id, schemaType, schema, and references. |
| `GET` | `/subjects/{subject}/versions/{version}/schema` | Retrieve only the raw schema string (without metadata) for a specific version. |
| `POST` | `/subjects/{subject}/versions` | Register a new schema under a subject. Request body includes `schema` (string), `schemaType` (AVRO, PROTOBUF, JSON), and optionally `references`. Returns `{"id": <schema_id>}`. |
| `POST` | `/subjects/{subject}` | Check if a schema is already registered under a subject (lookup). Request body is the schema to check. |
| `DELETE` | `/subjects/{subject}` | Soft-delete a subject and all its versions. Use `?permanent=true` for hard delete (requires prior soft delete). |
| `DELETE` | `/subjects/{subject}/versions/{version}` | Soft-delete a specific version. Use `?permanent=true` for hard delete. |
| `GET` | `/config` | Retrieve the global compatibility level (e.g., BACKWARD, FORWARD, FULL, NONE). |
| `PUT` | `/config` | Set the global compatibility level. Request body: `{"compatibility": "BACKWARD"}`. |
| `GET` | `/config/{subject}` | Retrieve the compatibility level for a specific subject. Returns the global default if no subject-level override is set. |
| `PUT` | `/config/{subject}` | Set the compatibility level for a specific subject. Request body: `{"compatibility": "NONE"}`. |
| `DELETE` | `/config/{subject}` | Remove the subject-level compatibility override, reverting to the global default. |
| `GET` | `/mode` | Retrieve the global mode (READWRITE, READONLY, IMPORT). |
| `PUT` | `/mode` | Set the global mode. Request body: `{"mode": "IMPORT"}`. Required for ID-preserving migration. |
| `GET` | `/mode/{subject}` | Retrieve the mode for a specific subject. |
| `PUT` | `/mode/{subject}` | Set the mode for a specific subject. |
| `GET` | `/schemas/ids/{id}` | Retrieve a schema by its global unique ID. Useful for verifying ID preservation after migration. |
| `GET` | `/schemas/ids/{id}/subjects` | List all subjects that reference a given schema ID. |
| `GET` | `/schemas` | List all schemas in the registry. Supports pagination with `?offset=` and `?limit=`. |
| `PUT` | `/exporters/{name}` | Update an existing schema exporter configuration. |
| `POST` | `/exporters` | Create a new schema exporter. Request body includes name, subjects, contextType, context, and config. |
| `GET` | `/exporters/{name}/status` | Retrieve the status of a schema exporter (STARTING, RUNNING, PAUSED, ERROR). |
| `GET` | `/exporters` | List all configured schema exporters. |
| `PUT` | `/exporters/{name}/pause` | Pause a running exporter. |
| `PUT` | `/exporters/{name}/resume` | Resume a paused exporter. |
| `PUT` | `/exporters/{name}/reset` | Reset an exporter to re-export from the beginning. |
| `DELETE` | `/exporters/{name}` | Delete an exporter. |
| `GET` | `/contexts` | List all contexts in the registry. Contexts appear as prefixes in the form `:.context-name:`. |

---

## srctl Command Reference

`srctl` is a purpose-built CLI tool for Schema Registry operations, including migration, validation, and comparison. The following table covers commands most relevant to migration workflows.

| Command | Description |
|---|---|
| `srctl stats` | Display summary statistics for a Schema Registry instance, including total subjects, schemas, schema types, and compatibility levels in use. Useful for pre-migration assessment. |
| `srctl list` | List all subjects in the registry with optional filtering by prefix, schema type, or compatibility level. Supports output in table, JSON, or CSV format. |
| `srctl clone` | Clone schemas from a source registry to a destination registry. Supports ID preservation, dry-run mode, context mapping, and reference resolution. The primary command for migration execution. |
| `srctl export` | Export all schemas, subjects, compatibility settings, and mode configurations to a local directory or archive file. Produces a portable snapshot of the registry state. |
| `srctl import` | Import schemas from a previously exported snapshot into a target registry. Handles ordering, references, and ID preservation. Requires the target to be in IMPORT mode for ID-preserving imports. |
| `srctl backup` | Create a full backup of the registry, including schemas, subjects, versions, compatibility configs, and mode settings. Similar to export but optimized for disaster recovery. |
| `srctl restore` | Restore a registry from a backup archive. Supports selective restore by subject prefix or schema type. |
| `srctl compare` | Compare two Schema Registry instances and produce a detailed diff report. Identifies missing subjects, version mismatches, schema content differences, and compatibility setting discrepancies. Essential for post-migration validation. |
| `srctl config get` | Retrieve compatibility configuration at the global level or for a specific subject. |
| `srctl config set` | Set compatibility configuration at the global level or for a specific subject. Supports batch operations across multiple subjects. |
| `srctl mode get` | Retrieve the current mode (READWRITE, READONLY, IMPORT) at the global or subject level. |
| `srctl mode set` | Set the mode at the global or subject level. Use `srctl mode set IMPORT` to prepare a target registry for ID-preserving migration. |
| `srctl split analyze` | Analyze a source registry to determine how schemas should be partitioned across multiple destination registries. Produces a mapping plan based on subject prefixes, schema types, or custom rules. |
| `srctl split extract` | Extract a subset of schemas from a source registry based on the mapping plan produced by `split analyze`. |
| `srctl split register` | Register the extracted subset of schemas into a destination registry, preserving IDs and references. |
| `srctl validate` | Validate schemas in a registry or export file against compatibility rules, reference integrity, and naming conventions. Reports errors and warnings. |
| `srctl dangling` | Identify dangling references -- schemas that reference other schemas which do not exist in the registry. Must be resolved before migration. |
| `srctl health` | Check the health and connectivity of a Schema Registry instance. Verifies authentication, API availability, and basic read/write capability. |
| `srctl contexts` | List all contexts in the registry. Useful when planning migrations that involve context flattening or context remapping. |
| `srctl diff` | Show a detailed, line-by-line diff of schema content between two subjects, two versions, or two registries. Supports Avro, Protobuf, and JSON Schema formats. |

For full documentation, usage examples, and installation instructions, see: [https://github.com/akrishnanDG/srctl](https://github.com/akrishnanDG/srctl)

---

## Configuration Property Reference

The following table lists key configuration properties used by Kafka clients and Schema Registry clients. These properties must be updated as part of the migration when producers and consumers are switched to the new registry.

| Property | Description | Example Value |
|---|---|---|
| `schema.registry.url` | The URL of the Schema Registry endpoint. Update this to point to the new Confluent Cloud SR after migration. Multiple URLs can be comma-separated for failover. | `https://psrc-abc12.us-east-2.aws.confluent.cloud` |
| `basic.auth.credentials.source` | Specifies the source of credentials for HTTP basic authentication. Set to `USER_INFO` when using API key/secret pairs. | `USER_INFO` |
| `basic.auth.user.info` | The API key and secret in the format `<key>:<secret>`. Used when `basic.auth.credentials.source` is set to `USER_INFO`. | `ABCDEFGH12345:xYzSecretKeyHere` |
| `schema.registry.ssl.truststore.location` | Path to the SSL truststore file for TLS connections. Required when using self-signed certificates or private CAs with on-premises Schema Registry. Typically not needed for Confluent Cloud. | `/etc/kafka/ssl/truststore.jks` |
| `schema.registry.ssl.truststore.password` | Password for the SSL truststore file. | `changeit` |
| `schema.registry.ssl.keystore.location` | Path to the SSL keystore file for mutual TLS (mTLS) authentication. Used with on-premises deployments that require client certificate authentication. | `/etc/kafka/ssl/keystore.jks` |
| `schema.registry.ssl.keystore.password` | Password for the SSL keystore file. | `changeit` |
| `key.subject.name.strategy` | The subject naming strategy for message keys. Determines how the subject name is derived for key schemas. | `io.confluent.kafka.serializers.subject.TopicNameStrategy` |
| `value.subject.name.strategy` | The subject naming strategy for message values. Determines how the subject name is derived for value schemas. | `io.confluent.kafka.serializers.subject.TopicNameStrategy` |
| `auto.register.schemas` | Whether the serializer should automatically register new schemas with the registry. Set to `false` during migration to prevent unintended registrations. | `false` |
| `use.latest.version` | Whether the serializer should look up the latest schema version rather than using a specific ID. Useful during migration transitions. | `true` |
| `latest.compatibility.strict` | When `use.latest.version` is true, this controls whether strict compatibility checking is applied. | `true` |

### Subject Name Strategies

| Strategy Class | Naming Pattern | Description |
|---|---|---|
| `TopicNameStrategy` | `<topic>-key` / `<topic>-value` | Default strategy. Subject name is derived from the topic name. One schema per topic. |
| `RecordNameStrategy` | `<fully.qualified.record.name>` | Subject name is derived from the record's fully qualified name. Allows multiple schema types per topic. |
| `TopicRecordNameStrategy` | `<topic>-<fully.qualified.record.name>` | Subject name is derived from both the topic name and the record name. Provides per-topic, per-record schema evolution. |

---

## Useful confluent CLI Commands

The `confluent` CLI provides commands for managing Confluent Cloud resources, including Schema Registry. The following commands are most relevant during migration.

| Command | Description |
|---|---|
| `confluent schema-registry cluster describe` | Display details about the Schema Registry cluster, including the endpoint URL, cluster ID, and cloud/region information. Use this to obtain the target SR URL for migration. |
| `confluent schema-registry subject list` | List all subjects in the Schema Registry. Supports `--prefix` for filtering and `--deleted` to include soft-deleted subjects. |
| `confluent schema-registry subject describe <subject>` | Show details for a specific subject, including all registered versions and compatibility level. |
| `confluent schema-registry schema create --subject <subject> --schema <file>` | Register a new schema from a file under the specified subject. Supports `--type` to specify AVRO, PROTOBUF, or JSON. Use `--references` for schemas with dependencies. |
| `confluent schema-registry schema list` | List all schemas in the registry. Supports filtering by subject, type, and other criteria. |
| `confluent schema-registry schema describe <schema-id>` | Retrieve a schema by its global ID. Useful for verifying ID preservation post-migration. |
| `confluent schema-registry exporter create <name>` | Create a new Schema Linking exporter. Requires `--config` file with destination registry connection details, subjects, and context configuration. |
| `confluent schema-registry exporter describe <name>` | Show the configuration and current state of a schema exporter. |
| `confluent schema-registry exporter list` | List all configured schema exporters. |
| `confluent schema-registry exporter get-status <name>` | Show the runtime status of a schema exporter (STARTING, RUNNING, PAUSED, ERROR). |
| `confluent schema-registry exporter pause <name>` | Pause a running schema exporter. |
| `confluent schema-registry exporter resume <name>` | Resume a paused schema exporter. |
| `confluent schema-registry exporter delete <name>` | Delete a schema exporter. |
| `confluent schema-registry compatibility validate --subject <subject> --schema <file>` | Test whether a schema is compatible with the existing versions under a subject. Useful for pre-migration validation. |
| `confluent schema-registry config describe` | Show the global compatibility level configuration. |
| `confluent schema-registry config update --compatibility <level>` | Update the global compatibility level. |
| `confluent schema-registry mode describe` | Show the current global mode (READWRITE, READONLY, IMPORT). |
| `confluent schema-registry mode update --mode <mode>` | Set the global mode. Use `--mode IMPORT` to enable ID-preserving schema registration. |

---

## Glossary of Terms

| Term | Definition |
|---|---|
| **Schema Registry (SR)** | A centralized service for managing and storing schemas used by Kafka producers and consumers. It provides schema versioning, compatibility enforcement, and ID assignment to ensure data contracts are maintained across distributed systems. |
| **Subject** | A named scope under which schemas are registered and versioned. By default, subjects follow the pattern `<topic>-key` or `<topic>-value`, but the naming is determined by the subject name strategy in use. |
| **Schema ID** | A globally unique integer identifier assigned to each distinct schema registered in the Schema Registry. Schema IDs are embedded in the Kafka message wire format and used by consumers to look up the correct schema for deserialization. Preserving schema IDs across migration is critical to avoid breaking consumers. |
| **Version** | A sequential integer assigned to each schema registered under a subject. Version 1 is the first schema registered, and each subsequent compatible schema increments the version. Versions are scoped to a subject, not global. |
| **Compatibility Level** | A rule that governs how schemas can evolve within a subject. Common levels include BACKWARD (new schema can read old data), FORWARD (old schema can read new data), FULL (both directions), and NONE (no compatibility checking). Can be set globally or per subject. |
| **Context** | A namespace mechanism in Schema Registry that allows logical separation of schemas within a single registry instance. Contexts appear as prefixes in subject names (e.g., `:.my-context:my-subject`). Used in Schema Linking and multi-tenant configurations. |
| **Schema Linking** | A Confluent feature that continuously replicates schemas from a source Schema Registry to a destination Schema Registry. Uses the exporter mechanism. Schemas are replicated into contexts on the destination. |
| **Exporter** | A Schema Registry component that performs schema replication from a source to a destination registry. Exporters track their progress and can be paused, resumed, or reset. They replicate schemas into contexts on the destination. |
| **SerDe** | Short for Serializer/Deserializer. In the Kafka ecosystem, SerDes are responsible for converting between in-memory objects and byte arrays for Kafka message production and consumption. Schema Registry-aware SerDes embed the schema ID in the serialized payload. |
| **Wire Format** | The binary format used to encode Kafka messages when using Schema Registry. The standard Confluent wire format is: magic byte (0x0) + 4-byte schema ID (big-endian) + serialized payload. Consumers use the embedded schema ID to fetch the correct schema for deserialization. |
| **IMPORT Mode** | A special Schema Registry mode that allows schemas to be registered with explicit, pre-assigned schema IDs. Required for ID-preserving migration. In IMPORT mode, the registry accepts the ID provided in the registration request rather than auto-assigning a new one. Must be set before migration and reverted to READWRITE after. |
| **READWRITE Mode** | The default Schema Registry mode. In this mode, schemas are registered normally with auto-assigned IDs, and all read and write operations are permitted. |
| **READONLY Mode** | A Schema Registry mode that permits only read operations. Schema registration, deletion, and configuration changes are rejected. Useful for protecting a source registry during migration. |
| **Schema Reference** | A mechanism that allows one schema to reference another schema registered in the Schema Registry. Commonly used with Protobuf imports and Avro/JSON Schema `$ref` directives. References must be resolved and registered in the correct order during migration. |
| **Soft Delete** | Marking a subject or schema version as deleted without permanently removing it. Soft-deleted schemas can be recovered. Use `?deleted=true` on API calls to include soft-deleted items. |
| **Hard Delete** | Permanently removing a subject or schema version from the registry. Requires a prior soft delete. Cannot be undone. |
| **Normalize** | A Schema Registry feature that normalizes schema content before registration, ensuring that logically equivalent schemas (differing only in formatting or field ordering) are treated as identical. Enable with `?normalize=true` on registration requests. |
| **TopicNameStrategy** | The default subject naming strategy where subjects are named `<topic>-key` and `<topic>-value`. Results in one schema per topic per key/value. |
| **RecordNameStrategy** | A subject naming strategy where subjects are named after the fully qualified record name, allowing multiple schema types to be used on a single topic. |
| **TopicRecordNameStrategy** | A subject naming strategy combining topic name and record name, providing per-topic, per-record schema evolution control. |
| **Schema Type** | The format of a schema. Schema Registry supports three types: AVRO (default), PROTOBUF, and JSON (JSON Schema). The schema type affects how compatibility is evaluated and how references work. |
| **Global ID** | See Schema ID. The globally unique identifier for a schema across the entire registry. |
| **Confluent Cloud** | Confluent's fully managed cloud-native platform for Apache Kafka, including managed Schema Registry, connectors, and stream processing. |
| **On-Premises (CP)** | Confluent Platform deployed on self-managed infrastructure (bare metal, VMs, or Kubernetes). Includes self-managed Schema Registry. |
| **Idempotent Registration** | Registering a schema that already exists returns the existing schema ID rather than creating a duplicate. This behavior is important during migration retries to avoid duplicate registrations. |
| **Context Flattening** | The process of removing context prefixes from subject names when migrating schemas from a context-based organization (e.g., Schema Linking destination) to a flat subject namespace. For example, `:.source-context:my-subject` becomes `my-subject`. |

---

*This appendix is intended as a quick reference. For the most up-to-date information, consult the official Confluent documentation and the [srctl documentation](https://github.com/akrishnanDG/srctl).*
