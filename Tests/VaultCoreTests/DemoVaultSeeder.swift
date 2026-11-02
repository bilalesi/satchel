import XCTest
@testable import VaultCore

/// Not a test: seeds a folder of throwaway vaults (four workspaces, each with categories and items of every
/// type, spread over a year so the "rotate soon" list has entries) for UI work, screenshots and the promo video.
/// `SATCHEL_DEMO_DIR=/path swift test --filter DemoVaultSeeder` (or run `scripts/demo.sh`, which does this and
/// launches an isolated copy of the app). Every secret in here is fake. Password for all: `demo-password-123`.
final class DemoVaultSeeder: XCTestCase {
    static let password = "demo-password-123"

    private struct Cat { let name: String, icon: String, color: String }
    private struct Row {
        let type: ItemType, title: String, user: String?, url: String?, tags: [String], cat: Int?
        let fav: Bool, days: Double, fields: [String: String], apps: [String]
        init(_ type: ItemType, _ title: String, user: String? = nil, url: String? = nil, tags: [String] = [], cat: Int? = nil,
             fav: Bool = false, days: Double, apps: [String] = [], _ fields: [String: String]) {
            self.type = type; self.title = title; self.user = user; self.url = url; self.tags = tags; self.cat = cat
            self.fav = fav; self.days = days; self.fields = fields; self.apps = apps
        }
    }
    private struct Space {
        let id: String, name: String, icon: String, color: String, categories: [Cat], rows: [Row]
    }

    private static let totp1 = "JBSWY3DPEHPK3PXP", totp2 = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", totp3 = "MFRGGZDFMZTWQ2LKNNWG23TP"
    private static let key = "-----BEGIN OPENSSH PRIVATE KEY-----\ndemo-key-not-real\n-----END OPENSSH PRIVATE KEY-----"

