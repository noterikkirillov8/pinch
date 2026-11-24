import AppKit
import SwiftUI

@MainActor @Observable final class PanelPresentation {
    var shown = false
}

struct PresentedContent<Content: View>: View {
    let state: PanelPresentation
    var anchor: UnitPoint = .top
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        if reduced { content().transaction { $0.disablesAnimations = true; $0.animation = nil }.opacity(state.shown ? 1 : 0).animation(KitMotion.soft, value: state.shown) }
        else { content().kitPanelEntrance(state.shown, anchor: anchor) }
    }
}

enum TourScene: Int, CaseIterable {
    case capture, resize, privacy, text, rename
    var title: String { ["A smaller screenshot", "Sized for an AI chat", "Private details stay hidden", "Copy the words, not the image", "A name you can find later"][rawValue] }
    var detail: String { ["Pinch keeps the original and shows you how much space you saved.", "Only the clipboard copy shrinks. Your saved screenshot stays full size.", "Email addresses and tokens are blurred on this Mac.", "Press Control–Option–T to copy recognised text to the clipboard.", "Screenshots are named after the app and the time. macOS may ask once to read your screenshot folder."][rawValue] }
}

private struct SampleDocument: View {
    var hiddenLines: Int
    private func height(_ index: Int) -> CGFloat {
        let wave = abs((index * 9) % 31 - 14)
        return CGFloat(14 + wave * 2 + index / 2)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("FIELD OFFICE     /     EDITION 04").font(.system(size: 9, weight: .bold, design: .monospaced))
            Rectangle().frame(height: 1)
            Text("Coastal survey").font(.system(size: 30, weight: .semibold, design: .serif))
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(0..<28) { index in
                    Rectangle().fill(index < 19 ? Color(hex: 0x406961) : Color(hex: 0xB6885D))
                        .frame(height: height(index))
                }
            }.frame(height: 52, alignment: .bottom)
            ForEach(["To     atlas@example.test", "Key    demo-4186-coast"], id: \.self) { line in
                HStack(spacing: 5) {
                    Text(String(line.prefix(3))).frame(width: 24, alignment: .leading)
                    if hiddenLines == 2 || (hiddenLines == 1 && line.hasPrefix("To")) {
                        HStack(spacing: 0) { ForEach(0..<19) { index in Color(white: 0.38 + Double(index * 7 % 11) / 35).frame(width: 6) } }.frame(height: 9)
                    } else { Text(String(line.dropFirst(7))) }
                }.font(.system(size: 10, design: .monospaced))
            }
        }.padding(18).frame(width: 250, height: 190).foregroundStyle(Color(hex: 0x263B35)).background(Color(hex: 0xE8E0C9))
    }
}

@MainActor final class IntroDemo {
    static func item(_ name: String, _ ext: String, _ thumb: CGImage, old: Int, new: Int, from: CGSize, to: CGSize? = nil, clipboard: Bool = false, state: Item.State = .done) -> Item {
        let item = Item(name: name, ext: ext, source: clipboard ? .clipboard : .file)
        item.thumb = NSImage(cgImage: thumb, size: NSSize(width: thumb.width / 2, height: thumb.height / 2))
        item.oldBytes = old; item.newBytes = new; item.oldSize = from; item.newSize = to ?? from
        item.state = state; item.dest = URL(fileURLWithPath: "/demo/\(name).\(ext)")
        return item
    }
    let image: CGImage
    lazy var privateImage = Self.draw(2)
    lazy var partial = privacyItem(Self.draw(1), hidden: 1)
    lazy var redacted = privacyItem(privateImage, hidden: 2)
    let landing: Item, shot: Item, copied: Item
    let store = ResultStore()
    let mark = PinchApp.mark()
    let receipt: Receipt
    private static func draw(_ count: Int) -> CGImage {
        let renderer = ImageRenderer(content: SampleDocument(hiddenLines: count)); renderer.scale = 2
        return renderer.cgImage!
    }
    private func privacyItem(_ image: CGImage, hidden: Int) -> Item {
        let item = Self.item(shot.name, shot.ext, image, old: shot.oldBytes, new: shot.newBytes, from: shot.oldSize ?? .zero)
        item.hidden = hidden
        return item
    }
    init() {
        image = Self.draw(0)
        let size = CGSize(width: 3024, height: 1964)
        landing = Self.item("Coastal survey", "png", image, old: 2_400_000, new: 0, from: size, state: .running("Optimising"))
        shot = Self.item("Coastal survey", "png", image, old: 2_400_000, new: 610_000, from: size)
        copied = Item(name: "Text", ext: "txt", source: .clipboard); copied.state = .done; copied.textLines = 3; copied.textPreview = "Coastal survey · Field office"
        let url = URL(fileURLWithPath: "/demo/Safari 2026-11-20 at 14.03.21.png")
        receipt = Receipt(id: UUID(), date: .now, name: url.lastPathComponent, before: 2_400_000, after: 610_000, output: url, original: url)
    }
}

