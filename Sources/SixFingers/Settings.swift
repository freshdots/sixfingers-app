import Foundation
import Security

struct ProviderInfo {
    let label: String
    let envKey: String
    let keyUrl: String
}

let providers: [String: ProviderInfo] = [
    "fal.ai": ProviderInfo(label: "fal.ai", envKey: "FAL_KEY", keyUrl: "fal.ai/dashboard/keys"),
    "openai": ProviderInfo(label: "OpenAI", envKey: "OPENAI_API_KEY", keyUrl: "platform.openai.com/api-keys"),
]

let builtInStyles: [(String, String)] = [
    ("Default", "simple line drawing, black ink on pure white background, no border, no circle, no frame, no background elements, just the subject floating on white, clean outlines, minimal shading, no drop shadow"),
    ("Picasso", "cubist style, black ink on white background, fragmented geometric shapes, multiple perspectives at once, abstract and angular, bold dark outlines, deconstructed form, like a Picasso sketch"),
    ("Van Gogh", "expressive swirling lines, black ink on white background, dynamic flowing strokes, heavy texture, emotional and energetic, thick impasto-style linework, like a Van Gogh pen sketch"),
    ("Monet", "soft impressionist style, black ink on white background, loose dappled strokes, dreamy and slightly blurred edges, light airy feeling, like a Monet study done in ink"),
    ("Da Vinci", "renaissance study sketch, black ink on white background, precise anatomical detail, cross-hatching for shading, scientific observation style, like a Leonardo da Vinci notebook sketch"),
    ("Banksy", "simple Banksy-style stencil, black on white background, bold silhouettes, minimal detail, few large shapes, no fine detail, no texture, clean stencil cutout look"),
    ("Scott Adams", "simple office comic strip style, black ink on white background, minimal detail, round heads, basic geometric bodies, deadpan expression, like a Dilbert comic panel"),
    ("Osamu Tezuka", "manga style, black ink on white background, big expressive eyes, dynamic poses, speed lines, clean confident linework, like an Osamu Tezuka manga panel"),
]

// Legacy compat
let styles: [String: String] = {
    var d: [String: String] = [:]
    for (n, p) in builtInStyles { d[n] = p }
    return d
}()

struct AppSettings: Codable {
    var style: String = "Default" // legacy single style
    var enabledStyles: [String] = ["Default"] // new: multiple enabled styles
    var narratorEnabled: Bool = true
    var countdown: Int = 5
    var drawSpeed: String = "normal"
    var customStyles: [String: String] = [:]
    var provider: String = "fal.ai"
    var keys: [String: String] = [:]
}

struct RecentEntry: Codable {
    let prompt: String
    let image: String
}

class SettingsManager {
    static let shared = SettingsManager()

    private let appSupport: URL
    private let settingsFile: URL
    private let recentsFile: URL
    let imagesDir: URL
    private let keychain = APIKeychain()

    init() {
        appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Draw")
        settingsFile = appSupport.appendingPathComponent("settings.json")
        recentsFile = appSupport.appendingPathComponent("recents.json")
        imagesDir = appSupport.appendingPathComponent("images")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)

