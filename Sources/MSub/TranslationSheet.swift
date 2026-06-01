import SwiftUI

/// Sheet for selecting target language + output mode before running a full-text translation.
struct TranslationSheet: View {
    let language: AppLanguage
    @Binding var targetLanguage: TranslationLanguageChoice
    @Binding var mode: TranslationOutputMode
    let isWholeSlot: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private func t(_ key: String) -> String { Copy.text(key, language: language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "character.bubble")
                    .font(.title3)
                    .foregroundStyle(.tint)
                Text(t("translation.title"))
                    .font(.title3.weight(.semibold))
            }

            Text(isWholeSlot ? t("translation.scope.whole") : t("translation.scope.partial"))
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text(t("translation.targetLanguage"))
                    .font(.callout.weight(.medium))
                Picker("", selection: $targetLanguage) {
                    ForEach(TranslationLanguageChoice.common) { choice in
                        Text(choice.localizedTitle).tag(choice)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(t("translation.mode"))
                    .font(.callout.weight(.medium))
                Picker("", selection: $mode) {
                    Text(t("translation.mode.replace")).tag(TranslationOutputMode.replace)
                    Text(t("translation.mode.bilingual")).tag(TranslationOutputMode.bilingual)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            Text(t("translation.helpFootnote"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(t("button.cancel"), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(t("translation.translate"), action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
