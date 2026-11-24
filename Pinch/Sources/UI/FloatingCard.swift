import SwiftUI

struct PinchFrame: Equatable {
    var bytes: Int
    var squeezed = false

    static func step(_ index: Int, from original: Int, to result: Int) -> Self {
        Self(bytes: original + Int((Double(result) - Double(original)) * Double(index) / 10), squeezed: index > 0 && result < original)
    }
}

struct FloatingCard: View {
    let item: Item
    let store: ResultStore
    var forceHover = false
    var sample: PinchFrame?
    @AppStorage("blurOn") private var blurOn = false
    @State private var hovering = false
    @State private var more = false
    @State private var sizes = false
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.displayScale) private var scale
    private let accent = Color(hex: 0xD97757)
    private var hovered: Bool { hovering || forceHover || more || sizes }
    private var frame: PinchFrame? { sample ?? item.pinch }
    private var working: Bool { item.running || frame != nil }
    private var error: String? { if case let .failed(message) = item.state { message } else { nil } }
    private var bytes: Int { frame?.bytes ?? (working ? item.oldBytes : item.newBytes) }
    private var saving: Double { item.oldBytes > 0 ? max(0, 1 - Double(bytes) / Double(item.oldBytes)) : 0 }
    private var kind: Kind? { Kind.of(URL(fileURLWithPath: "file.\(item.ext)")) }
    private var canDrag: Bool { !working && item.state == .done && !item.isText }
    private var keys: Bool { hovered && !working && item.state == .done && !item.isText }

    var body: some View {
        VStack(spacing: 0) {
            thumbnail.padding(8)
            ZStack(alignment: .top) {
                info.opacity(keys ? 0 : 1).offset(y: keys && !reduced ? -6 : 0)
                    .allowsHitTesting(!keys).accessibilityHidden(keys)
                if keys { actions.padding(.top, 10).transition(.opacity) }
            }.padding(.horizontal, 12).padding(.top, 6).frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 300, height: 196)
        .background { RoundedRectangle(cornerRadius: 12).fill(KitColor.window).shadow(color: .black.opacity(0.4), radius: 10, y: 4) }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(KitColor.line, lineWidth: 1 / scale).allowsHitTesting(false))
        .foregroundStyle(KitColor.text).kitAccent(accent)
        .contentShape(Rectangle()).onTapGesture {
            if !working, item.state == .done || (item.source == .file && item.state == .notice("Already optimised")) { Core.shared.copyToClipboard(item) }
        }
        .dragOut(canDrag, image: item.thumb, size: MenuView.bytes(item.newBytes)) { Drag.file(for: item) }
        .onHover { inside in withAnimation(KitMotion.soft) { hovering = inside } }
        .onChange(of: hovered) { store.hover(item, hovered) }
        .onChange(of: hovering) { Compare.shared.hover(src: item.src, dest: item.dest, ssim: item.ssim, on: hovering && item.state == .done && !working && item.batch == nil) }
        .animation(KitMotion.soft, value: keys)
        .opacity(item.inRemoval ? 0 : 1).offset(y: item.inRemoval && !reduced ? 8 : 0)
        .allowsHitTesting(!item.inRemoval)
    }

    private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        return ZStack {
            KitColor.well
            if let thumb = item.thumb {
                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: error != nil ? "doc.badge.ellipsis" : item.isText ? "text.alignleft" : item.batch != nil ? "square.stack" : "doc").font(.system(size: 24)).foregroundStyle(KitColor.text3)
            }
        }.frame(width: 284, height: 108).clipShape(shape)
        .overlay(shape.strokeBorder(KitColor.line, lineWidth: 1 / scale))
        .overlay(alignment: .topLeading) {
            HStack(spacing: 4) {
                if let batch = item.batch { chip("\(batch.total) files", accent) }
                else {
                    chip(item.ext.isEmpty ? "PINCH" : item.ext.uppercased(), accent)
                    if !item.isText, kind != nil { chip(item.opts.effective.chip, KitColor.text2) }
                }
            }.padding(6)
        }
        .overlay(alignment: .topTrailing) {
            if hovered {
                KitIconButton(symbol: "xmark", help: "Close result") { store.remove(item) }
                    .background(KitColor.window, in: RoundedRectangle(cornerRadius: 5)).padding(5)
            } else {
                let lamp = KitLed(color: error != nil ? KitColor.red : working ? KitColor.amber : accent, size: 9)
                    .padding(3).background(KitColor.window, in: Circle()).padding(7)
                Group {
                    if working && !reduced { lamp.phaseAnimator([false, true]) { view, dim in view.opacity(dim ? 0.45 : 1) } animation: { _ in .easeInOut(duration: 0.6) } }
                    else { lamp }
                }
                    .keyframeAnimator(initialValue: 1.0, trigger: working) { view, value in view.opacity(reduced || working ? 1 : value) } keyframes: { _ in
                        LinearKeyframe(0.45, duration: 0.06); LinearKeyframe(1, duration: 0.12)
                    }
                    .accessibilityLabel(error != nil ? "Failed" : working ? "Optimising" : "Finished")
            }
        }
        .overlay(alignment: .bottomLeading) {
            if blurOn && item.hidden > 0 {
                HStack(spacing: 4) {
                    chip("\(item.hidden) hidden", KitColor.amber)
                    if hovered && !working { Button("Show") { Core.shared.showHidden(item) }.buttonStyle(.kitSecondary).background(KitColor.window, in: RoundedRectangle(cornerRadius: 5)) }
                }.padding(6)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if kind == .video { Image(systemName: "play.fill").font(.system(size: 9)).padding(7).background(KitColor.window, in: RoundedRectangle(cornerRadius: 4)).padding(6) }
        }
        .scaleEffect(!reduced && working && bytes < item.oldBytes ? 0.97 : 1)
        .animation(KitMotion.snap, value: working && bytes < item.oldBytes)
    }

    private func chip(_ label: String, _ color: Color) -> some View {
        KitBadge(text: label, color: color).padding(.horizontal, 8).padding(.vertical, 4).background(KitColor.window, in: Capsule())
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error {
                HStack { Text(error).font(KitFont.bodyMedium).lineLimit(2); Spacer(); Button("Reveal", action: reveal).buttonStyle(.kitSecondary) }
            } else if case let .notice(message) = item.state {
                Text(message).font(KitFont.title)
            } else if item.isText {
                Text("Copied \(item.textLines) lines").font(KitFont.title)
            } else if let batch = item.batch, item.running {
                HStack(spacing: 6) {
                    Text("\(batch.done) of \(batch.total)").font(KitFont.figure(26, .semibold)).kitRollingNumber(batch.done)
                    Spacer(minLength: 0)
                    Text(MenuView.bytes(max(0, item.oldBytes - item.newBytes))).font(KitFont.detail).foregroundStyle(KitColor.text2)
                }.lineLimit(1)
                KitProgress(value: Double(batch.done) / Double(max(1, batch.total)))
            } else {
                HStack(spacing: 6) {
                    Text(MenuView.bytes(bytes)).font(KitFont.figure(26, .semibold)).kitRollingNumber(bytes)
                        .scaleEffect(x: frame?.squeezed == true && !reduced ? 0.82 : 1, y: 1, anchor: .leading)
                        .animation(KitMotion.snap, value: frame?.squeezed)
                    Text("from \(MenuView.bytes(item.oldBytes))").font(KitFont.detail).foregroundStyle(KitColor.text2)
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 4) {
                        let percent = Int((saving * 100).rounded())
                        Text("\(-percent)%").font(KitFont.figure(15)).kitRollingNumber(percent)
                        KitMeter(value: saving, segments: 12, warn: nil, danger: nil)
                    }.frame(width: 64, alignment: .trailing)
                }.lineLimit(1).minimumScaleFactor(0.8)
            }
            HStack(spacing: 8) {
                Text(item.overlay ?? (item.isText ? item.textPreview : item.batch != nil ? (item.running ? "Optimising with \(item.opts.effective.title.lowercased())" : "Saved \(MenuView.bytes(max(0, item.oldBytes - item.newBytes))) in total") : item.dest?.lastPathComponent ?? item.name))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if let ssim = item.ssim, item.overlay == nil, !working { Text(String(format: "%.1f%% identical", ssim * 100)).monospacedDigit().layoutPriority(1) }
            }.font(KitFont.detail).foregroundStyle(KitColor.text2)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reveal() { if let url = item.dest { NSWorkspace.shared.activateFileViewerSelecting([url]) } }

    private var actions: some View {
        HStack {
            // Native menus, not popovers: popovers draw a blurred material (banned in the family style).
            menuKey("arrow.down.right.and.arrow.up.left", "Downscale", open: $sizes) {
                ForEach([75, 50, 25], id: \.self) { percent in
                    Button("\(percent)%") { Core.shared.downscale(item, Double(percent) / 100) }
                }
            }.disabled(kind == .pdf)
            key("rectangle.compress.vertical", "AI size") { Core.shared.aiSize(item) }.disabled(kind?.isImage != true)
            key("text.viewfinder", "Copy text") { Core.shared.copyText(from: item) }.disabled(kind?.isImage != true)
            key("arrow.uturn.backward", "Restore original") { Core.shared.restore(item) }
            key("folder", "Reveal", reveal)
            menuKey("ellipsis", "More", open: $more) {
                Menu("Preset") {
                    ForEach(Preset.allCases) { preset in
                        Button { Core.shared.setPreset(item, preset) } label: {
                            if item.opts.preset == preset { Label(preset.title, systemImage: "checkmark") } else { Text(preset.title) }
                        }
                    }
                }
                Button("Optimise harder") { Core.shared.aggressive(item) }
                if kind == .gif { Button("Convert to MP4") { Core.shared.convertGIF(item) } }
                Button("Copy result") { Core.shared.copyToClipboard(item) }
            }
        }
    }

    /// A key that opens a native menu. `open` stays true while the menu is up so the card keeps its hover state.
    private func menuKey<Items: View>(_ symbol: String, _ title: String, open: Binding<Bool>, @ViewBuilder items: () -> Items) -> some View {
        Menu { items() } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(KitColor.text2)
                .frame(width: 26, height: 26)
                .overlay(RoundedRectangle(cornerRadius: KitSpace.controlRadius).strokeBorder(KitColor.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(title).accessibilityLabel(title)
        .frame(maxWidth: .infinity)
    }

    private func key(_ symbol: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        KitIconButton(symbol: symbol, help: title, outlined: true, action: action).frame(maxWidth: .infinity)
    }
}

struct FloatingStack: View {
    var store: ResultStore
    var onSize: (CGSize) -> Void = { _ in }
    var forceHover: Set<UUID> = []
    @Environment(\.accessibilityReduceMotion) private var reduced

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(store.items.reversed()) { item in
                let newest = store.items.first?.id == item.id
                FloatingCard(item: item, store: store, forceHover: forceHover.contains(item.id))
                    .scaleEffect(newest ? 1 : 0.97, anchor: .trailing)
                    .frame(height: newest ? 196 : 196 * 0.97)
                    .opacity(newest ? 1 : 0.85)
                    .transition(.asymmetric(insertion: reduced ? .opacity : .opacity.combined(with: .offset(x: 24)), removal: .identity))
            }
        }.padding(12).fixedSize().onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
}
