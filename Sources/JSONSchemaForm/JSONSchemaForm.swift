// The Swift Programming Language
// https://docs.swift.org/swift-book

import JSONSchema
import JSONSchemaValidator
import SwiftUI

// MARK: - JSONSchemaForm

/// A SwiftUI form component that renders a form from a JSON Schema.
///
/// `JSONSchemaForm` dynamically generates form fields based on a JSON Schema definition,
/// handles validation, and manages form state. It supports live validation, programmatic
/// submission, and customizable error handling through the `JSONSchemaFormController`.
///
/// ## Overview
///
/// The form automatically:
/// - Renders appropriate field types based on schema (string, number, boolean, object, array)
/// - Validates input against schema constraints
/// - Displays validation errors at form and field levels
/// - Supports conditional schemas (if/then/else, oneOf, anyOf, allOf)
///
/// ## Usage
///
/// ### Basic Usage
///
/// ```swift
/// @State private var formData = FormData.object(properties: [:])
///
/// var body: some View {
///     if let schema = try? JSONSchema(jsonString: schemaJSON) {
///         JSONSchemaForm(
///             schema: schema,
///             formData: $formData
///         )
///     }
/// }
/// ```
///
/// ### With Controller for Programmatic Control
///
/// ```swift
/// let controller = JSONSchemaFormController()
///
/// JSONSchemaForm(
///     schema: schema,
///     formData: $formData,
///     liveValidate: true,
///     controller: controller
/// )
///
/// Button("Submit") {
///     Task {
///         let success = try await controller.submit()
///     }
/// }
/// ```
///
/// ### With Error Handling
///
/// ```swift
/// let controller = JSONSchemaFormController()
/// controller.onValidationError = { errors in
///     for error in errors {
///         print(error.description)
///     }
/// }
///
/// JSONSchemaForm(
///     schema: schema,
///     formData: $formData,
///     liveValidate: true,
///     showErrorList: true,
///     controller: controller
/// )
/// ```
public struct JSONSchemaForm: View {
    // MARK: - Properties

    /// The schema defining the form structure
    let schema: JSONSchema

    /// Optional UI schema for customizing the form appearance
    var uiSchema: [String: Any]?

    /// Binding to the form data
    var formData: Binding<FormData>

    /// Conditional schemas for if/then/else support (extracted during preprocessing)
    var conditionalSchemas: [ConditionalSchema]?

    /// Callback when form is submitted successfully (legacy callback, prefer using controller)
    var onSubmit: ((Any?) -> Void)?

    /// Callback when form validation has errors (legacy callback, prefer using controller)
    var onError: (([FormValidationError]) -> Void)?

    /// Form context for passing data to fields
    var formContext: [String: Any]?

    /// Whether to validate the form as the user types
    var liveValidate: Bool = false

    /// Whether to show the error list at the top of the form
    var showErrorList: Bool = false

    /// Whether to show the built-in submit button
    var showSubmitButton: Bool = true

    /// Custom error transformer for modifying validation errors before display
    var transformErrors: (([ValidationError]) -> [ValidationError])?

    /// Whether the form is disabled
    var disabled: Bool = false

    /// Whether the form is read-only
    var readonly: Bool = false

    /// Additional custom validation function
    var customValidate: ((Any?, inout [String: Any]) -> Void)?

    /// Custom widgets keyed by `ui:widget`.
    var widgets: [String: JSONSchemaFormWidget]

    /// Custom object/field templates (rjsf-style), selected per-field via
    /// `ui:objectTemplate` / `ui:fieldTemplate` names, with optional defaults.
    var templates: JSONSchemaFormTemplates

    /// Configuration for `ui:widget: "foreign-key"` fields: the app's
    /// authenticated search client plus the selected-item transform.
    var foreignKey: ForeignKeyConfiguration?

    /// String prefix for field IDs
    var idPrefix: String = "root"

    /// String separator for field IDs
    var idSeparator: String = "_"

    // MARK: - Controller

    /// External controller provided by the user
    private var externalController: JSONSchemaFormController?

    /// Internal controller created when no external controller is provided
    @State private var internalController: JSONSchemaFormController = JSONSchemaFormController()

    /// The active controller (external or internal)
    private var controller: JSONSchemaFormController {
        externalController ?? internalController
    }

    /// Tracks whether the controller has been configured
    @State private var isConfigured: Bool = false

    // MARK: - Initialization

