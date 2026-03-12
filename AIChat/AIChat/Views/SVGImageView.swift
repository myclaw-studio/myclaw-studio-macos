import SwiftUI

/// Loads an image from URL supporting both SVG and raster formats.
struct RemoteImage: View {
    let url: String
    let size: CGFloat

    @State private var nsImage: NSImage?

    var body: some View {
        Group {
            if let img = nsImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: size * 0.6))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            guard let u = URL(string: url), !url.isEmpty else { return }
            do {
                let (data, _) = try await URLSession.shared.data(from: u)
                if let img = NSImage(data: data) {
                    await MainActor.run { nsImage = img }
                }
            } catch {}
        }
    }
}
