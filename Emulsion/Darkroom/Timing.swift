import Foundation

/// Development timings, appended to Documents/timing.log, for tuning on the device.
enum Timing {
    private static let queue = DispatchQueue(label: "emulsion.timing")
    private static var start = Date()

    static func begin(_ label: String) {
        let now = Date()
        queue.async {
            start = now
            append("\n\(label)")
        }
    }

    static func mark(_ event: String) {
        let now = Date()
        queue.async { append(String(format: "  %6.2fs  %@", now.timeIntervalSince(start), event)) }
    }

    private static func append(_ line: String) {
        #if os(macOS)
        // The Mac tools share this file; they print instead of writing into the user's Documents.
        print(line)
        #else
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = (line + "\n").data(using: .utf8) else { return }
        let url = documents.appendingPathComponent("timing.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
        #endif
    }
}
