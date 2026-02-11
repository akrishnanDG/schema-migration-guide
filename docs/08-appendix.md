# Appendix

---

## Confluent Cloud Schema Registry Limits

| Limit | Value | Notes |
|---|---|---|
| Max schema size | 1 MB (default) | Increasable via support ticket (Enterprise) |
| Max schemas | Varies by plan | Enterprise/Dedicated support higher counts |
| API rate limits | Varies by plan | Throttled requests receive HTTP 429 |
| Max versions per subject | 10,000 | May need cleanup before migration |
| Max subjects | Varies by plan | Check quota in Confluent Cloud console |
| Request timeout | 60 seconds | |

---

## REST API Endpoint Reference

| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/subjects` | List all subjects. `?subjectPrefix=` to filter, `?deleted=true` for soft-deleted. |
| `GET` | `/subjects/{subject}/versions` | List version numbers for a subject. |
| `GET` | `/subjects/{subject}/versions/{version}` | Get a specific version (`latest` supported). |
| `GET` | `/subjects/{subject}/versions/{version}/schema` | Get raw schema string only. |
| `POST` | `/subjects/{subject}/versions` | Register a schema. Body: `schema`, `schemaType`, `references`. Returns `{"id": N}`. |
| `POST` | `/subjects/{subject}` | Check if a schema is already registered (lookup). |
| `DELETE` | `/subjects/{subject}` | Soft-delete subject. `?permanent=true` for hard delete. |
| `DELETE` | `/subjects/{subject}/versions/{version}` | Soft-delete a version. `?permanent=true` for hard delete. |
| `GET` | `/config` | Get global compatibility level. |
| `PUT` | `/config` | Set global compatibility. Body: `{"compatibility": "BACKWARD"}`. |
| `GET` | `/config/{subject}` | Get subject-level compatibility. |
| `PUT` | `/config/{subject}` | Set subject-level compatibility. |
| `DELETE` | `/config/{subject}` | Remove subject-level override (revert to global). |
| `GET` | `/mode` | Get global mode (READWRITE, READONLY, IMPORT). |
| `PUT` | `/mode` | Set global mode. Body: `{"mode": "IMPORT"}`. |
| `GET` | `/schemas/ids/{id}` | Get schema by global ID. |
| `GET` | `/schemas/ids/{id}/subjects` | List subjects referencing a schema ID. |
| `GET` | `/schemas` | List all schemas. Supports `?offset=` and `?limit=`. |
| `POST` | `/exporters` | Create a schema exporter. |
| `GET` | `/exporters` | List all exporters. |
| `GET` | `/exporters/{name}/status` | Get exporter status (STARTING, RUNNING, PAUSED, ERROR). |
| `PUT` | `/exporters/{name}/pause` | Pause an exporter. |
| `PUT` | `/exporters/{name}/resume` | Resume an exporter. |
| `PUT` | `/exporters/{name}/reset` | Reset an exporter. |
| `DELETE` | `/exporters/{name}` | Delete an exporter. |
| `GET` | `/contexts` | List all contexts (`:.context-name:` prefixes). |

---

## srctl Command Reference

| Command | Description |
|---|---|
| `srctl stats` | Summary statistics: subjects, schemas, types, compatibility levels. |
| `srctl list` | List subjects with filtering by prefix, type, or compatibility. |
| `srctl clone` | Clone schemas between registries. Supports ID preservation, dry-run, context mapping, references. |
| `srctl export` | Export schemas, subjects, compatibility, and modes to a local snapshot. |
| `srctl import` | Import from a snapshot. Requires IMPORT mode for ID preservation. |
| `srctl backup` | Full backup optimized for disaster recovery. |
| `srctl restore` | Restore from backup. Supports selective restore by prefix or type. |
| `srctl compare` | Diff two registries: missing subjects, version mismatches, schema differences. |
| `srctl config get/set` | Get or set compatibility at global or subject level. |
| `srctl mode get/set` | Get or set mode (READWRITE, READONLY, IMPORT). |
| `srctl split analyze` | Plan how to partition schemas across multiple destinations. |
| `srctl split extract` | Extract a schema subset based on the split plan. |
| `srctl split register` | Register extracted schemas into a destination, preserving IDs. |
| `srctl validate` | Validate schemas against compatibility, references, and naming rules. |
| `srctl dangling` | Identify schemas with unresolved references. |
| `srctl health` | Check connectivity, auth, and read/write capability. |
| `srctl contexts` | List all contexts in the registry. |
| `srctl diff` | Line-by-line schema diff between subjects, versions, or registries. |

Full docs: [https://github.com/akrishnanDG/srctl](https://github.com/akrishnanDG/srctl)

---

## Configuration Property Reference

| Property | Description | Example |
|---|---|---|
| `schema.registry.url` | SR endpoint URL (comma-separated for failover) | `https://psrc-abc12.us-east-2.aws.confluent.cloud` |
| `basic.auth.credentials.source` | Credential source for HTTP basic auth | `USER_INFO` |
| `basic.auth.user.info` | API key and secret (`<key>:<secret>`) | `ABCDEFGH12345:xYzSecret` |
| `schema.registry.ssl.truststore.location` | SSL truststore path (on-prem with private CA) | `/etc/kafka/ssl/truststore.jks` |
| `schema.registry.ssl.truststore.password` | Truststore password | `changeit` |
| `schema.registry.ssl.keystore.location` | SSL keystore path (mTLS) | `/etc/kafka/ssl/keystore.jks` |
| `schema.registry.ssl.keystore.password` | Keystore password | `changeit` |
| `key.subject.name.strategy` | Subject naming strategy for keys | `TopicNameStrategy` |
| `value.subject.name.strategy` | Subject naming strategy for values | `TopicNameStrategy` |
| `auto.register.schemas` | Auto-register new schemas; set `false` during migration | `false` |
| `use.latest.version` | Use latest schema version instead of specific ID | `true` |