    /// Initializes a new JSONSchemaForm
    ///
    /// - Parameters:
    ///   - schema: The JSON Schema defining the form structure
    ///   - uiSchema: Optional UI schema for customizing field appearance
    ///   - formData: Binding to the form data
    ///   - schemaJSON: Optional raw JSON schema string. When provided, property key ordering
    ///     is extracted from the JSON to preserve the original definition order.
    ///   - conditionalSchemas: Pre-extracted conditional schemas for if/then/else support
    ///   - onSubmit: Legacy callback when form is submitted successfully
    ///   - onError: Legacy callback when validation errors occur
    ///   - formContext: Additional context data passed to fields
    ///   - liveValidate: Whether to validate as the user types (default: false)
    ///   - showErrorList: Whether to show error list at top of form (default: false)
    ///   - showSubmitButton: Whether to show built-in submit button (default: true)
    ///   - transformErrors: Function to transform validation errors before display
    ///   - disabled: Whether the form is disabled (default: false)
    ///   - readonly: Whether the form is read-only (default: false)
    ///   - customValidate: Additional custom validation function
    ///   - widgets: Custom widgets keyed by `ui:widget`
    ///   - foreignKey: Configuration for `ui:widget: "foreign-key"` fields
    ///     (search client + selected-item transform). Without it those
    ///     fields fall back to plain string inputs.
    ///   - idPrefix: Prefix for field IDs (default: "root")
    ///   - idSeparator: Separator for field IDs (default: "_")
    ///   - controller: Optional controller for programmatic form control
    public init(
        schema: JSONSchema,
        uiSchema: [String: Any]? = nil,
        formData: Binding<FormData>,
        schemaJSON: String? = nil,
        conditionalSchemas: [ConditionalSchema]? = nil,
        onSubmit: ((Any?) -> Void)? = nil,
        onError: (([FormValidationError]) -> Void)? = nil,
        formContext: [String: Any]? = nil,
        liveValidate: Bool = false,
        showErrorList: Bool = false,
        showSubmitButton: Bool = true,
        transformErrors: (([ValidationError]) -> [ValidationError])? = nil,
        disabled: Bool = false,
        readonly: Bool = false,
        customValidate: ((Any?, inout [String: Any]) -> Void)? = nil,
        widgets: [String: JSONSchemaFormWidget] = [:],
        templates: JSONSchemaFormTemplates = JSONSchemaFormTemplates(),
        foreignKey: ForeignKeyConfiguration? = nil,
        idPrefix: String = "root",
        idSeparator: String = "_",
        controller: JSONSchemaFormController? = nil
    ) {
        self.schema = schema
        self.formData = formData
        self.conditionalSchemas = conditionalSchemas

        // Merge property key order and object-level if/then/else conditionals
        // into uiSchema so they flow through the view hierarchy
        var mergedUiSchema = uiSchema
        if let order = schemaJSON.flatMap({
            PropertyOrderExtractor.extractPropertyOrder(
                from: $0, idPrefix: idPrefix, idSeparator: idSeparator)
        }) {
            var merged = mergedUiSchema ?? [:]
            merged["__propertyKeyOrder"] = order
            mergedUiSchema = merged
        }
        if let objectConditionals = schemaJSON.flatMap({
            ObjectConditionalExtractor.extract(
                from: $0, idPrefix: idPrefix, idSeparator: idSeparator)
        }) {
            var merged = mergedUiSchema ?? [:]
            merged["__objectConditionals"] = objectConditionals
            mergedUiSchema = merged
        }
        self.uiSchema = mergedUiSchema

        self.onSubmit = onSubmit
        self.onError = onError
        self.formContext = formContext
        self.liveValidate = liveValidate
        self.showErrorList = showErrorList
        self.showSubmitButton = showSubmitButton
        self.transformErrors = transformErrors
        self.disabled = disabled
        self.readonly = readonly
        self.customValidate = customValidate
        self.widgets = widgets
        self.templates = templates
        self.foreignKey = foreignKey
        self.idPrefix = idPrefix
        self.idSeparator = idSeparator
        self.externalController = controller
    }

    // MARK: - Body

    public var body: some View {
        Group {
            if showErrorList && !controller.errors.isEmpty {
                errorList
            }

            SchemaField(
                schema: schema,
                uiSchema: uiSchema,
                id: idPrefix,
                formData: formData,
                required: false,
                conditionalSchemas: conditionalSchemas,
                widgets: widgets,
                foreignKey: foreignKey
            )

            if showSubmitButton {
                submitButton
            }
        }
        .environment(\.formController, controller)
        .environment(\.formTemplates, templates)
        .onAppear {
            configureControllerIfNeeded()
        }
        .onChange(of: formData.wrappedValue) { _, _ in
            controller.handleFormDataChange()
        }
    }

    // MARK: - Private Views

    /// Renders the error list at the top of the form
    private var errorList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Errors")
                .font(.headline)
                .foregroundColor(.red)

            ForEach(controller.errors.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)