    private static let spaces: [Space] = [
        Space(id: "11111111-1111-4111-8111-111111111111", name: "Personal", icon: "home", color: "blue",
              categories: [Cat(name: "Banking", icon: "creditCard", color: "green"), Cat(name: "Streaming", icon: "game", color: "purple"),
                           Cat(name: "Shopping", icon: "gift", color: "orange"), Cat(name: "Travel", icon: "globe", color: "teal"),
                           Cat(name: "Social", icon: "heart", color: "pink")],
              rows: [
                Row(.login, "Checking account", user: "alex.demo", url: "https://bank.example.com", tags: ["money"], cat: 0, fav: true, days: 3,
                    ["password": "demo-Bank-4242", "totpSeed": totp1]),
                Row(.secureNote, "Backup card", tags: ["money"], cat: 0, days: 120, ["notes": "Card ending 4242 · expires 09/29\n(demo data, not a real card)"]),
                Row(.login, "Netflix", user: "alex@example.com", url: "https://netflix.com", cat: 1, days: 45, ["password": "demo-netflix"]),
                Row(.login, "Spotify", user: "alex.demo", url: "https://spotify.com", cat: 1, fav: true, days: 12, ["password": "demo-spotify"]),
                Row(.login, "Amazon", user: "alex@example.com", url: "https://amazon.com", tags: ["shop"], cat: 2, fav: true, days: 8,
                    ["password": "demo-amazon", "totpSeed": totp2]),
                Row(.login, "IKEA", user: "alex@example.com", url: "https://ikea.com", tags: ["shop"], cat: 2, days: 230, ["password": "demo-ikea"]),
                Row(.login, "Booking", user: "alex@example.com", url: "https://booking.com", cat: 3, days: 30, ["password": "demo-booking"]),
                Row(.login, "Airline miles", user: "AB12345", url: "https://airline.example.com", cat: 3, days: 410, ["password": "demo-miles"]),
                Row(.login, "Instagram", user: "alex.demo", url: "https://instagram.com", cat: 4, days: 60, apps: ["com.burbn.instagram"], ["password": "demo-insta"]),
                Row(.login, "Apple ID", user: "alex@example.com", url: "https://appleid.apple.com", fav: true, days: 1, ["password": "demo-apple", "totpSeed": totp3]),
                Row(.secureNote, "Home router", tags: ["home"], days: 150, ["notes": "Network: Casa-5G\nPassword: demo-wifi-pass\nAdmin: 192.168.1.1"]),
                Row(.secureNote, "Recovery codes", tags: ["mail"], days: 90, ["notes": "demo-1111\ndemo-2222\ndemo-3333\ndemo-4444"]),
              ]),
        Space(id: "22222222-2222-4222-8222-222222222222", name: "Work", icon: "briefcase", color: "orange",
              categories: [Cat(name: "Infrastructure", icon: "satchel.server", color: "blue"), Cat(name: "Payments", icon: "creditCard", color: "green"),
                           Cat(name: "Monitoring", icon: "lightbulb", color: "orange"), Cat(name: "CI/CD", icon: "rocket", color: "purple"),
                           Cat(name: "Access", icon: "satchel.lock", color: "red")],
              rows: [
                Row(.login, "AWS console", user: "ops@corp.example", url: "https://aws.amazon.com", tags: ["cloud"], cat: 0, fav: true, days: 2,
                    ["password": "demo-aws", "totpSeed": totp1]),
                Row(.apiKey, "AWS access key", user: "deploy-bot", tags: ["cloud"], cat: 0, days: 20,
                    ["apiKey": "AKIADEMO000000000000", "endpoint": "https://sts.amazonaws.com"]),
                Row(.dbCredential, "Postgres · production", user: "app_rw", tags: ["db"], cat: 0, fav: true, days: 5, apps: ["org.jkiss.dbeaver.core.product"],
                    ["host": "db.prod.example", "port": "5432", "database": "app", "password": "demo-pg-prod"]),
                Row(.dbCredential, "Postgres · staging", user: "app_rw", tags: ["db"], cat: 0, days: 15,
                    ["host": "db.stg.example", "port": "5432", "database": "app", "password": "demo-pg-stg"]),
                Row(.dbCredential, "Redis cache", user: "default", tags: ["db"], cat: 0, days: 95, ["host": "cache.prod.example", "port": "6379", "password": "demo-redis"]),
                Row(.apiKey, "Stripe live key", user: "billing", url: "https://dashboard.stripe.com", tags: ["payments"], cat: 1, fav: true, days: 12,
                    ["apiKey": "sk_test_demo_000000000000", "endpoint": "https://api.stripe.com"]),
                Row(.webhook, "Stripe webhook secret", tags: ["payments"], cat: 1, days: 28, ["url": "https://api.example.com/hooks/stripe", "secret": "whsec_demo000"]),
                Row(.apiKey, "Datadog API key", tags: ["ops"], cat: 2, days: 70, ["apiKey": "dd-demo-0000000000"]),
                Row(.webhook, "Sentry DSN", tags: ["ops"], cat: 2, days: 33, ["url": "https://demo@o0.ingest.sentry.io/0"]),
                Row(.login, "PagerDuty", user: "ops@corp.example", url: "https://pagerduty.com", tags: ["ops"], cat: 2, days: 195, ["password": "demo-pd"]),
                Row(.sshKey, "GitHub Actions deploy key", user: "deploy", tags: ["ci"], cat: 3, days: 7, ["privateKey": key, "host": "github.com"]),
                Row(.apiKey, "Docker Hub token", user: "corp-bot", tags: ["ci"], cat: 3, days: 265, ["apiKey": "dckr_pat_demo000"]),
                Row(.webhook, "Slack deploy alerts", tags: ["ci"], cat: 3, days: 20, apps: ["com.tinyspeck.slackmacgap"], ["url": "https://hooks.slack.com/services/T000/B000/demo"]),
                Row(.login, "Okta", user: "alex@corp.example", url: "https://corp.okta.com", cat: 4, fav: true, days: 1, ["password": "demo-okta", "totpSeed": totp2]),
                Row(.login, "VPN", user: "alex", cat: 4, days: 50, ["password": "demo-vpn"]),
                Row(.sshKey, "Bastion host", user: "ec2-user", tags: ["cloud"], cat: 4, days: 140, ["privateKey": key, "host": "bastion.prod.example"]),
              ]),
        Space(id: "33333333-3333-4333-8333-333333333333", name: "Side project", icon: "rocket", color: "purple",
              categories: [Cat(name: "Backend", icon: "database", color: "blue"), Cat(name: "Domains", icon: "globe", color: "teal"),
                           Cat(name: "Analytics", icon: "satchel.overview", color: "orange"), Cat(name: "Launch", icon: "rocket", color: "pink")],
              rows: [
                Row(.dbCredential, "Supabase", user: "postgres", tags: ["db"], cat: 0, fav: true, days: 4,
                    ["host": "db.demo.supabase.co", "port": "5432", "database": "postgres", "password": "demo-supabase"]),
                Row(.login, "Vercel", user: "alex@example.com", url: "https://vercel.com", cat: 0, days: 18, ["password": "demo-vercel", "totpSeed": totp1]),
                Row(.apiKey, "Resend API key", tags: ["mail"], cat: 0, days: 40, ["apiKey": "re_demo_0000000"]),
                Row(.apiKey, "LLM API key", tags: ["ai"], cat: 0, fav: true, days: 6, ["apiKey": "sk-demo-000000000000"]),
                Row(.apiKey, "Cloudflare DNS token", tags: ["dns"], cat: 1, days: 75, ["apiKey": "cf-demo-token"]),
                Row(.login, "Domain registrar", user: "alex@example.com", url: "https://registrar.example.com", cat: 1, days: 300, ["password": "demo-registrar"]),
                Row(.login, "Plausible", user: "alex@example.com", url: "https://plausible.io", cat: 2, days: 55, ["password": "demo-plausible"]),
                Row(.login, "Product Hunt", user: "alex.demo", url: "https://producthunt.com", cat: 3, days: 9, ["password": "demo-ph"]),
                Row(.apiKey, "Discord bot token", tags: ["bot"], cat: 3, days: 25, apps: ["com.hnc.Discord"], ["apiKey": "demo.discord.bot.token"]),
                Row(.secureNote, "Launch checklist", tags: ["launch"], cat: 3, days: 2, ["notes": "☐ DNS\n☐ Status page\n☐ Rotate keys after beta\n☐ Post on launch day"]),
              ]),
        Space(id: "44444444-4444-4444-8444-444444444444", name: "Family", icon: "heart", color: "pink",
              categories: [Cat(name: "Home", icon: "home", color: "blue"), Cat(name: "School", icon: "mortarBoard", color: "orange"),
                           Cat(name: "Insurance", icon: "satchel.shield", color: "green")],
              rows: [
                Row(.secureNote, "Guest Wi-Fi", tags: ["home"], cat: 0, fav: true, days: 14, ["notes": "Network: Casa-Guest\nPassword: demo-guest-wifi"]),
                Row(.login, "Smart TV", user: "family@example.com", cat: 0, days: 160, ["password": "demo-tv"]),
                Row(.login, "Electricity account", user: "family@example.com", url: "https://power.example.com", cat: 0, days: 85, ["password": "demo-power"]),
                Row(.login, "School portal", user: "parent-alex", url: "https://school.example.com", cat: 1, fav: true, days: 6, ["password": "demo-school"]),
                Row(.login, "Pediatrician", user: "alex", url: "https://clinic.example.com", cat: 1, days: 130, ["password": "demo-clinic"]),
                Row(.secureNote, "Home insurance", tags: ["policy"], cat: 2, days: 200, ["notes": "Policy HI-0000-DEMO\nRenews every March"]),
                Row(.login, "Car insurance", user: "alex", url: "https://cars.example.com", cat: 2, days: 100, ["password": "demo-car"]),
              ]),
    ]

