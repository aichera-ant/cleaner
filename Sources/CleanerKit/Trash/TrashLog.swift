import os

/// Taşıma yolunun birleşik günlüğü (`log stream --predicate 'subsystem == "com.aichera.cleaner"'`).
/// Yol, yöntem ve ret nedeni `.public` yazılır; dosya içeriği hiçbir zaman yazılmaz.
enum TrashLog {
    static let logger = Logger(subsystem: "com.aichera.cleaner", category: "trash")
}
