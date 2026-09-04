import Combine
import Foundation
import MapKit

@MainActor
final class LocationSearchCompleter: ObservableObject {
    @Published private(set) var results: [MKLocalSearchCompletion] = []

    private static let debounceInterval: Duration = .milliseconds(500)
    private var debounceTask: Task<Void, Never>?
    private var activeSession: SearchCompletionSession?
    private var activeSessionID: UUID?
    private var queryGeneration: UInt64 = 0
    private var currentQuery = ""
    private var resultsGeneration: UInt64?

    func update(query: String) {
        invalidateCurrentQuery()
        let normalized = Self.normalizedQuery(query)
        currentQuery = normalized
        guard !normalized.isEmpty else { return }

        let generation = queryGeneration
        debounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.debounceInterval)
            } catch {
                return
            }
            guard let self,
                  self.queryGeneration == generation,
                  self.currentQuery == normalized else { return }
            self.startSearch(query: normalized, generation: generation)
        }
    }

    func cancelAndClear() {
        invalidateCurrentQuery()
        currentQuery = ""
    }

    func firstResult(matching query: String) -> MKLocalSearchCompletion? {
        guard Self.normalizedQuery(query) == currentQuery,
              resultsGeneration == queryGeneration else { return nil }
        return results.first
    }

    nonisolated static func shouldAcceptResults(
        callbackGeneration: UInt64,
        currentGeneration: UInt64,
        callbackQuery: String,
        currentQuery: String,
        callbackSessionID: UUID,
        currentSessionID: UUID?
    ) -> Bool {
        callbackGeneration == currentGeneration
            && normalizedQuery(callbackQuery) == normalizedQuery(currentQuery)
            && callbackSessionID == currentSessionID
    }

    nonisolated private static func normalizedQuery(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func invalidateCurrentQuery() {
        queryGeneration &+= 1
        debounceTask?.cancel()
        debounceTask = nil
        activeSession?.cancel()
        activeSession = nil
        activeSessionID = nil
        resultsGeneration = nil
        results = []
    }

    private func startSearch(query: String, generation: UInt64) {
        activeSession?.cancel()
        let sessionID = UUID()
        let session = SearchCompletionSession(
            query: query,
            onResults: { [weak self] values in
                self?.receive(
                    values,
                    query: query,
                    generation: generation,
                    sessionID: sessionID
                )
            },
            onFailure: { [weak self] in
                self?.receive(
                    [],
                    query: query,
                    generation: generation,
                    sessionID: sessionID
                )
            }
        )
        activeSessionID = sessionID
        activeSession = session
        session.start()
    }

    private func receive(
        _ values: [MKLocalSearchCompletion],
        query: String,
        generation: UInt64,
        sessionID: UUID
    ) {
        guard Self.shouldAcceptResults(
            callbackGeneration: generation,
            currentGeneration: queryGeneration,
            callbackQuery: query,
            currentQuery: currentQuery,
            callbackSessionID: sessionID,
            currentSessionID: activeSessionID
        ) else { return }
        resultsGeneration = generation
        results = values
    }
}

@MainActor
private final class SearchCompletionSession: NSObject, @preconcurrency MKLocalSearchCompleterDelegate {
    private let query: String
    private let onResults: ([MKLocalSearchCompletion]) -> Void
    private let onFailure: () -> Void
    private let completer = MKLocalSearchCompleter()

    init(
        query: String,
        onResults: @escaping ([MKLocalSearchCompletion]) -> Void,
        onFailure: @escaping () -> Void
    ) {
        self.query = query
        self.onResults = onResults
        self.onFailure = onFailure
        super.init()
        completer.delegate = self
    }

    func start() {
        completer.queryFragment = query
    }

    func cancel() {
        completer.delegate = nil
        completer.queryFragment = ""
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        onResults(completer.results)
    }

    func completer(
        _ completer: MKLocalSearchCompleter,
        didFailWithError error: Error
    ) {
        onFailure()
    }
}
