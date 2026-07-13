import Collections
import JSONSchema
import SwiftUI

/// Implements an object field that renders a group of property fields
struct ObjectField: Field {
    var schema: JSONSchema
    var uiSchema: [String: Any]?
    var id: String
    var formData: Binding<FormData>
    var required: Bool
    var propertyName: String?
    var widgets: [String: JSONSchemaFormWidget] = [:]
    var foreignKey: ForeignKeyConfiguration?

    @Environment(\.formTemplates) private var templates

    /// Conditionals (`if`/`then`/`else`) declared on THIS object schema,
    /// extracted from the raw schema JSON at init and delivered through the
    /// uiSchema side-channel (`__objectConditionals`), keyed by field ID.
    private var localConditionals: [ConditionalSchema] {
        guard let map = uiSchema?["__objectConditionals"] as? [String: [ConditionalSchema]] else {
            return []
        }
        return map[id] ?? []
    }

    /// The `then`/`else` branch schemas whose conditions currently match this
    /// object's own form data.
    private var activeBranchSchemas: [[String: Any]] {
        let conditionals = localConditionals
        guard !conditionals.isEmpty else { return [] }
        return ConditionEvaluator.getApplicableSchemas(
            conditionals: conditionals,
            formData: formData.wrappedValue
        )
    }

    /// Property names declared only in non-matching conditional branches.
    /// These must not render — not even through the custom-widget ui:order
    /// fallback below. Their values are intentionally kept in formData so a
    /// hidden field's value is restored when the condition flips back.
    private var hiddenConditionalKeys: Set<String> {
        let conditionals = localConditionals
        guard !conditionals.isEmpty else { return [] }
        var declared: Set<String> = []
        for conditional in conditionals {
            for branch in [conditional.thenSchema, conditional.elseSchema] {
                if let props = branch?["properties"] as? [String: Any] {
                    declared.formUnion(props.keys)
                }
            }
        }
        var visible = Set((schema.objectSchema?.properties ?? [:]).keys)
        visible.formUnion(SchemaMerger.getPropertyNamesFromConditionals(activeBranchSchemas))
        return declared.subtracting(visible)
    }

    // Extract properties from schema, using ui:order or JSON-defined order when available
    private var properties: OrderedDictionary<String, JSONSchema>? {
        guard case .object = schema.type else {
            return nil
        }

        var dict = schema.objectSchema?.properties ?? [:]
        // Merge properties from matching conditional branches (branch wins —
        // it is the more specific schema, mirroring AllOfField's merge).
        for branch in activeBranchSchemas {
            guard let props = branch["properties"] as? [String: Any] else { continue }
            for (name, raw) in props {
                if let rawSchema = raw as? [String: Any],
                    let parsed = SchemaMerger.parsePropertySchema(rawSchema, name: name)
                {
                    dict[name] = parsed
                }
            }
        }
        let hidden = hiddenConditionalKeys

        // Priority: 1. ui:order from uiSchema, 2. JSON-defined order, 3. dictionary iteration order
        let orderedKeys: [String]
        if let uiOrder = uiSchema?["ui:order"] as? [String] {
            // Use ui:order from uiSchema. Keys missing from schema can still render
            // when they declare a custom widget in uiSchema — unless they belong
            // to a non-matching conditional branch.
            let orderedFromUi = uiOrder.filter {
                !hidden.contains($0) && (dict.keys.contains($0) || hasCustomWidget($0))
            }
            let remainingKeys = dict.keys.filter { !uiOrder.contains($0) }
            orderedKeys = orderedFromUi + remainingKeys
        } else if let orderMap = uiSchema?["__propertyKeyOrder"] as? [String: [String]],
            let jsonOrder = orderMap[id]
        {
            // Use the original JSON property order, filtering to keys present in
            // schema; conditional-branch keys are absent from the raw property
            // order, so append them at the end.
            let orderedFromJson = jsonOrder.filter { dict.keys.contains($0) }
            let remainingKeys = dict.keys.filter { !jsonOrder.contains($0) }
            orderedKeys = orderedFromJson + remainingKeys
        } else {
            orderedKeys = Array(dict.keys)
        }

        var orderedProperties = OrderedDictionary<String, JSONSchema>()
        for key in orderedKeys {
            orderedProperties[key] = dict[key] ?? virtualSchema(for: key)
        }
        return orderedProperties
    }

    private func hasCustomWidget(_ name: String) -> Bool {
        guard let propertyUiSchema = uiSchema?[name] as? [String: Any],
              let widgetName = propertyUiSchema["ui:widget"] as? String else {
            return false
        }
        return widgets[widgetName] != nil || widgetName == ForeignKeyField.widgetName
    }