                    Text(controller.errors[index].description)
                        .foregroundColor(.red)
                }
                .padding(.vertical, 4)
            }
        }
        .padding()
        .background(Color.red.opacity(0.05))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.red.opacity(0.3), lineWidth: 1)
        )
        .padding(.bottom, 16)
    }

    /// Renders the submit button
    private var submitButton: some View {
        Button("Submit") {
            Task {
                do {
                    let success = try await controller.submit()
                    if success {
                        onSubmit?(formData.wrappedValue.toDictionary())
                    }
                } catch {
                    // Handle unexpected errors
                }
            }
        }
        .disabled(disabled || controller.isSubmitting)
    }

    // MARK: - Private Methods

    /// Configures the controller with form settings
    private func configureControllerIfNeeded() {
        guard !isConfigured else { return }

        // Set up callbacks to bridge to legacy callbacks
        controller.onValidationError = { [onError] errors in
            // Convert SchemaValidationError to form's FormValidationError for legacy callback
            let formErrors = errors.map { error in
                FormValidationError(
                    name: String(describing: type(of: error)),
                    message: error.description,
                    stack: error.description,
                    property: nil
                )
            }
            onError?(formErrors)
        }

        controller.onSubmitSuccess = { [onSubmit] formData in
            onSubmit?(formData.toDictionary())
        }

        controller.configure(
            schema: schema,
            formData: formData,
            liveValidate: liveValidate,
            customValidate: customValidate,
            transformErrors: transformErrors
        )

        isConfigured = true
    }
}

// MARK: - Previews

#Preview("Basic Form") {
    struct PreviewWrapper: View {
        @State private var formData = FormData.object(properties: [
            "initial_capital": .number(10000),
            "broker": .string("Interactive Brokers"),
            "start_time": .array(items: []),
            "end_time": .array(items: []),
            "decimal_precision": .number(2),
        ])

        let schemaJSON = """
            {
              "$schema": "https://json-schema.org/draft/2020-12/schema",
              "type": "object",
              "additionalProperties": false,
              "required": [
                "initial_capital",
                "broker",
                "decimal_precision"
              ],
              "properties": {
                "initial_capital": {
                  "type": "number",
                  "minimum": 0,
                  "title": "Initial Capital",
                  "description": "Starting capital for the backtest in USD"
                },
                "broker": {
                  "type": "string",
                  "title": "Broker",
                  "description": "The broker to use for commission calculations"
                },
                "start_time": {
                  "type": "array",
                  "title": "Start Time",
                  "description": "Optional start time for the backtest period",
                  "items": {
                    "type": "string",
                    "format": "date-time"
                  }
                },
                "end_time": {
                  "type": "array",
                  "title": "End Time",
                  "description": "Optional end time for the backtest period",
                  "items": {
                    "type": "string",
                    "format": "date"
                  }
                },
                "decimal_precision": {
                  "type": "integer",
                  "minimum": 0,
                  "title": "Decimal Precision",
                  "description": "The number of decimal places allowed for quantity",
                  "default": 1
                }
              }
            }
            """

        var body: some View {
            if let schema = try? JSONSchema(jsonString: schemaJSON) {
                Form {
                    Section("Settings") {
                        JSONSchemaForm(
                            schema: schema,
                            formData: $formData,
                            schemaJSON: schemaJSON,
                            showSubmitButton: false
                        )
                    }
                }
                .formStyle(.grouped)
            } else {
                Text("Failed to parse schema")
            }
        }
    }

    return PreviewWrapper()
}

#Preview("Form with Field-Level Errors") {
    struct ErrorPreviewWrapper: View {
        @State private var formData = FormData.object(properties: [
            "name": .string("Jo"),  // Too short - will trigger minLength error
            "email": .string("invalid-email"),  // Invalid format
            "age": .number(-5),  // Negative - will trigger minimum error
        ])

        let controller = JSONSchemaFormController()

        var body: some View {
            if let schema = try? JSONSchema(
                jsonString: """
                    {
                      "type": "object",
                      "required": ["name", "email", "age"],
                      "properties": {
                        "name": {
                          "type": "string",
                          "title": "Name",
                          "description": "Your full name (at least 3 characters)",
                          "minLength": 3
                        },
                        "email": {
                          "type": "string",
                          "title": "Email",
                          "description": "Your email address",
                          "format": "email"
                        },
                        "age": {
                          "type": "integer",
                          "title": "Age",
                          "description": "Your age (must be positive)",
                          "minimum": 0
                        }
                      }
                    }
                    """
            ) {
                NavigationStack {
                    Form {
                        Section("User Information") {
                            JSONSchemaForm(
                                schema: schema,
                                formData: $formData,
                                liveValidate: true,
                                showSubmitButton: false,
                                controller: controller
                            )
                        }

                        Section {
                            Button("Validate") {
                                controller.validate()
                            }

                            Button("Submit") {
                                Task {
                                    let success = try? await controller.submit()
                                    print("Submit result: \(success ?? false)")
                                }
                            }
                            .disabled(!controller.isValid || controller.isSubmitting)

                            Button("Clear Errors") {
                                controller.clearErrors()
                            }
                        }

                        Section("Controller State") {
                            LabeledContent("Is Valid", value: controller.isValid ? "Yes" : "No")
                            LabeledContent("Error Count", value: "\(controller.errors.count)")
                            LabeledContent("Is Submitting", value: controller.isSubmitting ? "Yes" : "No")
                        }
                    }
                    .formStyle(.grouped)
                    .navigationTitle("Field-Level Errors")
                }
            } else {
                Text("Failed to parse schema")
            }
        }
    }

    return ErrorPreviewWrapper()
}

