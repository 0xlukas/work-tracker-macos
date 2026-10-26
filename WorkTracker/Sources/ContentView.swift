import SwiftUI
import SwiftData

enum NavigationItem: String, CaseIterable, Identifiable {
    case dailyEntry = "Daily Entry"
    case projects = "Projects"
    case absences = "Absences"
    case overview = "Overview"
    case calls = "Calls"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dailyEntry: return "calendar"
        case .projects: return "folder"
        case .absences: return "calendar.badge.minus"
        case .overview: return "chart.bar"
        case .calls: return "phone"
        }
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.undoManager) private var undoManager
    @Environment(Preferences.self) private var preferences
    @Environment(DeviceSync.self) private var deviceSync
    @State private var selection: NavigationItem? = .dailyEntry
    @State private var showDailyQuote = false
    @State private var showSyncQuestion = false

    /// Calls only appear when they're tracked on this Mac.
    private var sidebarItems: [NavigationItem] {
        NavigationItem.allCases.filter { $0 != .calls || preferences.callTrackingEnabled }
    }

    var body: some View {
        ZStack {
            NavigationSplitView {
                // The system sidebar extends to the window edge and takes on the
                // macOS 27 glass treatment on its own; keep it a plain List of Labels.
                List(sidebarItems, selection: $selection) { item in
                    if item == .dailyEntry {
                        // Count of past working days with nothing logged, like an unread count.
                        MissingEntriesReader(trackingStart: preferences.trackingStartDate) { missing in
                            Label(tr(item.rawValue), systemImage: item.icon)
                                .badge(missing.count)
                        }
                        .tag(item)
                    } else {
                        Label(tr(item.rawValue), systemImage: item.icon)
                            .tag(item)
                    }
                }
                .listStyle(.sidebar)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            } detail: {
                switch selection {
                case .dailyEntry:
                    DailyEntryView()
                case .projects:
                    ProjectsView()
                case .absences:
                    AbsencesView()
                case .overview:
                    OverviewView()
                case .calls:
                    CallsView()
                case nil:
                    ContentUnavailableView(tr("Select an item from the sidebar"), systemImage: "sidebar.left")
                }
            }
            .frame(minWidth: 860, minHeight: 620)
            // Not `.disabled`: disabling every control while macOS restores a tiled window
            // at launch sent SwiftUI into an endless layout loop (the app hung at 100% CPU).
            // The quote's backdrop takes the clicks, its key capture the typing.
            .allowsHitTesting(!showDailyQuote)

            if showDailyQuote {
                DailyQuoteOverlayView(quote: DailyQuote.quoteOfTheDay()) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        showDailyQuote = false
                    }
                    preferences.lastQuoteShownDate = Date()
                }
                .transition(.opacity)
            }
        }
        .onAppear {
            // Edit ▸ Undo (⌘Z) covers every change made through the shared context.
            modelContext.undoManager = undoManager
            if preferences.shouldShowDailyQuote {
                showDailyQuote = true
            }
        }
        .onChange(of: undoManager) { _, manager in
            modelContext.undoManager = manager
        }
        .onChange(of: preferences.callTrackingEnabled) { _, enabled in
            if !enabled && selection == .calls { selection = .dailyEntry }
        }
        // Sync waits for a decision; also shown in Settings ▸ Sync.
        .onChange(of: deviceSync.question, initial: true) { _, question in
            showSyncQuestion = question != nil
        }
        .alert(deviceSync.question?.title ?? "", isPresented: $showSyncQuestion, presenting: deviceSync.question) { question in
            ForEach(question.answers, id: \.label) { option in
                Button(option.label, role: option.isDestructive ? .destructive : nil) {
                    Task { await deviceSync.answer(option.answer, to: question) }
                }
            }
            Button(tr("Later"), role: .cancel) {}
        } message: { question in
            Text(question.message)
        }
    }
}
