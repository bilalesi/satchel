import XCTest
@testable import VaultCore

final class VaultStoreTests: XCTestCase {
    var dir: URL!
    let cheap = KDFParams(memoryKiB: 8192, iterations: 1, salt: Data(repeating: 3, count: 16))
    let device = UUID()
    let pw = SecureBytes(utf8: "pw")

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vault-test-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func makeStore() throws -> VaultStore {
        try VaultStore.create(at: dir, password: pw, kdfParams: cheap, deviceID: device)
    }

    func login(_ title: String, pass: String) -> (ItemOverview, ItemDetails) {
        (ItemOverview(type: .login, title: title, username: "u", urls: ["https://\(title.lowercased()).com"]),
         ItemDetails(fields: ["password": pass]))
    }

    func testCreateUnlockRoundTrip() throws {
        let store = try makeStore()
        XCTAssertTrue(store.isUnlocked)
        let (o1, d1) = login("Gmail", pass: "a")
        let (o2, d2) = login("Discord", pass: "b")
        try store.save(overview: o1, details: d1)
        try store.save(overview: o2, details: d2)
        store.lock()
        XCTAssertFalse(store.isUnlocked)
        XCTAssertThrowsError(try store.loadOverviews()) { XCTAssertEqual($0 as? VaultError, .locked) }

        let reopened = try VaultStore.open(at: dir, deviceID: device)
        XCTAssertFalse(reopened.isUnlocked)
        try reopened.unlock(password: pw)
        let loaded = try reopened.loadOverviews()
        XCTAssertEqual(Set(loaded.items.map(\.title)), ["Gmail", "Discord"])
        XCTAssertEqual(loaded.corrupt, [])
        XCTAssertEqual(try reopened.details(for: o1.id).fields["password"], "a")
        XCTAssertEqual(reopened.manifest.generation, 2)
        XCTAssertEqual(reopened.manifest.deviceID, device)
    }

    func testWrongPasswordAndWrongKeyAreRejected() throws {
        _ = try makeStore()
        let store = try VaultStore.open(at: dir, deviceID: device)
        XCTAssertThrowsError(try store.unlock(password: SecureBytes(utf8: "nope"))) {
            XCTAssertEqual($0 as? VaultError, .authenticationFailed)
        }
        XCTAssertThrowsError(try store.unlock(vaultKey: VaultKey.generate())) {
            XCTAssertEqual($0 as? VaultError, .corruptManifest)
        }
        XCTAssertFalse(store.isUnlocked)
    }

    func testSaveBumpsVersionAndGeneration() throws {
        let store = try makeStore()
        let (o, d) = login("Gmail", pass: "a")
        XCTAssertEqual(store.manifest.generation, 0)
        try store.save(overview: o, details: d)
        XCTAssertEqual(store.manifest.version(of: o.id), 1)
        XCTAssertEqual(store.manifest.generation, 1)
        try store.save(overview: o, details: d)
        XCTAssertEqual(store.manifest.version(of: o.id), 2)
        XCTAssertEqual(store.manifest.generation, 2)
        let fileData = try Data(contentsOf: store.itemsURL.appendingPathComponent("\(o.id.uuidString).vitem"))
        XCTAssertEqual(try ItemFile.decodeHeader(fileData).version, 2)
    }

    func testHistoryCapturesPreviousSecret() throws {
        let store = try makeStore()
        let (o, d) = login("Gmail", pass: "first")
        try store.save(overview: o, details: d)
        try store.save(overview: o, details: ItemDetails(fields: ["password": "second"]))
        let details = try store.details(for: o.id)
        XCTAssertEqual(details.fields["password"], "second")
        XCTAssertEqual(details.history.map(\.value), ["first"])
    }

    func testDeleteWritesTombstone() throws {
        let store = try makeStore()
        let (o, d) = login("Gmail", pass: "a")
        try store.save(overview: o, details: d)
        try store.delete(id: o.id)
        XCTAssertEqual(try store.loadOverviews().items, [])
        XCTAssertEqual(store.manifest.version(of: o.id), 2)
        let fileData = try Data(contentsOf: store.itemsURL.appendingPathComponent("\(o.id.uuidString).vitem"))
        XCTAssertTrue(try ItemFile.decodeHeader(fileData).deleted)
        XCTAssertThrowsError(try store.details(for: o.id)) { XCTAssertEqual($0 as? VaultError, .corruptItem(o.id)) }
    }

