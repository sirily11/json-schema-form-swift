import JSONSchema
import SwiftUI

// MARK: - Foreign Key Types

/// One selectable record returned by the app's search client.
public struct ForeignKeyItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?
    /// Full record payload, for transforms that store the whole object
    /// rather than just the id.
    public let raw: FormData?

    public init(id: String, title: String, subtitle: String? = nil, raw: FormData? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.raw = raw
    }
}

/// One page of search results with an opaque cursor for the next page.
public struct ForeignKeyPage: Sendable {
    public let items: [ForeignKeyItem]
    public let nextCursor: String?

    public init(items: [ForeignKeyItem], nextCursor: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// Implemented by the host app. The library never talks to the network
/// itself — the client owns URL construction, authentication, and response
/// parsing, so requests carry the app's credentials.
@MainActor
public protocol ForeignKeySearchClient: AnyObject, Sendable {
    /// Fetch one page of records for `endpoint` (the opaque token from the
    /// field's `ui:options.endpoint`), optionally filtered by `query` and
    /// starting at `cursor`.
    func search(endpoint: String, query: String?, cursor: String?) async throws -> ForeignKeyPage

    /// Resolve an already-stored id to a display item so the field row can
    /// show a human-readable title. Optional — the default returns nil and
    /// the raw id is shown instead.
    func resolve(endpoint: String, id: String) async throws -> ForeignKeyItem?
}

public extension ForeignKeySearchClient {
    func resolve(endpoint: String, id: String) async throws -> ForeignKeyItem? { nil }
}

/// Field context handed to the transform so a single closure can vary its
/// behavior per field.
public struct ForeignKeyFieldContext {
    public let id: String
    public let propertyName: String?
    public let endpoint: String
    public let schema: JSONSchema
    public let uiOptions: [String: Any]?
}

public typealias ForeignKeyTransform =
    @MainActor @Sendable (ForeignKeyItem, ForeignKeyFieldContext) -> FormData
public typealias ForeignKeyStoredID = @MainActor @Sendable (FormData) -> String?

/// Configuration for fields marked `ui:widget: "foreign-key"`. Pass it to
/// `JSONSchemaForm(foreignKey:)`; without it those fields fall back to a
/// plain string input.
public struct ForeignKeyConfiguration: Sendable {
    /// App-owned client performing (authenticated) search requests.
    public let client: any ForeignKeySearchClient
    /// Converts a picked item into the stored FormData. Some APIs store just
    /// the id, others the full object. Default stores `.string(item.id)`.
    public let transform: ForeignKeyTransform
    /// Extracts the stored id back out of FormData, used to resolve the
    /// current selection's title and to highlight it in the picker. Default
    /// unwraps `.string`; apps that store full objects supply their own.
    public let storedID: ForeignKeyStoredID

    public init(
        client: any ForeignKeySearchClient,
        transform: @escaping ForeignKeyTransform = { item, _ in .string(item.id) },
        storedID: @escaping ForeignKeyStoredID = { value in
            if case .string(let id) = value, !id.isEmpty { return id }
            return nil
        }
    ) {
        self.client = client
        self.transform = transform
        self.storedID = storedID
    }
}

