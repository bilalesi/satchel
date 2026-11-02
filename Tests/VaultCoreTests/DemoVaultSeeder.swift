import XCTest
@testable import VaultCore

/// Not a test: seeds a throwaway vault with fake items for UI work and screenshots.
/// `SATCHEL_DEMO_VAULT=/path/demo.vault swift test --filter DemoVaultSeeder`
/// Password: `demo-password-123` (test value, never a real secret).
final class DemoVaultSeeder: XCTestCase {
    static let password = "demo-password-123"

    func testSeedDemoVault() throws {
        guard let path = ProcessInfo.processInfo.environment["SATCHEL_DEMO_VAULT"] else {
            throw XCTSkip("set SATCHEL_DEMO_VAULT to seed a demo vault")
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        let store = try VaultStore.create(at: url, password: SecureBytes(utf8: Self.password),
                                          kdfParams: KDFParams(memoryKiB: 8192, iterations: 1, salt: Data(repeating: 9, count: 16)))
        let day: TimeInterval = 86400
        let now = Date()
        let items: [(ItemOverview, [String: String])] = [
            (ItemOverview(type: .login, title: "Gmail", username: "alex@example.com", urls: ["https://accounts.google.com"], tags: ["mail"], favorite: true, updatedAt: now - 2 * day),
             ["password": "demo-Gm4il-pass", "totpSeed": "JBSWY3DPEHPK3PXP"]),
            (ItemOverview(type: .login, title: "Discord", username: "alex#4821", urls: ["https://discord.com"], bundleIDs: ["com.hnc.Discord"], tags: ["chat"], updatedAt: now - 40 * day),
             ["password": "demo-discord-pw"]),
            (ItemOverview(type: .login, title: "Microsoft Teams", username: "alex@corp.example", urls: ["https://teams.microsoft.com"], bundleIDs: ["com.microsoft.teams2"], tags: ["work"], updatedAt: now - 200 * day),
             ["password": "demo-teams-pw"]),
            (ItemOverview(type: .login, title: "GitHub", username: "alex-dev", urls: ["https://github.com"], tags: ["dev"], favorite: true, updatedAt: now - 1 * day),
             ["password": "demo-gh-pw", "totpSeed": "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"]),
            (ItemOverview(type: .apiKey, title: "Stripe live key", username: "billing", urls: ["https://dashboard.stripe.com"], tags: ["payments"], updatedAt: now - 12 * day),
             ["apiKey": "sk_test_demo_000000000000", "endpoint": "https://api.stripe.com"]),
            (ItemOverview(type: .apiKey, title: "OpenWeather", tags: ["dev"], updatedAt: now - 300 * day),
             ["apiKey": "demo-weather-key"]),
            (ItemOverview(type: .dbCredential, title: "Postgres · production", username: "app_rw", bundleIDs: ["org.jkiss.dbeaver.core.product"], tags: ["work", "db"], favorite: true, updatedAt: now - 5 * day),
             ["host": "db.internal.example", "port": "5432", "database": "app", "password": "demo-pg-pw"]),
            (ItemOverview(type: .dbCredential, title: "Redis cache", username: "default", tags: ["db"], updatedAt: now - 90 * day),
             ["host": "localhost", "port": "6379", "password": "demo-redis"]),
            (ItemOverview(type: .webhook, title: "Discord alerts webhook", tags: ["ops"], updatedAt: now - 20 * day),
             ["url": "https://discord.com/api/webhooks/000/demo"]),
            (ItemOverview(type: .secureNote, title: "Recovery codes", tags: ["mail"], updatedAt: now - 60 * day),
             ["notes": "demo-1111\ndemo-2222\ndemo-3333"]),
            (ItemOverview(type: .sshKey, title: "Deploy key", username: "deploy", tags: ["ops"], updatedAt: now - 7 * day),
             ["privateKey": "-----BEGIN OPENSSH PRIVATE KEY-----\ndemo\n-----END OPENSSH PRIVATE KEY-----", "host": "deploy.example"]),
        ]
        for (o, f) in items { try store.save(overview: o, details: ItemDetails(fields: f)) }
        // Restore the intended "updated" dates (save() stamps now).
        XCTAssertEqual(try store.loadOverviews().items.count, items.count)
    }
}
