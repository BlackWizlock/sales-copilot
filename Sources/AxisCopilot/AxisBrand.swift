import SwiftUI

enum AxisBrand {
    static let teal = Color(red: 36 / 255, green: 145 / 255, blue: 155 / 255)
    static let navy = Color(red: 58 / 255, green: 68 / 255, blue: 88 / 255)
}

/// Kept outside the meeting scroll views so the product identity stays visible.
struct AxisBrandHeader: View {
    var body: some View {
        HStack(spacing: 14) {
            if let url = Bundle.main.resourceURL?.appendingPathComponent("axis_sign.png"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image).renderingMode(.template).resizable()
                    .scaledToFit().frame(width: 30, height: 30).accessibilityHidden(true)
            }
            Text("Аксис Суфлёр").font(.title3.weight(.semibold))
            Rectangle().fill(.white.opacity(0.3)).frame(width: 1, height: 24)
            Text("Запись и транскрипция встреч").font(.callout)
            Spacer()
            Label("На этом Mac", systemImage: "lock.shield")
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(.white).padding(.horizontal, 24).padding(.vertical, 13)
        .background(AxisBrand.teal)
    }
}

struct AxisProductCredits: View {
    var body: some View {
        HStack(spacing: 18) {
            Text("Разработано Аксис Консалт").fontWeight(.medium)
            Spacer(minLength: 12)
            Link("Консалтинг", destination: URL(string: "https://axisconsult.ru")!)
            Link("Платформа", destination: URL(string: "https://axisplatform.ru")!)
            Link("Обучение", destination: URL(string: "https://edu.axisconsult.ru")!)
        }
        .font(.caption).foregroundStyle(.white).tint(.white)
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(AxisBrand.navy)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Продукты Аксис")
    }
}
