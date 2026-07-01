import OSLog

nonisolated enum Log {
    static let subsystem = "com.danneu.dancam"

    static let reducer = Logger(subsystem: subsystem, category: "reducer")
    static let pull = Logger(subsystem: subsystem, category: "pull")
    static let remux = Logger(subsystem: subsystem, category: "remux")
    static let tsDemux = Logger(subsystem: subsystem, category: "ts-demux")
    static let h264 = Logger(subsystem: subsystem, category: "h264-au")
    static let playback = Logger(subsystem: subsystem, category: "playback")
    static let nav = Logger(subsystem: subsystem, category: "nav")
}