private struct TourCursor: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 1, y: 1))
            for point in [(2,22),(7,16),(12,25),(16,23),(11,14),(20,13)] { path.addLine(to: CGPoint(x: point.0, y: point.1)) }
            path.closeSubpath()
        }
    }
}

private struct TourStage: View {
    let demo: IntroDemo, scene: TourScene, progress: Double
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.displayScale) private var scale
    private var finished: Bool { progress >= 0.68 }
    private var fraction: Double { min(1, max(0, (progress - 0.12) / 0.65)) }
    private var pixels: Int { 3024 - Int(fraction * 1456) }
    private var card: Item {
        if progress < 1.0 / 3 { return demo.shot }
        return progress < 2.0 / 3 ? demo.partial : demo.redacted
    }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(KitColor.well)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Group {
                    switch scene {
                    case .capture:
                        let step = Int(fraction * 10)
                        let sampled = PinchFrame(bytes: PinchFrame.step(step, from: demo.shot.oldBytes, to: demo.shot.newBytes).bytes,
                                                 squeezed: step > 0 && (fraction * 10).truncatingRemainder(dividingBy: 1) < 0.85)
                        FloatingCard(item: fraction < 1 ? demo.landing : demo.shot, store: demo.store, sample: fraction < 1 ? sampled : nil)
                    case .privacy:
                        HStack(spacing: 14) {
                            FloatingCard(item: card, store: demo.store)
                                .offset(y: reduced ? 0 : 8 * (1 - fraction))
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Matched regions").font(KitFont.detail).foregroundStyle(KitColor.text2)
                                let value = min(2, Int(progress * 3))
                                Text("\(value) hidden").font(KitFont.figure(24)).kitRollingNumber(value)
                                KitMeter(value: fraction, segments: 22, warn: nil, danger: nil)
                                Text("Email and access token").font(KitFont.detail).foregroundStyle(KitColor.text2)
                            }.frame(width: 178, alignment: .leading)
                        }
                    case .resize:
                        HStack(spacing: 24) {
                            Image(decorative: demo.image, scale: 2).resizable().aspectRatio(contentMode: .fit).frame(width: 165).scaleEffect(reduced ? 1 : 1 - fraction * 0.21)
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Long side").font(KitFont.detail).foregroundStyle(KitColor.text2)
                                Text("\(pixels) px").font(KitFont.figure(25)).kitRollingNumber(pixels)
                                KitMeter(value: Double(pixels) / 3024, warn: nil, danger: nil)
                                KitToggleRow(title: "AI size", isOn: .constant(progress >= 0.25))
                            }.frame(width: 180)
                        }
                    case .text:
                        VStack(spacing: 18) {
                            KitKeycaps(keys: "⌃⌥T")
                            if progress < 0.42 { FloatingCard(item: demo.shot, store: demo.store) }
                            else { FloatingCard(item: demo.copied, store: demo.store).transition(reduced ? .opacity : .kitBar) }
                        }
                    case .rename:
                        VStack(alignment: .leading, spacing: 14) {
                            HStack { Image(nsImage: demo.mark).renderingMode(.template).scaleEffect(reduced ? 1 : 0.85 + 0.15 * fraction); Text("Pinch").font(KitFont.title); Spacer(); KitBadge(text: "Watching") }
                            KitDivider()
                            if progress >= 0.30 {
                                ReceiptRow(row: demo.receipt, thumbnail: demo.image, highlighted: finished) { _ in }.transition(reduced ? .opacity : .kitRow)
                            } else { Text("Screenshot.png").font(KitFont.body).frame(height: 52).padding(.leading, 16) }
                            KitDivider()
                            HStack { Text("Optimise clipboard").font(KitFont.detail); Spacer(); KitKeycaps(keys: "⌃⇧O") }
                        }.padding(16).frame(width: 510).background(KitColor.window, in: RoundedRectangle(cornerRadius: 8))
                    }
                }.allowsHitTesting(false).accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            let cursor = TourCursor()
            cursor.fill(KitColor.text).overlay(cursor.stroke(KitColor.window, lineWidth: 1 / scale)).frame(width: 22, height: 26)
                .offset(x: reduced ? 108 : 172 - 66 * fraction, y: reduced ? 36 : 72 - 42 * fraction)
                .opacity(progress > 0.88 ? 0 : 1).allowsHitTesting(false).accessibilityHidden(true)
        }.foregroundStyle(KitColor.text).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(KitColor.line, lineWidth: 1 / scale))
    }
}