    func testSeedDemoVaults() throws {
        guard let path = ProcessInfo.processInfo.environment["SATCHEL_DEMO_DIR"] else {
            throw XCTSkip("set SATCHEL_DEMO_DIR to seed the demo vaults")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date()
        var registry: [[String: String]] = []

        for space in Self.spaces {
            let url = dir.appendingPathComponent(space.id + ".vault", isDirectory: true)
            let store = try VaultStore.create(at: url, password: SecureBytes(utf8: Self.password),
                                              kdfParams: KDFParams(memoryKiB: 8192, iterations: 1, salt: Data((0..<16).map { _ in UInt8.random(in: 0...255) })))
            var categoryIDs: [UUID] = []
            for (n, c) in space.categories.enumerated() {
                let o = ItemOverview(type: .category, title: c.name, createdAt: now - 400 * 86400, updatedAt: now - Double(300 - n) * 86400)
                try store.save(overview: o, details: ItemDetails(fields: ["icon": c.icon, "color": c.color]), stampingNow: false)
                categoryIDs.append(o.id)
            }
            for r in space.rows {
                let o = ItemOverview(type: r.type, title: r.title, username: r.user, urls: r.url.map { [$0] } ?? [], bundleIDs: r.apps, tags: r.tags,
                                     categoryID: r.cat.map { categoryIDs[$0] }, favorite: r.fav,
                                     createdAt: now - (r.days + 30) * 86400, updatedAt: now - r.days * 86400)
                try store.save(overview: o, details: ItemDetails(fields: r.fields), stampingNow: false)
            }
            let loaded = try store.loadOverviews().items
            XCTAssertEqual(loaded.count, space.rows.count + space.categories.count, space.name)
            registry.append(["id": space.id, "name": space.name, "path": url.path, "iconName": space.icon, "colorName": space.color])
        }
        // The list in the shape the app stores it, for scripts/demo.sh to put into the app's defaults.
        try JSONSerialization.data(withJSONObject: registry, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent("workspaces.json"))
    }
}
