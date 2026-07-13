import Foundation
import Observation

/// Search + cursor-pagination state for the foreign-key picker page.
///
/// A monotonically increasing generation counter guards against stale
/// responses: any load that started before the latest reset (new search,
/// pull-to-refresh) is dropped when it lands.
@MainActor
@Observable
final class ForeignKeyPickerModel {
    let client: any ForeignKeySearchClient
    let endpoint: String
    let searchable: Bool

    var items: [ForeignKeyItem] = []
    var query = ""
    var nextCursor: String?
    var isLoading = false
    /// True once the first page request has completed (successfully or not),
    /// so the view can distinguish "loading" from "genuinely empty".
    var hasLoaded = false
    var errorMessage: String?
    private var requestGeneration = 0

    init(client: any ForeignKeySearchClient, endpoint: String, searchable: Bool) {
        self.client = client
        self.endpoint = endpoint
        self.searchable = searchable
    }

    func load(reset: Bool = true) async {
        let requestedCursor: String?
        if reset {
            requestGeneration &+= 1
            requestedCursor = nil
        } else {
            guard !isLoading, let nextCursor else { return }
            requestedCursor = nextCursor
        }

        let generation = requestGeneration
        let requestedQuery = effectiveQuery
        isLoading = true
        defer {
            if generation == requestGeneration {
                isLoading = false
            }
        }

        do {
            let page = try await client.search(
                endpoint: endpoint, query: requestedQuery, cursor: requestedCursor
            )
            guard !Task.isCancelled,
                  generation == requestGeneration,
                  requestedQuery == effectiveQuery
            else { return }
            items = reset ? page.items : items + page.items
            nextCursor = page.nextCursor
            errorMessage = nil
            hasLoaded = true
        } catch is CancellationError {
            return
        } catch {
            guard generation == requestGeneration, requestedQuery == effectiveQuery else { return }
            errorMessage = error.localizedDescription
            hasLoaded = true
        }
    }

    /// Triggers the next page load when `item` is the last loaded row.
    func loadNextIfNeeded(item: ForeignKeyItem) async {
        guard item.id == items.last?.id, nextCursor != nil else { return }
        await load(reset: false)
    }

    private var effectiveQuery: String? {
        guard searchable else { return nil }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
