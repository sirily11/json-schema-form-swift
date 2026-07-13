import JSONSchema
import SwiftUI

/// SchemaField is the main field component that determines which specific field to render
/// based on the schema type.
struct SchemaField: Field {
    var schema: JSONSchema
    var uiSchema: [String: Any]?
    var id: String
    var formData: Binding<FormData>
    var required: Bool
    var propertyName: String?

    /// Conditional schemas for if/then/else support (passed to AllOfField)
    var conditionalSchemas: [ConditionalSchema]?

    /// Custom widgets keyed by `ui:widget`.
    var widgets: [String: JSONSchemaFormWidget]

    /// App-supplied configuration for built-in `foreign-key` fields.
    var foreignKey: ForeignKeyConfiguration?

    /// Access to the form controller for field-level error display
    @Environment(\.formController) private var formController

    /// Returns field-level errors for this field from the controller
    private var currentFieldErrors: [String]? {
        guard let errors = formController?.errorsForField(id), !errors.isEmpty else {
            return nil
        }
        return errors
    }

    // Extract the field widget from uiSchema if present
    private var uiField: String? {
        return uiSchema?["ui:field"] as? String
    }

    private var uiWidget: String? {
        return uiSchema?["ui:widget"] as? String
    }

    init(
        schema: JSONSchema, uiSchema: [String: Any]?, id: String, formData: Binding<FormData>,
        required: Bool, propertyName: String? = nil, conditionalSchemas: [ConditionalSchema]? = nil,
        widgets: [String: JSONSchemaFormWidget] = [:],
        foreignKey: ForeignKeyConfiguration? = nil
    ) {
        self.schema = schema
        self.uiSchema = uiSchema
        self.id = id
        self.formData = formData
        self.required = required
        self.propertyName = propertyName
        self.conditionalSchemas = conditionalSchemas
        self.widgets = widgets
        self.foreignKey = foreignKey
    }

    /// The non-null branch when this anyOf schema is just a nullable wrapper
    /// (`anyOf: [X, {type: "null"}]`), or nil for genuine multi-branch anyOf.
    private var nullableBranch: JSONSchema? {
        guard let branches = schema.combinedSchema?.anyOf, branches.count == 2 else { return nil }
        let nonNull = branches.filter { $0.type != .null }
        return nonNull.count == 1 ? nonNull.first : nil
    }

    /// Returns a binding for schema data that correctly updates the parent form data
    private func schemaDataBinding(schemaType: JSONSchema.SchemaType) -> Binding<FormData> {
        if let propertyName = propertyName {
            // This is a nested field, create a binding that updates the parent
            return Binding<FormData>(
                get: {
                    if schemaType == .object {
                        return formData.wrappedValue
                    }
                    if case .object(let properties) = formData.wrappedValue {
                        return properties[propertyName] ?? FormData.fromSchemaType(schema: schema)
                    }
                    return formData.wrappedValue
                },
                set: { newValue in
                    formData.wrappedValue = newValue
                }
            )
        } else {
            // This is a root-level field, use the formData binding directly
            return formData
        }
    }

    var body: some View {
        Group {
            if let uiWidget, let widget = widgets[uiWidget] {
                widget(JSONSchemaFormWidgetContext(
                    id: id,
                    propertyName: propertyName,
                    schema: schema,
                    uiSchema: uiSchema,
                    formData: schemaDataBinding(schemaType: schema.type),
                    required: required
                ))
            } else if uiWidget == ForeignKeyField.widgetName {
                // Built-in foreign-key field: a row pushing a dedicated
                // searchable, paginated picker page. An app-registered
                // widget of the same name (above) still takes precedence.
                TemplatedField(
                    id: id,
                    label: fieldTitle,
                    description: schema.description,
                    errors: currentFieldErrors,
                    required: required,
                    uiSchema: uiSchema
                ) {
                    ForeignKeyField(
                        schema: schema,
                        uiSchema: uiSchema,
                        id: id,
                        formData: schemaDataBinding(schemaType: schema.type),
                        required: required,
                        propertyName: propertyName,
                        configuration: foreignKey
                    )
                }
            } else if let customField = uiField {
                // If a custom field is specified in uiSchema, use it
                // In a complete implementation, this would look up the custom field
                // from a registry and render it
                Text("Custom field: \(customField)")
                    .foregroundColor(.blue)
            } else {
                // Otherwise, determine the appropriate field based on schema type
                renderFieldBasedOnSchemaType()
            }
        }
    }

