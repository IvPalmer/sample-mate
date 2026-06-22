// The live waveform strip with two display modes (engine.displayMode):
//
//  • Scroll — a moving left-to-right timeline. New audio enters at the right; once the
//    viewport fills it right-anchors and scrolls. History stays to the left: scroll back
//    to grab anything still in the rolling buffer. No overwrite.
//
//  • Loop — a static fixed-size oscilloscope (like the original). The write-head sweeps
//    left→right and overwrites in place when it wraps; the display itself never moves.
//
// "Skip silence" (engine.skipSilence, applied in CaptureSink) is orthogonal: when on,
// the frontier/sweep only advances while there's real sound, so the view freezes during
// silence and idle redraws stop.
//
// Left-drag selects a region (global frame timeline); dragging out of a selection exports
// a WAV and starts a native file drag (Finder / Ableton). Ctrl+Click pauses. In Scroll
// mode, the scroll wheel pans back through history.

import SwiftUI
import AppKit

// MARK: - SwiftUI bridge

struct WaveformStrip: NSViewRepresentable {
    var engine: CaptureEngine

    func makeNSView(context: Context) -> WaveformView {
        let view = WaveformView()
        view.engine = engine
        view.startRenderTimer()
        return view
    }
    func updateNSView(_ view: WaveformView, context: Context) {
        view.engine = engine
        view.needsDisplay = true   // reflect mode / setting changes immediately
    }
    static func dismantleNSView(_ view: WaveformView, coordinator: ()) { view.stopRenderTimer() }
}

// MARK: - NSView

final class WaveformView: NSView {

    var engine: CaptureEngine?

    /// Scroll mode: pixels per second of captured audio (fixed, so drawn content never
    /// rescales as new audio arrives).
    private let pixelsPerSecond: Double = 40

    // View state
    private var paused = false
    private var frozenWriteFrame = 0
    private var followLive = true          // scroll mode only
    private var viewLeftFrame = 0          // scroll mode only
    private var selection: (start: Int, end: Int)?

    // Interaction
    private var selecting = false
    private var selectionAnchor = 0
    private var pendingDragOut = false
    private var dragStartPoint: NSPoint = .zero
    /// Frozen write frame for the duration of a mouse interaction → both mappings hold still.
    private var interactionRefFrame: Int?

    private var seenEpochID = -1
    private var lastTimerWriteFrame = -1
    private var renderTimer: Timer?