    func testCorruptItemIsSkippedAndReported() throws {
        let store = try makeStore()
        let (o, d) = login("Gmail", pass: "a")
        try store.save(overview: o, details: d)
        let badID = UUID()
        try Sodium.randomData(10).write(to: store.itemsURL.appendingPathComponent("\(badID.uuidString).vitem"))
        try Data().write(to: store.itemsURL.appendingPathComponent("\(UUID().uuidString).vitem"))
        let loaded = try store.loadOverviews()
        XCTAssertEqual(loaded.items.map(\.id), [o.id])
        XCTAssertEqual(loaded.corrupt.count, 2)
        XCTAssertTrue(loaded.corrupt.contains(badID))
    }

    func testCrashRecoveryAcceptsNewerFileAndRepairsManifest() throws {
        let store = try makeStore()
        let (o, d) = login("Gmail", pass: "a")
        try store.save(overview: o, details: d)
        // Simulate a crash after the item write but before the manifest write.
        let keys = VaultKeys(vaultKey: try store.withVaultKey { $0 })
        let newer = try ItemFile.encode(overview: o, details: ItemDetails(fields: ["password": "z"]),
                                        version: 5, deleted: false, keys: keys)
        try newer.write(to: store.itemsURL.appendingPathComponent("\(o.id.uuidString).vitem"))
        let before = store.manifest.generation
        let loaded = try store.loadOverviews()
        XCTAssertEqual(loaded.items.count, 1)
        XCTAssertEqual(loaded.corrupt, [])
        XCTAssertEqual(store.manifest.version(of: o.id), 5)
        XCTAssertEqual(store.manifest.generation, before + 1)
        XCTAssertEqual(try store.details(for: o.id).fields["password"], "z")
    }

    func testRolledBackFileIsReported() throws {
        let store = try makeStore()
        let (o, d) = login("Gmail", pass: "a")
        try store.save(overview: o, details: d)
        let v1 = try Data(contentsOf: store.itemsURL.appendingPathComponent("\(o.id.uuidString).vitem"))
        try store.save(overview: o, details: d) // v2
        try v1.write(to: store.itemsURL.appendingPathComponent("\(o.id.uuidString).vitem")) // attacker restores v1
        let loaded = try store.loadOverviews()
        XCTAssertEqual(loaded.items, [])
        XCTAssertEqual(loaded.corrupt, [o.id])
    }

    func testMissingFileListedInManifestIsReported() throws {
        let store = try makeStore()
        let (o, d) = login("Gmail", pass: "a")
        try store.save(overview: o, details: d)
        try FileManager.default.removeItem(at: store.itemsURL.appendingPathComponent("\(o.id.uuidString).vitem"))
        XCTAssertEqual(try store.loadOverviews().corrupt, [o.id])
    }

    func testTamperedManifestAndHeaderRejected() throws {
        _ = try makeStore()
        let manifestURL = dir.appendingPathComponent(Manifest.fileName)
        var m = try Data(contentsOf: manifestURL)
        m[3] ^= 0x01
        try m.write(to: manifestURL)
        XCTAssertThrowsError(try VaultStore.open(at: dir, deviceID: device).unlock(password: pw)) {
            XCTAssertEqual($0 as? VaultError, .corruptManifest)
        }
        try FileManager.default.removeItem(at: dir)
        _ = try makeStore()
        let headerURL = dir.appendingPathComponent(VaultHeader.fileName)
        var h = try Data(contentsOf: headerURL)
        h.append(contentsOf: [0x20]) // still valid JSON, different bytes
        try h.write(to: headerURL)
        XCTAssertThrowsError(try VaultStore.open(at: dir, deviceID: device).unlock(password: pw)) {
            XCTAssertEqual($0 as? VaultError, .corruptManifest)
        }
    }