    private func virtualSchema(for name: String) -> JSONSchema? {
        guard hasCustomWidget(name) else { return nil }
        return JSONSchema.string()
    }

    // Get required properties from schema, including matching conditional branches
    private var requiredProperties: [String]? {
        guard case .object = schema.type else {
            return nil
        }

        var required = schema.objectSchema?.required ?? []
        for branch in activeBranchSchemas {
            guard let branchRequired = branch["required"] as? [String] else { continue }
            for name in branchRequired where !required.contains(name) {
                required.append(name)
            }
        }
        return required
    }

    /// Object template name requested by the schema's uiSchema, if any.
    private var objectTemplateName: String? {
        uiSchema?["ui:objectTemplate"] as? String
    }

    var body: some View {
        if let template = templates.object(for: objectTemplateName) {
            // Custom (rjsf-style) object layout supplied by the consumer.
            template(
                JSONSchemaFormObjectTemplateContext(
                    id: id,
                    title: fieldTitle,
                    description: schema.description,
                    required: required,
                    uiSchema: uiSchema,
                    properties: templateProperties()
                ))
        } else if fieldTitle.isEmpty {
            Section {
                propertyList
            }
        } else {
            Section(fieldTitle) {
                propertyList
            }
        }
    }

    @ViewBuilder
    private var propertyList: some View {
        // Render properties according to the order
        if let properties = properties {
            ForEach(Array(properties.keys), id: \.self) { propertyName in
                if let propertySchema = properties[propertyName] {
                    propertyView(name: propertyName, schema: propertySchema)
                }
            }
        }
    }

    /// Build the ordered list of rendered child properties for a custom template.
    private func templateProperties() -> [JSONSchemaFormObjectTemplateProperty] {
        guard let properties = properties else { return [] }
        return properties.keys.compactMap { name in
            guard let propertySchema = properties[name] else { return nil }
            return JSONSchemaFormObjectTemplateProperty(
                name: name,
                id: "\(id)_\(name)",
                content: AnyView(propertyView(name: name, schema: propertySchema))
            )
        }
    }

    private func schemaBinding(name: String) -> Binding<FormData> {
        if case .object(let properties) = formData.wrappedValue {
            return Binding<FormData>(
                get: {
                    properties[name] ?? FormData.fromSchemaType(schema: schema)
                },
                set: { newValue in
                    var updatedProperties = properties
                    updatedProperties[name] = newValue
                    formData.wrappedValue = FormData.object(properties: updatedProperties)
                }
            )
        }
        return formData
    }

    /// Computes the uiSchema for a child property, propagating property key
    /// order and object-level conditionals
    private func childUiSchema(for name: String) -> [String: Any]? {
        var result = uiSchema?[name] as? [String: Any]
        if let orderMap = uiSchema?["__propertyKeyOrder"] {
            if result == nil {
                result = [:]
            }
            result?["__propertyKeyOrder"] = orderMap
        }
        if let conditionals = uiSchema?["__objectConditionals"] {
            if result == nil {
                result = [:]
            }
            result?["__objectConditionals"] = conditionals
        }
        return result
    }

    // Render a property field
    @ViewBuilder
    private func propertyView(name: String, schema: JSONSchema) -> some View {
        if case .object = formData.wrappedValue {
            // Get property-specific uiSchema with propagated property key order
            let propertyUiSchema = childUiSchema(for: name)

            // Check if property is required
            let isRequired = requiredProperties?.contains(name) ?? false

            // Create a unique ID for this field
            let fieldId = "\(id)_\(name)"

            // Render the appropriate field based on schema type
            SchemaField(
                schema: schema,
                uiSchema: propertyUiSchema,
                id: fieldId,
                formData: schemaBinding(name: name),
                required: isRequired,
                propertyName: name,
                widgets: widgets,
                foreignKey: foreignKey
            )
        } else {
            InvalidValueType(
                valueType: formData.wrappedValue,
                expectedType: FormData.object(properties: [:])
            )
        }
    }

    // Helper method to get schema type name
    private func getSchemaType(_ schema: JSONSchema) -> String {
        switch schema.type {
        case .string:
            return "string"
        case .number:
            return "number"
        case .integer:
            return "integer"
        case .boolean:
            return "boolean"
        case .array:
            return "array"
        case .object:
            return "object"
        case .null:
            return "null"
        default:
            return "unknown"
        }
    }

    // In a real implementation, you would need methods to handle:
    // - Updating individual property values
    // - Adding additional properties if allowed
    // - Removing properties
}