    private static let rainbowColors: [CGColor] = (0..<96).map { i in
        let t = Double(i) / 95.0
        let hue = 0.92 - t * 0.90
        return NSColor(calibratedHue: CGFloat(hue), saturation: 0.7, brightness: 0.98, alpha: 1).cgColor
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Render loop (redraw only when the frontier advanced → idle/silence = 0 redraws)

    func startRenderTimer() {
        stopRenderTimer()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, let engine = self.engine, engine.isCapturing, !self.paused else { return }
            let wf = engine.currentWriteFrame
            if wf != self.lastTimerWriteFrame {
                self.lastTimerWriteFrame = wf
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        renderTimer = timer
    }
    func stopRenderTimer() { renderTimer?.invalidate(); renderTimer = nil }
    deinit { renderTimer?.invalidate() }

    // MARK: Shared

    private func refWriteFrame(_ e: CaptureEngine) -> Int {
        if let f = interactionRefFrame { return f }
        return paused ? frozenWriteFrame : e.currentWriteFrame
    }
    private func capacityFrames(_ e: CaptureEngine) -> Int { max(1, Int(e.bufferSeconds * e.sampleRate)) }

    private func frameAtX(_ x: Double, _ e: CaptureEngine) -> Int {
        if e.displayMode == .loop, let peaks = e.peaks { return loopMap(e, peaks).frameForX(x) }
        return leftFrame(e) + Int(x * fpp(e))
    }
    private func xAtFrame(_ frame: Int, _ e: CaptureEngine) -> Double {
        if e.displayMode == .loop, let peaks = e.peaks { return loopMap(e, peaks).xForFrame(frame) }
        return Double(frame - leftFrame(e)) / fpp(e)
    }
    private func selectableFrame(_ x: Double, _ e: CaptureEngine) -> Int {
        let refWrite = refWriteFrame(e)
        let contentStart = max(0, refWrite - capacityFrames(e))
        return min(max(frameAtX(x, e), contentStart), refWrite)
    }

    // MARK: Scroll mapping

    private func fpp(_ e: CaptureEngine) -> Double { e.sampleRate / pixelsPerSecond }
    private func leftFrame(_ e: CaptureEngine) -> Int {
        let viewFrames = Int(Double(bounds.width) * fpp(e))
        let refWrite = refWriteFrame(e)
        let contentStart = max(0, refWrite - capacityFrames(e))
        let liveLeft = max(contentStart, refWrite - viewFrames)   // fills left→right, then scrolls
        if followLive { return liveLeft }
        return min(max(viewLeftFrame, contentStart), liveLeft)
    }

    // MARK: Loop (oscilloscope) mapping

    private struct LoopMap {
        let binSize, bufferBins, currentBin, passBase, writePhase: Int
        let width: Double
        func absBin(_ phase: Int) -> Int { var b = passBase + phase; if b >= currentBin { b -= bufferBins }; return b }
        func phase(forBin bin: Int) -> Int { ((bin - passBase) % bufferBins + bufferBins) % bufferBins }
        func frameForX(_ x: Double) -> Int {
            let p = min(bufferBins - 1, max(0, Int(x / width * Double(bufferBins))))
            return max(0, absBin(p)) * binSize
        }
        func xForFrame(_ frame: Int) -> Double {
            let bin = frame / binSize
            let frac = Double(frame % binSize) / Double(binSize)
            return (Double(phase(forBin: bin)) + frac) / Double(bufferBins) * width
        }
        var headX: Double { Double(writePhase) / Double(bufferBins) * width }
    }
    private func loopMap(_ e: CaptureEngine, _ peaks: PeakRing) -> LoopMap {
        let binSize = peaks.binSize
        let bufferBins = max(1, peaks.retainedBins)
        let currentBin = max(0, refWriteFrame(e) / binSize)
        return LoopMap(binSize: binSize, bufferBins: bufferBins, currentBin: currentBin,
                       passBase: currentBin - (currentBin % bufferBins),
                       writePhase: currentBin % bufferBins, width: Double(max(1, Int(bounds.width))))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor(white: 0.07, alpha: 1).cgColor)
        ctx.fill(bounds)

        if let engine, engine.epochID != seenEpochID {
            seenEpochID = engine.epochID
            selection = nil; selecting = false; pendingDragOut = false
            interactionRefFrame = nil; paused = false; followLive = true; viewLeftFrame = 0
        }

        guard let engine, engine.isCapturing, let peaks = engine.peaks, bounds.width > 1 else {
            drawPlaceholder(); return
        }

        if engine.displayMode == .loop {
            drawLoop(ctx, engine, peaks)
        } else {
            drawScroll(ctx, engine, peaks)
        }

        if paused { drawBadge("PAUSED") }
        else if engine.displayMode == .scroll && !followLive { drawBadge("◂ SCROLLED BACK") }
    }

    private func drawScroll(_ ctx: CGContext, _ engine: CaptureEngine, _ peaks: PeakRing) {
        let f = fpp(engine)
        let left = leftFrame(engine)
        let binSize = peaks.binSize
        let w = Int(bounds.width)

        let paths = makeBucketPaths()
        var x = 0
        while x < w {
            let f0 = left + Int(Double(x) * f)
            let f1 = left + Int(Double(x + 1) * f)
            if f0 >= 0, let env = peaks.envelope(fromBin: f0 / binSize, toBin: max(f0 / binSize + 1, f1 / binSize + 1)) {
                addBar(env, atX: x, width: w, into: paths)
            }
            x += 1
        }
        fillBuckets(ctx, paths)
        drawSelectionLinear(ctx, engine)

        let hx = xAtFrame(refWriteFrame(engine), engine)
        drawHead(ctx, x: hx)
    }

    private func drawLoop(_ ctx: CGContext, _ engine: CaptureEngine, _ peaks: PeakRing) {
        let map = loopMap(engine, peaks)
        let w = Int(bounds.width)

        let paths = makeBucketPaths()
        var x = 0
        while x < w {
            let pLo = Int(Double(x) / map.width * Double(map.bufferBins))
            let pHi = max(pLo + 1, Int(Double(x + 1) / map.width * Double(map.bufferBins)))
            var lo: Float = .greatestFiniteMagnitude
            var hi: Float = -.greatestFiniteMagnitude
            var any = false
            var p = pLo
            while p < pHi && p < map.bufferBins {
                let b = map.absBin(p)
                if b >= 0, let env = peaks.envelope(fromBin: b, toBin: b + 1) {
                    if env.low < lo { lo = env.low }
                    if env.high > hi { hi = env.high }
                    any = true
                }
                p += 1
            }
            if any { addBar((low: lo, high: hi), atX: x, width: w, into: paths) }
            x += 1
        }
        fillBuckets(ctx, paths)
        drawSelectionWrapping(ctx, engine, map)
        drawHead(ctx, x: map.headX)
    }

    // MARK: Draw helpers

    private func makeBucketPaths() -> [CGMutablePath] {
        (0..<Self.rainbowColors.count).map { _ in CGMutablePath() }
    }
    private func addBar(_ env: (low: Float, high: Float), atX x: Int, width w: Int, into paths: [CGMutablePath]) {
        let gain = 2.0
        let height = bounds.height
        let midY = height / 2
        let lo = max(-1.0, Double(env.low) * gain)
        let hi = min(1.0, Double(env.high) * gain)
        let yLo = midY + CGFloat(lo) * (height / 2)
        let yHi = midY + CGFloat(hi) * (height / 2)
        let bucket = min(Self.rainbowColors.count - 1, x * Self.rainbowColors.count / w)
        paths[bucket].addRect(CGRect(x: CGFloat(x), y: yLo, width: 1, height: max(1, yHi - yLo)))
    }
    private func fillBuckets(_ ctx: CGContext, _ paths: [CGMutablePath]) {
        for i in 0..<paths.count where !paths[i].isEmpty {
            ctx.addPath(paths[i]); ctx.setFillColor(Self.rainbowColors[i]); ctx.fillPath()
        }
    }
    private func drawHead(_ ctx: CGContext, x hx: Double) {
        guard hx >= 0, hx <= bounds.width else { return }
        ctx.setStrokeColor(NSColor.systemYellow.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1.5)
        ctx.move(to: CGPoint(x: hx, y: 0)); ctx.addLine(to: CGPoint(x: hx, y: bounds.height)); ctx.strokePath()
    }
    private func drawSelectionLinear(_ ctx: CGContext, _ engine: CaptureEngine) {
        guard let sel = selection, sel.end > sel.start else { return }
        let sx = max(0, xAtFrame(sel.start, engine))
        let ex = min(bounds.width, xAtFrame(sel.end, engine))
        guard ex > sx else { return }
        ctx.setFillColor(NSColor(white: 1, alpha: 0.16).cgColor)
        ctx.fill(CGRect(x: sx, y: 0, width: ex - sx, height: bounds.height))
    }
    private func drawSelectionWrapping(_ ctx: CGContext, _ engine: CaptureEngine, _ map: LoopMap) {
        guard let sel = selection, sel.end > sel.start else { return }
        let sx = map.xForFrame(sel.start)
        let ex = map.xForFrame(sel.end)
        ctx.setFillColor(NSColor(white: 1, alpha: 0.16).cgColor)
        if sx <= ex {
            ctx.fill(CGRect(x: sx, y: 0, width: max(1, ex - sx), height: bounds.height))
        } else {   // selection wraps across the sweep edge
            ctx.fill(CGRect(x: sx, y: 0, width: max(1, map.width - sx), height: bounds.height))
            ctx.fill(CGRect(x: 0, y: 0, width: max(1, ex), height: bounds.height))
        }
    }

    private func drawPlaceholder() {
        let text = (engine?.isCapturing == true) ? "Listening… play some audio" : "Start capturing to see the waveform"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor(white: 0.5, alpha: 1)
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        str.draw(at: NSPoint(x: (bounds.width - str.size().width) / 2, y: (bounds.height - str.size().height) / 2))
    }
    private func drawBadge(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.systemYellow
        ]
        NSAttributedString(string: text, attributes: attrs).draw(at: NSPoint(x: 8, y: bounds.height - 16))
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard let engine, engine.isCapturing else { return }
        let p = convert(event.locationInWindow, from: nil)

        if event.modifierFlags.contains(.control) {
            paused.toggle()
            if paused { frozenWriteFrame = engine.currentWriteFrame }
            needsDisplay = true
            return
        }

        interactionRefFrame = engine.currentWriteFrame   // freeze the view for the interaction
        let frame = selectableFrame(Double(p.x), engine)

        if let sel = selection, sel.end > sel.start, frame >= sel.start, frame <= sel.end {
            pendingDragOut = true
            dragStartPoint = p
        } else {
            selecting = true
            selectionAnchor = frame
            selection = (frame, frame)
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let engine, engine.isCapturing else { return }
        let p = convert(event.locationInWindow, from: nil)

        if pendingDragOut {
            if hypot(p.x - dragStartPoint.x, p.y - dragStartPoint.y) > 4 {
                pendingDragOut = false
                beginDragOut(with: event)
            }
            return
        }
        if selecting {
            let cur = selectableFrame(Double(p.x), engine)
            selection = (Swift.min(selectionAnchor, cur), Swift.max(selectionAnchor, cur))
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        if selecting {
            selecting = false
            if let sel = selection, sel.end - sel.start < 64 { selection = nil }
        }
        pendingDragOut = false
        interactionRefFrame = nil
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard let e = engine, e.isCapturing, e.displayMode == .scroll else { return }   // pan = scroll mode only
        let f = fpp(e)
        let delta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
        let viewFrames = Int(Double(bounds.width) * f)
        let refWrite = refWriteFrame(e)
        let contentStart = max(0, refWrite - capacityFrames(e))
        let liveLeft = max(contentStart, refWrite - viewFrames)
        let newLeft = min(max(leftFrame(e) - Int(Double(delta) * f), contentStart), liveLeft)
        viewLeftFrame = newLeft
        followLive = newLeft >= liveLeft
        needsDisplay = true
    }

    // MARK: Drag-out

    private func beginDragOut(with event: NSEvent) {
        guard let engine, let sel = selection, sel.end > sel.start else { return }
        guard let url = engine.exportSelection(startFrame: sel.start, frameCount: sel.end - sel.start) else { return }

        let sx = Swift.min(Swift.max(xAtFrame(sel.start, engine), 0), bounds.width)
        let ex = Swift.min(Swift.max(xAtFrame(sel.end, engine), 0), bounds.width)
        let rectX = Swift.min(sx, ex)
        let rectW = Swift.max(8, abs(ex - sx))
        var rect = CGRect(x: rectX, y: 0, width: rectW, height: bounds.height).intersection(bounds)
        if rect.isNull || rect.width < 1 {
            rect = CGRect(x: 0, y: 0, width: Swift.min(8, bounds.width), height: bounds.height)
        }

        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        if let rep = bitmapImageRepForCachingDisplay(in: rect) {
            cacheDisplay(in: rect, to: rep)
            let image = NSImage(size: rect.size)
            image.addRepresentation(rep)
            item.setDraggingFrame(rect, contents: image)
        } else {
            item.setDraggingFrame(rect, contents: nil)
        }
        beginDraggingSession(with: [item], event: event, source: self)
    }
}

extension WaveformView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        interactionRefFrame = nil
        pendingDragOut = false
        selecting = false
        needsDisplay = true
    }
}
