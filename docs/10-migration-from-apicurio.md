# Migration from Apicurio Registry

> **Status:** This guide is under active development. A dedicated migration tool is being built to facilitate migrations from Apicurio Registry to Confluent Schema Registry.

## Overview

[Apicurio Registry](https://www.apicur.io/registry/) is an open-source schema and API registry that supports a broad range of artifact types, including Avro, Protobuf, JSON Schema, OpenAPI, AsyncAPI, and GraphQL. Organizations running Apicurio may choose to migrate to Confluent Schema Registry for tighter integration with the Confluent ecosystem, production-grade support, and standardized Kafka SerDe tooling.

### Key Differences Between Apicurio and Confluent SR

| Concept | Apicurio Registry | Confluent Schema Registry |
|---|---|---|
| Schema organization | Artifact groups and artifact IDs | Subjects (optionally with contexts) |
| Supported types | Avro, Protobuf, JSON Schema, OpenAPI, AsyncAPI, GraphQL | Avro, Protobuf, JSON Schema |
| Compatibility rules | Per-artifact and global rules; rule types include validity and compatibility | Per-subject and global compatibility levels |
| REST API | `/apis/registry/v2/...` endpoints | `/subjects/...`, `/schemas/...` endpoints |
| Wire format | Custom SerDe with its own wire format (e.g., content ID or global ID encoded differently) | Standard 5-byte prefix: magic byte `0x0` + 4-byte schema ID |

These differences affect schema organization, client configuration, and how schema identifiers are embedded in Kafka messages.

## Planned Migration Approach

The dedicated migration tool will follow a phased approach:

1. **Phase 1 -- Schema Export from Apicurio.** Extract all artifact groups, artifact versions, metadata, and compatibility rules from the source Apicurio Registry instance.

2. **Phase 2 -- Schema Mapping and Transformation.** Map Apicurio artifact group/artifact ID pairs to Confluent SR subject names. Transform metadata and compatibility rules into their Confluent equivalents.

3. **Phase 3 -- Import to Confluent SR.** Load the transformed schemas into Confluent Schema Registry with schema ID preservation where possible.

4. **Phase 4 -- Client Migration.** Update all producers and consumers to switch from Apicurio SerDe libraries to Confluent SerDe libraries, adjusting wire format expectations accordingly.

## In the Meantime

Manual migration is possible today using existing APIs and tooling:

- **Export from Apicurio** using the Apicurio REST API. List and retrieve artifacts per group:
  ```
  GET /apis/registry/v2/groups/{groupId}/artifacts
  GET /apis/registry/v2/groups/{groupId}/artifacts/{artifactId}/versions
  ```
- **Import to Confluent SR** using [srctl](https://github.com/akrishnanDG/srctl) or REST API scripts such as the [import-schemas.sh](../scripts/import-schemas.sh) script included in this guide.

### Key Considerations

- **Group-to-subject mapping:** Decide how Apicurio artifact groups map to Confluent subjects or contexts. A common pattern is `{groupId}.{artifactId}-value` as the subject name.
- **ID mismatch:** Apicurio's content ID and global ID are not equivalent to Confluent's schema ID. Plan for ID reassignment or use the Confluent import mode that allows setting IDs explicitly.
- **Wire format change:** Apicurio's SerDe encodes schema identifiers differently than Confluent's standard wire format. All producers and consumers must be updated to use Confluent SerDe libraries, and any in-flight data using the old wire format will need special handling during the transition.

## Resources

- [Apicurio Registry Documentation](https://www.apicur.io/registry/docs/)
- [srctl -- Schema Registry CLI tool](https://github.com/akrishnanDG/srctl)
- [Import schemas script](../scripts/import-schemas.sh)

## Contributing

If you would like to contribute to or test the Apicurio migration tool, reach out or watch this space for updates. Contributions around schema mapping logic and edge-case handling are especially welcome.