### Subject Name Strategies

| Strategy | Pattern | Description |
|---|---|---|
| `TopicNameStrategy` | `<topic>-key` / `<topic>-value` | Default. One schema per topic. |
| `RecordNameStrategy` | `<record.name>` | Multiple schema types per topic. |
| `TopicRecordNameStrategy` | `<topic>-<record.name>` | Per-topic, per-record evolution. |

---

## Glossary

| Term | Definition |
|---|---|
| **Schema Registry (SR)** | Service for managing schemas used by Kafka producers and consumers. Provides versioning, compatibility enforcement, and ID assignment. |
| **Subject** | Named scope for schema registration and versioning (default: `<topic>-key` / `<topic>-value`). |
| **Schema ID** | Globally unique integer embedded in Kafka messages for deserialization lookup. Preserving IDs during migration is critical. |
| **Version** | Sequential integer per schema registration under a subject. |
| **Compatibility Level** | Evolution rule: BACKWARD, FORWARD, FULL, NONE. Set globally or per subject. |
| **Context** | Namespace prefix (`:.name:subject`) for logical separation within one registry. |
| **Schema Linking** | Continuous schema replication from source to destination SR via exporters. |
| **Exporter** | Component that replicates schemas between registries. Can be paused, resumed, or reset. |
| **SerDe** | Serializer/Deserializer. SR-aware SerDes embed schema ID in the payload. |
| **Wire Format** | Binary encoding: magic byte (`0x0`) + 4-byte schema ID + payload. |
| **IMPORT Mode** | Allows registration with pre-assigned schema IDs for ID-preserving migration. |
| **READWRITE Mode** | Default mode. Normal operations with auto-assigned IDs. |
| **READONLY Mode** | Read-only; rejects writes. Useful for protecting source during migration. |
| **Schema Reference** | Cross-schema dependency (Protobuf imports, Avro/JSON `$ref`). Must be registered in order. |
| **Soft Delete** | Mark as deleted without permanent removal. Recoverable via `?deleted=true`. |
| **Hard Delete** | Permanent removal. Requires prior soft delete. |
| **Normalize** | Treat logically equivalent schemas as identical regardless of formatting. |
| **Idempotent Registration** | Re-registering an existing schema returns the same ID (safe for retries). |
| **Context Flattening** | Removing context prefixes when migrating from context-based to flat namespace. |

---

*For the latest information, see the [Confluent docs](https://docs.confluent.io) and [srctl documentation](https://github.com/akrishnanDG/srctl).*
