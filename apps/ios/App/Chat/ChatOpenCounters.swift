import Foundation

struct ChatOpenCounters: Equatable {
    enum Source: String {
        case model
        case snapshot
        case none
    }

    let source: Source
    let rowsAtFirstPublish: Int
    let zeroRowsMilliseconds: Int

    var message: String {
        "open cache=\(source.rawValue) rowsAtFirstPublish=\(rowsAtFirstPublish) zeroRowsMs=\(zeroRowsMilliseconds)"
    }
}