/// One clock: an IntroFlow plus a single 30 Hz timer that sets the scene and its 0...1 progress.
@MainActor @Observable final class IntroModel {
    static let sceneSeconds = 4.0
    var scene: TourScene
    var progress: Double
    @ObservationIgnored var flow = IntroFlow(durations: Array(repeating: IntroModel.sceneSeconds, count: TourScene.allCases.count))
    @ObservationIgnored var onClose: () -> Void = {}
    @ObservationIgnored private var timer: Timer?

    /// A fixed frame (QA) or the start state.
    init(scene: TourScene = .capture, progress: Double = 0) { self.scene = scene; self.progress = progress }

    func start() {
        flow = IntroFlow(durations: flow.durations, now: CACurrentMediaTime())
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    func stop() { timer?.invalidate(); timer = nil }

    func tick() {
        let now = CACurrentMediaTime()
        flow.tick(now: now)
        sync()
        if !flow.closed { progress = min(1, flow.time(now: now) / Self.sceneSeconds) }
    }
    func next() { flow.next(now: CACurrentMediaTime()); sync() }
    func back() { flow.back(now: CACurrentMediaTime()); sync(backwards: true) }
    /// Skip, Get started, Esc and the window closing.
    func finish() { flow.close(); sync() }

    private func sync(backwards: Bool = false) {
        if flow.closed { stop(); onClose(); return }
        if flow.scene == TourScene.privacy.rawValue && !Prefs.blurOn {
            if backwards { flow.back(now: CACurrentMediaTime()) } else { flow.next(now: CACurrentMediaTime()) }
        }
        guard flow.scene != scene.rawValue, let next = TourScene(rawValue: flow.scene) else { return }
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? KitMotion.soft : KitMotion.list) { scene = next; progress = 0 }
    }
}

struct IntroView: View {
    let demo: IntroDemo
    let model: IntroModel
    @AppStorage("blurOn") private var blurOn = false
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.displayScale) private var scale
    var body: some View {
        let scenes = TourScene.allCases.filter { blurOn || $0 != .privacy }
        let scene = !blurOn && model.scene == .privacy ? TourScene.text : model.scene
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                TourStage(demo: demo, scene: scene, progress: model.progress).id(scene)
                    .transition(reduced ? .opacity : .asymmetric(insertion: .offset(x: 24).combined(with: .opacity), removal: .offset(x: -24).combined(with: .opacity)))
            }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            Text(scene.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(KitColor.text)
            Text(scene.detail).font(KitFont.body).foregroundStyle(KitColor.text2)
            HStack {
                Button("Skip") { model.finish() }.buttonStyle(.kitQuiet).focusable(false)
                Spacer()
                Button(scene == .rename ? "Get started" : "Next") { model.next() }.buttonStyle(KitButtonStyle(kind: scene == .rename ? .primary : .secondary)).focusable(false)
            }.overlay { HStack(spacing: 7) { ForEach(scenes, id: \.self) { KitLed(on: scene == $0) } }.accessibilityLabel("Step \((scenes.firstIndex(of: scene) ?? 0) + 1) of \(scenes.count)") }
        }.padding(20).frame(width: 640, height: 440).background(KitColor.window, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(KitColor.line, lineWidth: 1 / scale)).kitAccent(Color(hex: 0xD97757))
    }
}

@MainActor final class IntroController {
    static let shared = IntroController()
    static let seenKey = "introPresented.v2"
    private let presenter = IntroPresenter()
    private var model: IntroModel?
    var isShowing: Bool { presenter.isShowing }

    func show() {
        UserDefaults.standard.set(true, forKey: Self.seenKey)    // seen as soon as it is shown: a failed intro never repeats
        if presenter.isShowing { presenter.focus(); return }
        let m = IntroModel()
        model = m
        m.onClose = { [weak self] in self?.presenter.close() }
        presenter.onClose = { [weak m] in m?.finish() }
        presenter.onNext = { [weak m] in m?.next() }
        presenter.onBack = { [weak m] in m?.back() }
        presenter.show(IntroView(demo: IntroDemo(), model: m), size: CGSize(width: 640, height: 440))
        m.start()
    }
}
