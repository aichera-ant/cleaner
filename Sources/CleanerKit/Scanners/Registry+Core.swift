// Çekirdek tarayıcıların kaydı. Sahibi: çekirdek (İP1-1).
extension CleanerRegistry {
    static func registerCoreScanners(_ r: inout CleanerRegistry) {
        r.register(RuleBasedScanner())
    }
}
