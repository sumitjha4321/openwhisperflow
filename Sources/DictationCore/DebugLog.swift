import Foundation

public func owfLog(_ message: String) {
    let line = "[\(String(format: "%.3f", Date.timeIntervalSinceReferenceDate))] \(message)\n"
    if let fh = FileHandle(forWritingAtPath: "/tmp/owf-debug.log") {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        try? fh.close()
    }
}
