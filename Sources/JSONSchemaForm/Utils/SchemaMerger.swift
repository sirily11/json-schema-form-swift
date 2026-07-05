import Foundation
import JSONSchema

/// Utility for merging multiple schemas (used by AllOfField)
public enum SchemaMerger {

    /// Merges conditional schemas (raw JSON dictionaries) with a base merged schema
    /// Used for if/then/else conditional schema support
    public static func mergeWithConditionals(
        baseMerged: MergedSchema,
        conditionalSchemas: [[String: Any]]
    ) -> MergedSchema {
        var mergedProperties = baseMerged.properties
        var mergedRequired = Set(baseMerged.required)

        for schemaDict in conditionalSchemas {
            // Extract properties from conditional schema
            if let properties = schemaDict["properties"] as? [String: Any] {
                for (name, propDict) in properties {
                    if let propSchema = propDict as? [String: Any] {
                        // Parse the property schema
                        if let jsonSchema = parsePropertySchema(propSchema, name: name) {
                            mergedProperties[name] = jsonSchema
                        }
                    }
                }
            }

            // Extract required fields
            if let required = schemaDict["required"] as? [String] {
                mergedRequired.formUnion(required)
            }
        }

        return MergedSchema(
            title: baseMerged.title,
            description: baseMerged.description,
            properties: mergedProperties,
            required: Array(mergedRequired),
            mergedType: baseMerged.mergedType,
            minimum: baseMerged.minimum,
            maximum: baseMerged.maximum,
            allSchemas: baseMerged.allSchemas
        )
    }

    /// Parse a raw property schema dictionary into a JSONSchema
    static func parsePropertySchema(_ propDict: [String: Any], name: String) -> JSONSchema? {
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: propDict, options: [])
            let schema = try JSONDecoder().decode(JSONSchema.self, from: jsonData)
            return schema
        } catch {
            // If parsing fails, try to create a minimal schema
            return nil
        }
    }

    /// Get property names from conditional schemas without parsing
    public static func getPropertyNamesFromConditionals(_ conditionalSchemas: [[String: Any]]) -> Set<String> {
        var propertyNames: Set<String> = []
        for schemaDict in conditionalSchemas {
            if let properties = schemaDict["properties"] as? [String: Any] {
                propertyNames.formUnion(properties.keys)
            }
        }
        return propertyNames
    }

    /// Merges multiple schemas into a single schema by combining their properties
    /// For allOf: all sub-schemas must validate, so we merge all properties
    public static func merge(schemas: [JSONSchema], baseSchema: JSONSchema? = nil) -> MergedSchema {
        var mergedProperties: [String: JSONSchema] = [:]
        var mergedRequired: Set<String> = []
        var mergedTitle: String?
        var mergedDescription: String?

        // Primitive type merging
        var mergedType: JSONSchema.SchemaType?
        var minimum: Int?
        var maximum: Int?

        // Start with base schema if provided
        if let base = baseSchema {
            mergedTitle = base.title
            mergedDescription = base.description

            if let props = base.objectSchema?.properties {
                mergedProperties.merge(props) { _, new in new }
            }
            if let required = base.objectSchema?.required {
                mergedRequired.formUnion(required)
            }
        }

        // Merge each sub-schema
        for schema in schemas {
            // Take first non-nil title
            if mergedTitle == nil {
                mergedTitle = schema.title ?? schema.combinedSchema?.title
            }

            // Take first non-nil description
            if mergedDescription == nil {
                mergedDescription = schema.description
            }

            // Merge properties
            if let props = schema.objectSchema?.properties {
                for (name, propSchema) in props {
                    if mergedProperties[name] != nil {
                        // Property exists - keep the later one (more specific)
                        mergedProperties[name] = propSchema
                    } else {
                        mergedProperties[name] = propSchema
                    }
                }
            }

            // Merge required (union of all)
            if let required = schema.objectSchema?.required {
                mergedRequired.formUnion(required)
            }

            // Detect and merge primitive types
            if schema.type == .integer || schema.type == .number {
                mergedType = mergedType ?? schema.type
            }

            // Merge integer constraints
            if let intSchema = schema.integerSchema {
                if let min = intSchema.minimum {
                    minimum = max(minimum ?? min, min)  // Take stricter constraint
                }
                if let max = intSchema.maximum {
                    maximum = min(maximum ?? max, max)  // Take stricter constraint
                }
            }

            // Merge number constraints
            if let numSchema = schema.numberSchema {
                if let min = numSchema.minimum {
                    let intMin = Int(min)
                    minimum = max(minimum ?? intMin, intMin)
                }
                if let max = numSchema.maximum {
                    let intMax = Int(max)
                    maximum = min(maximum ?? intMax, intMax)
                }
            }
        }

        return MergedSchema(
            title: mergedTitle,
            description: mergedDescription,
            properties: mergedProperties,
            required: Array(mergedRequired),
            mergedType: mergedType,
            minimum: minimum,
            maximum: maximum,
            allSchemas: schemas
        )
    }

    /// Represents a merged schema result
    public struct MergedSchema {
        public let title: String?
        public let description: String?
        public let properties: [String: JSONSchema]
        public let required: [String]

        // Primitive type merging
        public let mergedType: JSONSchema.SchemaType?
        public let minimum: Int?
        public let maximum: Int?

        // Keep reference to all original schemas for validation
        public let allSchemas: [JSONSchema]

        public var isEmpty: Bool {
            properties.isEmpty && mergedType == nil
        }

        public var isPrimitive: Bool {
            mergedType != nil && properties.isEmpty
        }
    }
}