    @ViewBuilder
    private func renderFieldBasedOnSchemaType() -> some View {
        switch schema.type {
        case .string:
            TemplatedField(
                id: id,
                label: fieldTitle,
                description: schema.description,
                errors: currentFieldErrors,
                required: required,
                uiSchema: uiSchema
            ) {
                StringField(
                    schema: schema,
                    uiSchema: uiSchema,
                    id: id,
                    formData: schemaDataBinding(schemaType: schema.type),
                    required: required,
                    propertyName: propertyName
                )
            }

        case .number:
            TemplatedField(
                id: id,
                label: fieldTitle,
                description: schema.description,
                errors: currentFieldErrors,
                required: required,
                uiSchema: uiSchema
            ) {
                NumberField(
                    schema: schema,
                    uiSchema: uiSchema,
                    id: id,
                    formData: schemaDataBinding(schemaType: schema.type),
                    required: required,
                    propertyName: propertyName
                )
            }

        case .integer:
            TemplatedField(
                id: id,
                label: fieldTitle,
                description: schema.description,
                errors: currentFieldErrors,
                required: required,
                uiSchema: uiSchema
            ) {
                NumberField(
                    schema: schema,
                    uiSchema: uiSchema,
                    id: id,
                    formData: schemaDataBinding(schemaType: schema.type),
                    required: required,
                    propertyName: propertyName
                )
            }

        case .boolean:
            TemplatedField(
                id: id,
                label: fieldTitle,
                description: schema.description,
                errors: currentFieldErrors,
                required: required,
                uiSchema: uiSchema
            ) {
                BooleanField(
                    schema: schema,
                    uiSchema: uiSchema,
                    id: id,
                    formData: schemaDataBinding(schemaType: schema.type),
                    required: required,
                    propertyName: propertyName
                )
            }

        case .object:
            // Object fields have their own template (ObjectFieldTemplate)
            if schema.combinedSchema?.allOf != nil || conditionalSchemas?.isEmpty == false {
                AllOfField(
                    schema: schema,
                    uiSchema: uiSchema,
                    id: id,
                    formData: schemaDataBinding(schemaType: schema.type),
                    required: required,
                    propertyName: propertyName,
                    conditionalSchemas: conditionalSchemas
                )
            } else {
                ObjectField(
                    schema: schema,
                    uiSchema: uiSchema,
                    id: id,
                    formData: schemaDataBinding(schemaType: schema.type),
                    required: required,
                    propertyName: propertyName,
                    widgets: widgets,
                    foreignKey: foreignKey
                )
            }

        case .array:
            // Array fields have their own template (ArrayFieldTemplate)
            ArrayField(
                schema: schema,
                uiSchema: uiSchema,
                id: id,
                formData: schemaDataBinding(schemaType: schema.type),
                required: required,
                propertyName: propertyName
            )

        case .null:
            TemplatedField(
                id: id,
                label: fieldTitle,
                description: schema.description,
                errors: currentFieldErrors,
                required: required,
                uiSchema: uiSchema
            ) {
                Text("null")
                    .foregroundColor(.gray)
                    .italic()
            }

        case .enum:
            TemplatedField(
                id: id,
                label: fieldTitle,
                description: schema.description,
                errors: currentFieldErrors,
                required: required,
                uiSchema: uiSchema
            ) {
                EnumField(
                    schema: schema,
                    uiSchema: uiSchema,
                    id: id,
                    formData: schemaDataBinding(schemaType: schema.type),
                    required: required,
                    propertyName: propertyName
                )
            }

        case .oneOf:
            // OneOf fields have their own complex layout
            OneOfField(
                schema: schema,
                uiSchema: uiSchema,
                id: id,
                formData: schemaDataBinding(schemaType: schema.type),
                required: required,
                propertyName: propertyName
            )

        case .anyOf:
            if let nonNullBranch = nullableBranch {
                // Nullable wrapper (anyOf: [X, {type: null}]) — render the non-null
                // branch directly so its title/description/enum surface as a normal field.
                SchemaField(
                    schema: nonNullBranch,
                    uiSchema: uiSchema,
                    id: id,
                    formData: formData,
                    required: false,
                    propertyName: propertyName,
                    widgets: widgets,
                    foreignKey: foreignKey
                )
            } else {
                // AnyOf fields use OneOfField with their own layout
                OneOfField(
                    schema: schema,
                    uiSchema: uiSchema,
                    id: id,
                    formData: schemaDataBinding(schemaType: schema.type),
                    required: required,
                    propertyName: propertyName
                )
            }

        case .allOf:
            // AllOf fields have their own complex layout
            AllOfField(
                schema: schema,
                uiSchema: uiSchema,
                id: id,
                formData: schemaDataBinding(schemaType: schema.type),
                required: required,
                propertyName: propertyName,
                conditionalSchemas: conditionalSchemas
            )
        }
    }
}
