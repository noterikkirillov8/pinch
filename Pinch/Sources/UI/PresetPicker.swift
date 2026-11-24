import SwiftUI

/// The five presets as rows of a settings section: a lit LED marks the one in use.
struct PresetPicker: View {
    @Binding var selection: Preset

    var body: some View {
        KitSection(title: "Default preset", footer: "Each result is the smallest file that still reaches the preset's SSIM score against the original.") {
            ForEach(Preset.allCases) { preset in
                Button { withAnimation(KitMotion.soft) { selection = preset } } label: {
                    HStack(spacing: 10) {
                        KitLed(on: selection == preset, size: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.title).font(KitFont.body).foregroundStyle(KitColor.text)
                            Text(preset.detail).font(KitFont.detail).foregroundStyle(KitColor.text2)
                        }
                        Spacer(minLength: KitSpace.m)
                        Text(preset == .lossless ? "exact" : "\(String(format: "%g", preset.ssim * 100))%")
                            .font(KitFont.number).foregroundStyle(selection == preset ? KitColor.text : KitColor.text3)
                    }
                    .padding(.horizontal, KitSpace.m).padding(.vertical, 8).frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(preset.title).accessibilityAddTraits(selection == preset ? .isSelected : [])
            }
        }
    }
}