#Preview("Form with Programmatic Controller") {
    struct ControllerPreviewWrapper: View {
        @State private var formData = FormData.object(properties: [
            "username": .string(""),
            "password": .string(""),
        ])

        let controller = JSONSchemaFormController()
        @State private var submitResult: String = ""

        var body: some View {
            if let schema = try? JSONSchema(
                jsonString: """
                    {
                      "type": "object",
                      "required": ["username", "password"],
                      "properties": {
                        "username": {
                          "type": "string",
                          "title": "Username",
                          "description": "Enter your username (min 3 chars)",
                          "minLength": 3
                        },
                        "password": {
                          "type": "string",
                          "title": "Password",
                          "description": "Enter your password (min 8 chars)",
                          "minLength": 8
                        }
                      }
                    }
                    """
            ) {
                NavigationStack {
                    Form {
                        Section("Login") {
                            JSONSchemaForm(
                                schema: schema,
                                formData: $formData,
                                liveValidate: true,
                                showSubmitButton: false,
                                controller: controller
                            )
                        }

                        Section {
                            Button("Login") {
                                Task {
                                    do {
                                        let success = try await controller.submit()
                                        submitResult = success ? "Login successful!" : "Validation failed"
                                    } catch {
                                        submitResult = "Error: \(error)"
                                    }
                                }
                            }
                            .disabled(controller.isSubmitting)

                            if !submitResult.isEmpty {
                                Text(submitResult)
                                    .foregroundColor(submitResult.contains("successful") ? .green : .red)
                            }
                        }
                    }
                    .formStyle(.grouped)
                    .navigationTitle("Programmatic Submit")
                    .onAppear {
                        controller.onValidationError = { errors in
                            print("Validation errors: \(errors.count)")
                            for error in errors {
                                print("  - \(error.description)")
                            }
                        }
                        controller.onSubmitSuccess = { data in
                            print("Form submitted with data: \(data)")
                        }
                    }
                }
            } else {
                Text("Failed to parse schema")
            }
        }
    }

    return ControllerPreviewWrapper()
}
#Preview("Form with ui:order") {
    struct UIOrderPreviewWrapper: View {
        @State private var formData = FormData.object(properties: [
            "ticker": .string("AAPL"),
            "startDate": .string("2024-01-01"),
            "endDate": .string("2024-12-31"),
            "interval": .string("1d"),
            "apiKey": .string("secret-key-123"),
        ])

        let schemaJSON = """
            {
              "type": "object",
              "required": ["ticker", "startDate", "endDate", "interval", "apiKey"],
              "properties": {
                "apiKey": {
                  "type": "string",
                  "title": "API Key",
                  "description": "Your API key for data access"
                },
                "ticker": {
                  "type": "string",
                  "title": "Ticker Symbol",
                  "description": "Stock ticker symbol (e.g., AAPL)"
                },
                "startDate": {
                  "type": "string",
                  "title": "Start Date",
                  "description": "Start date for historical data"
                },
                "endDate": {
                  "type": "string",
                  "title": "End Date",
                  "description": "End date for historical data"
                },
                "interval": {
                  "type": "string",
                  "title": "Interval",
                  "description": "Data interval (e.g., 1d, 1h, 15m)"
                }
              }
            }
            """

        // ui:order reorders fields: ticker first, dates, interval, then apiKey last
        let uiSchema: [String: Any] = [
            "apiKey": ["ui:widget": "password"],
            "ui:order": ["ticker", "startDate", "endDate", "interval", "apiKey"]
        ]

        var body: some View {
            if let schema = try? JSONSchema(jsonString: schemaJSON) {
                NavigationStack {
                    Form {
                        Section("Stock Data Query") {
                            JSONSchemaForm(
                                schema: schema,
                                uiSchema: uiSchema,
                                formData: $formData,
                                schemaJSON: schemaJSON,
                                showSubmitButton: false
                            )
                        }
                    }
                    .formStyle(.grouped)
                    .navigationTitle("ui:order Demo")
                }
            } else {
                Text("Failed to parse schema")
            }
        }
    }

    return UIOrderPreviewWrapper()
}
