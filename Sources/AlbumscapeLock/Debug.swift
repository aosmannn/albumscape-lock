import Foundation

/// Temporary: appends to a file in the host's temp folder so a run can be read from outside.
enum Debug {
    static func log(_ message: String) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("albumscape-debug.log")
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
