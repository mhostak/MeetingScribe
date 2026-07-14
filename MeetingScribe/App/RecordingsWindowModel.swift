import Foundation

@MainActor
final class RecordingsWindowModel: ObservableObject {
    @Published var selectedDate: Date
    @Published private(set) var snapshot = SessionCatalogSnapshot.empty
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    private let calendar: Calendar
    private let catalog: SessionCatalog

    init(
        selectedDate: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        catalog: SessionCatalog = SessionCatalog()
    ) {
        self.calendar = calendar
        self.catalog = catalog
        self.selectedDate = calendar.startOfDay(for: selectedDate)
    }

    var entriesForSelectedDate: [SessionCatalogEntry] {
        snapshot.entries.filter { calendar.isDate($0.occurredAt, inSameDayAs: selectedDate) }
    }

    func previousDay() {
        selectedDate = calendar.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
    }

    func nextDay() {
        selectedDate = calendar.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
    }

    func goToToday() {
        selectedDate = calendar.startOfDay(for: Date())
    }

    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            snapshot = try await catalog.load()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}
