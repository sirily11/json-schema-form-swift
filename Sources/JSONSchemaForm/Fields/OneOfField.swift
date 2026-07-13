import Collections
import JSONSchema
import SwiftUI

/// Implements a oneOf field that allows selecting between mutually exclusive schema options
/// oneOf requires EXACTLY ONE sub-schema to validate
struct OneOfField: Field {
    var schema: JSONSchema
    var uiSchema: [String: Any]?
    var id: String
    var formData: Binding<FormData>
    var required: Bool
    var propertyName: String?

    @State private var selectedOptionIndex: Int = 0

    /// Get the oneOf options from the combined schema (anyOf schemas reuse this
    /// field, so fall back to the anyOf branches)
    private var options: [JSONSchema] {
        schema.combinedSchema?.oneOf ?? schema.combinedSchema?.anyOf ?? []
    }

    /// Generate display titles for the picker options
    private var optionTitles: [String] {
        // Check for custom names in uiSchema
        if let enumNames = uiSchema?["ui:enumNames"] as? [String], enumNames.count == options.count {
            return enumNames
        }

        return options.enumerated().map { index, option in
            // Use schema title if available
            if let title = option.title ?? option.combinedSchema?.title {
                return title
            }

            // Use property names as title
            if let props = option.objectSchema?.properties, !props.isEmpty {
                let propNames = props.keys.sorted().joined(separator: ", ")
                return propNames
            }

            // Default to "Option N"
            return "Option \(index + 1)"
        }
    }

    /// Detect which option matches the current formData
    private func detectInitialOption() -> Int {
        guard case .object(let properties) = formData.wrappedValue else {
            return 0
        }

        // Find the option that best matches current formData based on required properties
        for (index, option) in options.enumerated() {
            if let required = option.objectSchema?.required, !required.isEmpty {
                let hasAllRequired = required.allSatisfy { properties[$0] != nil }
                if hasAllRequired {
                    return index
                }
            }
        }

        // Check which option has properties that match the formData keys
        let formDataKeys = Set(properties.keys)
        for (index, option) in options.enumerated() {
            if let optionProps = option.objectSchema?.properties {
                let optionKeys = Set(optionProps.keys)
                if !optionKeys.intersection(formDataKeys).isEmpty {
                    return index
                }
            }
        }

        return 0
    }

    /// Get properties for the selected option
    private var selectedProperties: OrderedDictionary<String, JSONSchema> {
        guard selectedOptionIndex < options.count else {
            return [:]
        }
        let selectedOption = options[selectedOptionIndex]
        if let props = selectedOption.objectSchema?.properties {
            var result = OrderedDictionary<String, JSONSchema>()
            for (key, value) in props {
                result[key] = value
            }
            return result
        }
        return [:]
    }

    /// Get required properties for the selected option
    private var selectedRequired: [String] {
        guard selectedOptionIndex < options.count else {
            return []
        }
        return options[selectedOptionIndex].objectSchema?.required ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Schema selector picker
            if options.count > 1 {
                Picker(fieldTitle.isEmpty ? "Select Option" : fieldTitle, selection: $selectedOptionIndex) {
                    ForEach(options.indices, id: \.self) { index in
                        Text(optionTitles[index]).tag(index)
                    }
                }
                .pickerStyle(.menu)
                .id("\(id)_oneOf_picker")
            }

            // Render selected option's fields
            if !selectedProperties.isEmpty {
                ForEach(Array(selectedProperties.keys), id: \.self) { propertyName in
                    if let propertySchema = selectedProperties[propertyName] {
                        propertyView(name: propertyName, schema: propertySchema)
                    }
                }
            } else if selectedOptionIndex < options.count {
                // Handle non-object schemas (primitive types in oneOf)
                let selectedSchema = options[selectedOptionIndex]
                SchemaField(
                    schema: selectedSchema,
                    uiSchema: getOptionUiSchema(index: selectedOptionIndex),
                    id: "\(id)_option_\(selectedOptionIndex)",
                    formData: formData,
                    required: required,
                    propertyName: propertyName
                )
            }
        }
        .onAppear {
            selectedOptionIndex = detectInitialOption()
        }
        .onChange(of: selectedOptionIndex) { _, newValue in
            resetFormDataForOption(newValue)
        }
    }

    /// Get uiSchema for a specific option
    private func getOptionUiSchema(index: Int) -> [String: Any]? {
        if let oneOfUiSchema = uiSchema?["oneOf"] as? [[String: Any]] {
            return oneOfUiSchema.indices.contains(index) ? oneOfUiSchema[index] : nil
        }
        return uiSchema
    }

    /// Reset formData when switching between options
    private func resetFormDataForOption(_ index: Int) {
        guard index < options.count else { return }
        let newOption = options[index]

        // Initialize with empty object for the new option
        if let props = newOption.objectSchema?.properties {
            var newProperties: [String: FormData] = [:]
            for (name, propSchema) in props {
                newProperties[name] = FormData.fromSchemaType(schema: propSchema)
            }
            formData.wrappedValue = FormData.object(properties: newProperties)
        }
    }

    /// Create a binding for a specific property
    private func schemaBinding(name: String) -> Binding<FormData> {
        if case .object(let properties) = formData.wrappedValue {
            return Binding<FormData>(
                get: {
                    properties[name] ?? FormData.fromSchemaType(schema: selectedProperties[name] ?? schema)
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

    /// Render a property field
    @ViewBuilder
    private func propertyView(name: String, schema: JSONSchema) -> some View {
        if case .object = formData.wrappedValue {
            // Get property-specific uiSchema if it exists
            let optionUiSchema = getOptionUiSchema(index: selectedOptionIndex)
            let propertyUiSchema = optionUiSchema?[name] as? [String: Any]

            // Check if property is required
            let isRequired = selectedRequired.contains(name)

            // Create a unique ID for this field
            let fieldId = "\(id)_\(name)"

            // Render the appropriate field based on schema type
            SchemaField(
                schema: schema,
                uiSchema: propertyUiSchema,
                id: fieldId,
                formData: schemaBinding(name: name),
                required: isRequired,
                propertyName: name
            )
        } else {
            InvalidValueType(
                valueType: formData.wrappedValue,
                expectedType: FormData.object(properties: [:])
            )
        }
    }
}
