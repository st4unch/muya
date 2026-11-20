// Storage heads-up rule of the web (src/redesign/StorageHeadsUp.tsx): once a day, only when the history is heavy.

import Foundation

enum StorageHeadsUpLogic {
    static func text(count: Int, bytes: Int64, old: Int, big: Int) -> String {
        "\(count) sessions · \(SessionsLogic.byteSize(bytes))" + (old > 0 ? " · \(old) not used for 30+ days" : "") + (big > 0 ? " · \(big) over 100 MB" : "") + " — big histories slow Muya and Claude down."
    }
    static func summary(_ entries: [HistoryEntry], now: Date) -> (count: Int, bytes: Int64, old: Int, big: Int) {
        let ms = now.timeIntervalSince1970 * 1000, day = 86_400_000.0
        return (entries.count, entries.reduce(Int64(0)) { $0 + $1.sizeBytes },
                entries.filter { ms - Double($0.lastModified) > 30 * day }.count, entries.filter { $0.sizeBytes > 100 * 1_048_576 }.count)
    }
    static func heavy(_ s: (count: Int, bytes: Int64, old: Int, big: Int)) -> Bool { s.old > 0 || s.big > 0 }
    static func dayKey(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d) }
}