    func testAtomicWriteLeavesNoTempFileAndRestrictsPermissions() throws {
        let store = try makeStore()
        for i in 0..<5 {
            let (o, d) = login("Item\(i)", pass: "p")
            try store.save(overview: o, details: d)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: store.itemsURL.path)
        XCTAssertEqual(names.count, 5)
        XCTAssertTrue(names.allSatisfy { !$0.hasPrefix(".") })
        let attrs = try FileManager.default.attributesOfItem(atPath: store.itemsURL.appendingPathComponent(names[0]).path)
        XCTAssertEqual((attrs[.posixPermissions] as? Int), 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual((dirAttrs[.posixPermissions] as? Int), 0o700)
    }

    func testChangePasswordKeepsItems() throws {
        let store = try makeStore()
        let (o, d) = login("Gmail", pass: "a")
        try store.save(overview: o, details: d)
        XCTAssertThrowsError(try store.changePassword(old: SecureBytes(utf8: "wrong"), new: SecureBytes(utf8: "new"), kdfParams: cheap)) {
            XCTAssertEqual($0 as? VaultError, .authenticationFailed)
        }
        try store.changePassword(old: pw, new: SecureBytes(utf8: "new"), kdfParams: cheap)
        let reopened = try VaultStore.open(at: dir, deviceID: device)
        XCTAssertThrowsError(try reopened.unlock(password: pw))
        try reopened.unlock(password: SecureBytes(utf8: "new"))
        XCTAssertEqual(try reopened.details(for: o.id).fields["password"], "a")
    }

    func testSecureEnclaveSlotIsLocalOnly() throws {
        let store = try makeStore()
        XCTAssertFalse(store.hasSecureEnclaveSlot)
        let headerBefore = try Data(contentsOf: dir.appendingPathComponent(VaultHeader.fileName))
        try store.addSecureEnclaveSlot(.secureEnclave(keyData: Data([1]), wrappedKey: Data([2])))
        XCTAssertTrue(store.hasSecureEnclaveSlot)
        try store.addSecureEnclaveSlot(.secureEnclave(keyData: Data([3]), wrappedKey: Data([4])))
        XCTAssertEqual(store.secureEnclaveSlot, .secureEnclave(keyData: Data([3]), wrappedKey: Data([4])))
        // Header and manifest untouched: the slot never reaches the synced files.
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(VaultHeader.fileName)), headerBefore)
        XCTAssertTrue(store.header.slots.allSatisfy(\.isPassword))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(VaultStore.touchIDSlotFileName).path))

        let reopened = try VaultStore.open(at: dir, deviceID: device)
        XCTAssertTrue(reopened.hasSecureEnclaveSlot) // readable before unlock, as the unlock screen needs
        try reopened.unlock(password: pw)
        try reopened.removeSecureEnclaveSlots()
        try reopened.removeSecureEnclaveSlots() // idempotent
        XCTAssertFalse(reopened.hasSecureEnclaveSlot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(VaultStore.touchIDSlotFileName).path))
        XCTAssertThrowsError(try store.addSecureEnclaveSlot(.password(params: cheap, wrappedKey: Data())))
    }

    func testLegacyHeaderSlotIsMigratedOnUnlock() throws {
        let store = try makeStore()
        // Forge a phase-1 header that carries the SE slot, with a matching manifest MAC.
        var legacy = store.header
        legacy.slots.append(.secureEnclave(keyData: Data([9]), wrappedKey: Data([8])))
        let headerData = try legacy.encoded()
        try headerData.write(to: dir.appendingPathComponent(VaultHeader.fileName))
        var m = store.manifest
        m.headerHash = ManifestFile.sha256(headerData)
        let keys = VaultKeys(vaultKey: try store.withVaultKey { $0 })
        try ManifestFile.encode(m, key: keys.manifest).write(to: dir.appendingPathComponent(Manifest.fileName))

        let reopened = try VaultStore.open(at: dir, deviceID: device)
        try reopened.unlock(password: pw)
        XCTAssertTrue(reopened.hasSecureEnclaveSlot)
        XCTAssertEqual(reopened.secureEnclaveSlot, .secureEnclave(keyData: Data([9]), wrappedKey: Data([8])))
        XCTAssertTrue(reopened.header.slots.allSatisfy(\.isPassword))
        // And the rewritten header still verifies on the next unlock.
        let again = try VaultStore.open(at: dir, deviceID: device)
        try again.unlock(password: pw)
        XCTAssertEqual(again.header.updatedAt, again.header.createdAt)
    }

    func testChangePasswordBumpsHeaderUpdatedAt() throws {
        let store = try makeStore()
        let before = store.header.updatedAt
        Thread.sleep(forTimeInterval: 0.002)
        try store.changePassword(old: pw, new: SecureBytes(utf8: "another"), kdfParams: cheap)
        XCTAssertGreaterThan(store.header.updatedAt, before)
    }
}
