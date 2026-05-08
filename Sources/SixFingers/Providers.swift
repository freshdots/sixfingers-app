import Foundation

let globalRules = "Do not include any text, words, or letters in the image unless explicitly asked for. No border, no frame, no box around the image."

func pickAspect(_ aspect: Double?) -> String {
    guard let a = aspect else { return "square" }
    if a > 1.3 { return "landscape" }
    if a < 0.77 { return "portrait" }
    return "square"
}

func saveGeneratedImage(_ data: Data, prefix: String, prompt: String) -> String {
    let mgr = SettingsManager.shared
    let slug = prompt.replacingOccurrences(of: "[^a-zA-Z0-9 ]", with: "", options: .regularExpression)
        .prefix(40).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
    let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: "[-:T]", with: "", options: .regularExpression).prefix(15)
    let path = mgr.imagesDir.appendingPathComponent("\(prefix)\(slug)_\(ts).png").path
    try? data.write(to: URL(fileURLWithPath: path))
    return path
}

// MARK: - Image Generation

func generateImage(prompt: String, style: String, aspect: Double? = nil) async throws -> String {
    let s = SettingsManager.shared.load()
    guard let key = SettingsManager.shared.getApiKey() else { throw NSError(domain: "", code: 1, userInfo: [NSLocalizedDescriptionKey: "No API key"]) }

    let fullPrompt = "\(prompt). Style: \(style). \(globalRules)"
    let shape = pickAspect(aspect)

    switch s.provider {
    case "fal.ai":
        return try await falGenerate(prompt: fullPrompt, rawPrompt: prompt, shape: shape, key: key)
    case "openai":
        return try await openaiGenerate(prompt: fullPrompt, rawPrompt: prompt, shape: shape, key: key)
    case "gemini":
        return try await geminiGenerate(prompt: fullPrompt, rawPrompt: prompt, key: key)
    default:
        throw NSError(domain: "", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown provider"])
    }
}

private func falGenerate(prompt: String, rawPrompt: String, shape: String, key: String) async throws -> String {
    let falSizes = ["square": "square", "landscape": "landscape_4_3", "portrait": "portrait_4_3"]
    let body: [String: Any] = ["prompt": prompt, "image_size": falSizes[shape] ?? "square"]
    let data = try JSONSerialization.data(withJSONObject: body)

    var req = URLRequest(url: URL(string: "https://fal.run/fal-ai/nano-banana")!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
    req.httpBody = data

    let (resData, _) = try await URLSession.shared.data(for: req)
    let json = try JSONSerialization.jsonObject(with: resData) as? [String: Any]
    guard let images = json?["images"] as? [[String: Any]],
          let url = images.first?["url"] as? String else {
        throw NSError(domain: "", code: 3, userInfo: [NSLocalizedDescriptionKey: "No image returned"])
    }
    let (imgData, _) = try await URLSession.shared.data(from: URL(string: url)!)
    return saveGeneratedImage(imgData, prefix: "", prompt: rawPrompt)
}

private func openaiGenerate(prompt: String, rawPrompt: String, shape: String, key: String) async throws -> String {
    let sizes = ["square": "1024x1024", "landscape": "1536x1024", "portrait": "1024x1536"]
    let body: [String: Any] = ["model": "gpt-image-1", "prompt": prompt, "size": sizes[shape] ?? "1024x1024", "n": 1]
    let data = try JSONSerialization.data(withJSONObject: body)

    var req = URLRequest(url: URL(string: "https://api.openai.com/v1/images/generations")!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    req.httpBody = data

    let (resData, _) = try await URLSession.shared.data(for: req)
    let json = try JSONSerialization.jsonObject(with: resData) as? [String: Any]
    guard let results = json?["data"] as? [[String: Any]], let first = results.first else {
        throw NSError(domain: "", code: 3, userInfo: [NSLocalizedDescriptionKey: "No image returned"])
    }

    if let b64 = first["b64_json"] as? String, let imgData = Data(base64Encoded: b64) {
        return saveGeneratedImage(imgData, prefix: "", prompt: rawPrompt)
    }
    if let url = first["url"] as? String {
        let (imgData, _) = try await URLSession.shared.data(from: URL(string: url)!)
        return saveGeneratedImage(imgData, prefix: "", prompt: rawPrompt)
    }
    throw NSError(domain: "", code: 3, userInfo: [NSLocalizedDescriptionKey: "No image returned"])
}

private func geminiGenerate(prompt: String, rawPrompt: String, key: String) async throws -> String {
    let body: [String: Any] = [
        "contents": [["parts": [["text": prompt]]]],
        "generationConfig": ["responseModalities": ["IMAGE"]]
    ]
    let data = try JSONSerialization.data(withJSONObject: body)

    var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash-exp:generateContent?key=\(key)")!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = data

    let (resData, _) = try await URLSession.shared.data(for: req)
    let json = try JSONSerialization.jsonObject(with: resData) as? [String: Any]

    if let candidates = json?["candidates"] as? [[String: Any]],
       let content = candidates.first?["content"] as? [String: Any],
       let parts = content["parts"] as? [[String: Any]] {
        for part in parts {
            if let inlineData = part["inlineData"] as? [String: Any],
               let b64 = inlineData["data"] as? String,
               let imgData = Data(base64Encoded: b64) {
                return saveGeneratedImage(imgData, prefix: "", prompt: rawPrompt)
            }
        }
    }
    throw NSError(domain: "", code: 3, userInfo: [NSLocalizedDescriptionKey: "No image returned"])
}

// MARK: - TTS

func speakText(_ text: String) async -> String? {
    let s = SettingsManager.shared.load()
    let key = SettingsManager.shared.getApiKey()

    if s.provider == "fal.ai", let key = key {
        if let path = try? await falTTS(text: text, key: key) { return path }
    }
    if s.provider == "openai", let key = key {
        if let path = try? await openaiTTS(text: text, key: key) { return path }
    }

    // No macOS say fallback — use bundled audio or stay silent
    return nil
}

private func falTTS(text: String, key: String) async throws -> String {
    let body: [String: Any] = ["text": text, "voice_id": "male-qn-qingse"]
    let data = try JSONSerialization.data(withJSONObject: body)

    var req = URLRequest(url: URL(string: "https://fal.run/fal-ai/minimax/speech-02-hd")!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
    req.httpBody = data

    let (resData, _) = try await URLSession.shared.data(for: req)
    let json = try JSONSerialization.jsonObject(with: resData) as? [String: Any]
    guard let audio = json?["audio"] as? [String: Any], let url = audio["url"] as? String else { throw NSError(domain: "", code: 4) }
    let (audioData, _) = try await URLSession.shared.data(from: URL(string: url)!)
    let tmp = NSTemporaryDirectory() + "sf_tts_\(Int(Date().timeIntervalSince1970)).mp3"
    try audioData.write(to: URL(fileURLWithPath: tmp))
    return tmp
}

private func openaiTTS(text: String, key: String) async throws -> String {
    let body: [String: Any] = ["model": "tts-1", "voice": "nova", "input": text]
    let data = try JSONSerialization.data(withJSONObject: body)

    var req = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    req.httpBody = data

    let (resData, _) = try await URLSession.shared.data(for: req)
    let tmp = NSTemporaryDirectory() + "sf_tts_\(Int(Date().timeIntervalSince1970)).mp3"
    try resData.write(to: URL(fileURLWithPath: tmp))
    return tmp
}