        // Migrate legacy provider.json
        let providerFile = appSupport.appendingPathComponent("provider.json")
        if FileManager.default.fileExists(atPath: providerFile.path) {
            if let data = try? Data(contentsOf: providerFile),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                var settings = load()
                if let p = json["provider"] as? String { settings.provider = p }
                if let k = json["keys"] as? [String: String] { settings.keys = k }
                save(settings)
                try? FileManager.default.removeItem(at: providerFile)
            }
        }

        migrateLegacyKeysToKeychain()
        keychain.migrateLegacyPerProviderItems()
        keychain.purgeLegacyKeyClassItems()
        applyEnv()
    }

    func load() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsFile),
              var settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        if styles[settings.style] == nil && settings.customStyles[settings.style] == nil {
            settings.style = "Dürer"
        }
        // Gemini support removed — direct users of a retired provider to fal.ai
        if settings.provider == "gemini" {
            settings.provider = "fal.ai"
        }
        return settings
    }

    func save(_ settings: AppSettings) {
        var sanitized = settings
        if !sanitized.keys.isEmpty {
            migrateKeysToKeychain(sanitized.keys)
            sanitized.keys = [:]
        }

        if let data = try? JSONEncoder().encode(sanitized) {
            try? data.write(to: settingsFile)
        }
        applyEnv()
    }

    func applyEnv() {
        for prov in providers.keys {
            let key = keychain.read(provider: prov)
            if let info = providers[prov], !key.isEmpty {
                setenv(info.envKey, key, 1)
            }
        }
    }

    func getApiKey(_ provider: String? = nil) -> String? {
        let s = load()
        let p = provider ?? s.provider
        let key = keychain.read(provider: p)
        return key.isEmpty ? nil : key
    }

    func setApiKey(_ provider: String, key: String) {
        if key.isEmpty {
            keychain.delete(provider: provider)
        } else {
            keychain.upsert(provider: provider, key: key)
        }
        applyEnv()
    }

    private func migrateLegacyKeysToKeychain() {
        var settings = load()
        if settings.keys.isEmpty { return }
        migrateKeysToKeychain(settings.keys)
        settings.keys = [:]
        if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: settingsFile)
        }
    }

    private func migrateKeysToKeychain(_ keys: [String: String]) {
        for (provider, key) in keys where !key.isEmpty {
            keychain.upsert(provider: provider, key: key)
        }
    }

    func getAllStyles() -> [String: String] {
        let s = load()
        var all = styles
        for (name, prompt) in s.customStyles {
            all[name] = prompt
        }
        return all
    }

    func pickRandomStyle() -> (name: String, prompt: String) {
        let s = load()
        let all = getAllStyles()
        let enabled = s.enabledStyles.filter { all[$0] != nil }
        let pool = enabled.isEmpty ? ["Default"] : enabled
        let name = pool.randomElement()!
        return (name, all[name] ?? styles["Default"]!)
    }

    // Recents
    func loadRecents() -> [RecentEntry] {
        guard let data = try? Data(contentsOf: recentsFile),
              let recents = try? JSONDecoder().decode([RecentEntry].self, from: data) else {
            return []
        }
        return recents
    }

    func addRecent(_ prompt: String, _ imagePath: String) {
        var recents = loadRecents().filter { $0.prompt != prompt }
        recents.insert(RecentEntry(prompt: prompt, image: imagePath), at: 0)
        if recents.count > 10 { recents = Array(recents.prefix(10)) }
        if let data = try? JSONEncoder().encode(recents) {
            try? data.write(to: recentsFile)
        }
    }

    func clearRecents() {
        try? "[]".data(using: .utf8)?.write(to: recentsFile)
    }
}

private final class APIKeychain {
    private let service = "com.dotfunlabs.sixfingers.api-keys"
    private let account = "all"

    // Cached after the first successful read so subsequent reads (e.g.
    // switching provider tabs in Settings) never re-query the keychain.
    // macOS evaluates the ACL on every SecItemCopyMatching call, so without
    // this cache "Always Allow" still has to be re-evaluated on each tab
    // change.
    private var cache: [String: String]?

    func read(provider: String) -> String {
        return loadAll()[provider] ?? ""
    }

    func upsert(provider: String, key: String) {
        var all = loadAll()
        all[provider] = key
        writeAll(all)
    }

    func delete(provider: String) {
        var all = loadAll()
        all.removeValue(forKey: provider)
        writeAll(all)
    }

    // Older builds stored each provider's API key as its own
    // `kSecClassGenericPassword` item (one per `kSecAttrAccount`). macOS
    // evaluates ACLs per item, so the keychain prompt fired again every time
    // the user switched provider tabs. We now collapse everything into a
    // single item; this pulls any legacy per-provider items into the
    // consolidated blob and deletes the originals.
    func migrateLegacyPerProviderItems() {
        var merged = loadAll()
        var moved = false
        for legacy in providers.keys {
            let readQuery: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: legacy,
                kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(readQuery as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data,
                  let value = String(data: data, encoding: .utf8),
                  !value.isEmpty else { continue }

            if merged[legacy] == nil { merged[legacy] = value }
            moved = true

            let deleteQuery: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: legacy,
            ]
            SecItemDelete(deleteQuery as CFDictionary)
        }
        if moved { writeAll(merged) }
    }

    // macOS evaluates keychain ACLs per item class. Older builds shipped a
    // `kSecClassKey` item under the same logical identity as our generic
    // password store, which caused a second "wants to access key …" prompt on
    // every (re)install in addition to the generic-password prompt. We never
    // read those items — the canonical API key store is
    // `kSecClassGenericPassword` — so best-effort delete on launch under both
    // the label and the application-tag attribute (the two places legacy
    // builds stashed the service identifier on key-class items).
    func purgeLegacyKeyClassItems() {
        let labelQuery: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrLabel: service,
        ]
        SecItemDelete(labelQuery as CFDictionary)

        if let tagData = service.data(using: .utf8) {
            let tagQuery: [CFString: Any] = [
                kSecClass: kSecClassKey,
                kSecAttrApplicationTag: tagData,
            ]
            SecItemDelete(tagQuery as CFDictionary)
        }
    }

    private func loadAll() -> [String: String] {
        if let cache = cache { return cache }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            cache = [:]
            return [:]
        }
        cache = decoded
        return decoded
    }

    private func writeAll(_ keys: [String: String]) {
        cache = keys
        let data = (try? JSONEncoder().encode(keys)) ?? Data("{}".utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }

        var item = query
        item[kSecValueData] = data
        SecItemAdd(item as CFDictionary, nil)
    }
}
