// SPDX-License-Identifier: GPL-2.0-only
import SwiftUI
import AppKit
import GravityCore

// Name the property-wrapper type explicitly; newer SDKs also export a State macro.
private typealias DragOrigin = SwiftUI.State<Double?>

/// Both this diagram and the slider edit the same boundary, measured from the
/// left edge of the combined macOS and available space.
struct PartitionDiagram: View {
    let target: StorageTarget
    @Binding var boundaryGB: Double
    @DragOrigin private var dragStartGB: Double? = nil
    private typealias T = InstallerTheme
    private var linux: Int64 { target.boundedAllocation(Int64(((Double(target.diagramTotalBytes) / 1e9 - boundaryGB) * 1e9).rounded())) }
    private var macOS: Int64 { target.kind == "resize" ? target.totalBytes - target.shrinkBytes(for: linux) : 0 }
    private var unused: Int64 { target.unusedBytes(for: linux) }
    private var used: Int64 { target.kind == "resize" ? max(0, target.totalBytes - target.freeBytes) : 0 }

    var body: some View {
        GeometryReader { geometry in
            let available = max(1, geometry.size.width - 16)
            let scale = available / CGFloat(max(1, target.diagramTotalBytes))
            HStack(spacing: 0) {
                if macOS > 0 {
                    ZStack(alignment: .leading) {
                        T.surface
                        T.hairline.frame(width: min(CGFloat(macOS), CGFloat(used)) * scale)
                        labels("macOS", "\(sizeText(macOS)) · \(sizeText(max(0, macOS-used))) free")
                    }.frame(width: CGFloat(macOS) * scale, height: 72).clipShape(PartitionSegment(leading: true))
                }
                if unused > 0 {
                    ZStack(alignment: .leading) {
                        Color.white
                        Rectangle().strokeBorder(T.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3])).padding(.horizontal, 3)
                        if CGFloat(unused) * scale >= 42 {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Unallocated").font(T.font(12, .medium)).minimumScaleFactor(0.6)
                                Text(sizeText(unused)).font(T.font(11)).minimumScaleFactor(0.6)
                            }.lineLimit(1).padding(.horizontal, 6)
                        }
                    }.frame(width: CGFloat(unused) * scale, height: 72).clipped()
                        .help("\(sizeText(unused)) will remain unallocated")
                }
                Capsule().fill(T.border).frame(width: 4, height: 32)
                    .frame(width: 16, height: 72).background(.white)
                if linux > 0 {
                    labels("Gravity Linux", sizeText(linux))
                        .frame(width: CGFloat(linux) * scale, height: 72, alignment: .leading)
                        .foregroundStyle(.white).background(T.accent).clipShape(PartitionSegment(leading: false))
                }
            }.clipShape(RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                    if dragStartGB == nil { dragStartGB = boundaryGB }
                    boundaryGB = ((dragStartGB ?? boundaryGB) + Double(gesture.translation.width / available) * Double(target.diagramTotalBytes) / 1e9).rounded()
                }.onEnded { _ in dragStartGB = nil })
                .onHover { hovering in if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
        }.frame(height: 72)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Partition diagram")
            .accessibilityValue("macOS \(sizeText(macOS)), unallocated \(sizeText(unused)), Gravity Linux \(linux == 0 ? "0 GB" : sizeText(linux))")
            .accessibilityAdjustableAction { direction in boundaryGB += direction == .increment ? -1 : 1 }
    }

    private func labels(_ name: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(T.font(14, .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            Text(detail).font(T.font(12)).lineLimit(1).minimumScaleFactor(0.8)
        }.padding(.horizontal, 16).clipped()
    }
}
