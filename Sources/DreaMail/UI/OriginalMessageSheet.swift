import SwiftUI
import AppKit

/// "Show original" from a message's "More" menu: the message exactly as
/// Gmail holds it, as Gmail on the web shows it, with "Download original"
/// and "Copy to clipboard". Held in memory while the sheet is open, never
/// stored or logged.
struct OriginalMessageSheet: View {
    @Environment(MailStore.self) var store
    @Environment(\.dismiss) private var dismiss
    let message: Message

    private enum LoadState {
        case loading
        case loaded(String)
        case failed(String)
    }

    @State private var state: LoadState = .loading

    /// Longest text shown: a message with large attachments is megabytes of
    /// base64, which a text view lays out slowly. "Download original" and
    /// "Copy to clipboard" always take all of it.
    static let shownCharacterLimit = 262_144

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Original message")
                .font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                row("Message ID", message.messageIdHeader)
                row("Created at", message.date.formatted(date: .complete, time: .shortened))
                row("From", message.fromHeader)
                if !message.toHeader.isEmpty { row("To", message.toHeader) }
                row("Subject", message.subject)
            }
            .font(.system(size: 12))
            Divider()
            content
            HStack {
                Button("Download original") { store.downloadMessage(message) }
                Button("Copy to clipboard") {
                    if case .loaded(let raw) = state {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(raw, forType: .string)
                    }
                }
                .disabled(!isLoaded)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 760, minHeight: 480, idealHeight: 620)
        .task(id: message.id) { await load() }
    }

    private var isLoaded: Bool {
        if case .loaded = state { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let raw):
            VStack(alignment: .leading, spacing: 6) {
                if raw.count > Self.shownCharacterLimit {
                    Text("Showing the beginning of the message. Download original for all of it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ScrollView {
                    Text(String(raw.prefix(Self.shownCharacterLimit)))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("originalMessageText")
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value).textSelection(.enabled).lineLimit(2)
        }
    }

    private func load() async {
        state = .loading
        do {
            let data = try await store.originalMessage(message)
            guard !Task.isCancelled else { return }
            state = .loaded(String(decoding: data, as: UTF8.self))
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed("Couldn't load the original: \(error.localizedDescription)")
        }
    }
}
