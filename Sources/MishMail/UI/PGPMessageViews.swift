import SwiftUI

/// The OpenPGP indicator in an open message's header, Gmail S/MIME style: a
/// small symbol and a few words; a click shows who signed, the fingerprint
/// and the state of each signature. Shown only for a message the engine
/// checked (`PGPCenter`), so nothing here appears with the switch off.
struct PGPIndicatorButton: View {
    let reading: PGPCenter.Reading
    /// The user asks to decrypt an encrypted part of a larger message.
    let onDecryptPart: () -> Void
    @State private var showingDetails = false

    var body: some View {
        if let summary = PGPDisplay.summary(reading.indicator) {
            Button {
                showingDetails.toggle()
            } label: {
                Label(summary.title, systemImage: summary.symbol)
                    .labelStyle(.iconOnly)
                    .font(.system(size: 12))
                    .foregroundStyle(Self.color(reading.indicator.tone))
            }
            .buttonStyle(.plain)
            .help(summary.title)
            .accessibilityLabel(summary.title)
            .accessibilityIdentifier("messagePGPIndicator")
            .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
                PGPDetailsView(reading: reading, title: summary.title, symbol: summary.symbol,
                               onDecryptPart: {
                                   showingDetails = false
                                   onDecryptPart()
                               })
            }
        }
    }

    static func color(_ tone: PGPIndicator.Tone) -> Color {
        switch tone {
        case .positive: return .green
        case .none, .neutral: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }
}

private struct PGPDetailsView: View {
    let reading: PGPCenter.Reading
    let title: String
    let symbol: String
    let onDecryptPart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(PGPIndicatorButton.color(reading.indicator.tone))
            ForEach(Array(reading.signatures.enumerated()), id: \.offset) { _, line in
                VStack(alignment: .leading, spacing: 3) {
                    Text("Signature: \(line.status.rawValue)").font(.system(size: 12, weight: .semibold))
                    ForEach(line.userIDs, id: \.self) { userID in
                        Text(userID).font(.system(size: 12))
                    }
                    if !line.userIDs.isEmpty {
                        Text("User IDs are stated by the key; nobody has verified them.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if !line.keyIdentifier.isEmpty {
                        Text(PGPDisplay.grouped(line.keyIdentifier))
                            .font(.system(size: 11).monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            if reading.indicator.showsSignedMark {
                Text("The signature covers the message body, not its subject or other headers.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if reading.indicator.render.decryptedContent == .onRequest {
                Text("Decrypted text is shown apart from the rest of the message, which anyone could have written.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Decrypt the encrypted part", action: onDecryptPart)
                    .accessibilityIdentifier("messagePGPDecryptPart")
            }
        }
        .frame(width: 340, alignment: .leading)
        .padding(14)
    }
}

/// A message that may be OpenPGP but could not be checked just now (no raw
/// message, unreadable keys): neutral, and remote content stays blocked.
struct PGPUncheckableIndicator: View {
    var body: some View {
        let text = PGPBodyNotice.cannotCheckNow.text
        Image(systemName: "questionmark.circle")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .help(text)
            .accessibilityLabel(text)
            .accessibilityIdentifier("messagePGPUncheckable")
    }
}

/// What replaces the body of an OpenPGP message: the decrypted or signed
/// text (plain text, never HTML), or a notice. A locked key asks for its
/// passphrase here; it is kept in memory for this session only.
struct PGPBodyReplacement: View {
    @Environment(MailStore.self) private var store
    let display: PGPBodyDisplay
    let accountId: String
    let fontScale: Double
    @State private var passphrase = ""

    var body: some View {
        switch display {
        case .original:
            EmptyView()
        case .text(let text):
            // Plain on purpose: decrypted or signed text is not scanned for
            // links, so nothing in it becomes something to click (or a
            // request that could carry it out).
            Text(text)
                .font(.system(size: 14.5 * fontScale))
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("messageBody")
        case .notice(let notice):
            VStack(alignment: .leading, spacing: 8) {
                Label(notice.text, systemImage: "lock")
                    .font(.system(size: 13 * fontScale))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("messagePGPNotice")
                if let detail = notice.detail {
                    Text(detail)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if notice == .passphraseRequired {
                    HStack {
                        SecureField("Passphrase", text: $passphrase)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                            .onSubmit(unlock)
                            .accessibilityIdentifier("messagePGPPassphrase")
                        Button("Decrypt", action: unlock)
                            .disabled(passphrase.isEmpty)
                    }
                    if store.openPGP.wrongPassphrase.contains(accountId) {
                        Text("That passphrase didn’t unlock your key.")
                            .font(.system(size: 11)).foregroundStyle(.red)
                    }
                    Text("Kept in memory until MishMail quits; never saved.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
        }
    }

    private func unlock() {
        guard !passphrase.isEmpty else { return }
        store.openPGP.unlock(accountId: accountId, passphrase: passphrase)
        passphrase = ""
    }
}

/// An encrypted part of a larger message, decrypted on request: shown apart,
/// as plain text, under a heading that says so.
struct PGPEncryptedPartView: View {
    let text: String
    let fontScale: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Decrypted part", systemImage: "lock.open")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 14.5 * fontScale))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .accessibilityIdentifier("messagePGPDecryptedPart")
    }
}
