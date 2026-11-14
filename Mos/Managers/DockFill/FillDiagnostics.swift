//
//  FillDiagnostics.swift
//  Mos
//
//  「窗口铺满下屏」诊断日志。
//  同时写统一日志(NSLog, 可在 Console.app 中过滤 MosDockDiag)与 /tmp/mosfill.log,
//  方便用户把日志内容直接贴给维护者定位问题。
//

import Foundation

enum FillDiagnostics {
    /// 方便用户查看的日志文件
    static let filePath = "/tmp/mosfill.log"
    /// 超过该大小就在下次写入时清空, 避免无限增长
    private static let maxFileSize: UInt64 = 1_048_576

    private static let queue = DispatchQueue(label: "mos.fill.diagnostics")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func log(_ message: String) {
        NSLog("MosDockDiag: %@", message)
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            append(line)
        }
    }

    /// 应用启动时写一条分隔线, 便于区分多次运行
    static func markSessionStart() {
        log("===== Mos fill session start pid=\(getpid()) =====")
    }

    private static func append(_ line: String) {
        let manager = FileManager.default
        if !manager.fileExists(atPath: filePath) {
            manager.createFile(atPath: filePath, contents: Data("Mos Fill Diagnostics\n".utf8))
        } else if let attributes = try? manager.attributesOfItem(atPath: filePath),
                  let size = attributes[.size] as? UInt64,
                  size > maxFileSize {
            try? Data().write(to: URL(fileURLWithPath: filePath))
        }
        guard let handle = FileHandle(forWritingAtPath: filePath) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        handle.write(Data(line.utf8))
    }
}
