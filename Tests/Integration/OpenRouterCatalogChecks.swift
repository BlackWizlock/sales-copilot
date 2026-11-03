import Foundation

@main struct OpenRouterCatalogChecks {
    @MainActor static func main() async throws {
        let synthetic = Data(#"{"data":[{"id":"safe","name":"Safe","pricing":{"prompt":"0.000001","completion":"0.000002","request":"0"},"supported_parameters":["max_tokens"]},{"id":"overrides","name":"Overrides","pricing":{"prompt":"0.000001","completion":"0.000002","overrides":[{"prompt":"99"}]},"supported_parameters":["max_tokens"]},{"id":"null","name":"Null price","pricing":{"prompt":null,"completion":"0.000002"},"supported_parameters":["max_tokens"]},{"id":"bad"}]}"#.utf8)
        let models = try OpenRouterSandbox.decodeCatalog(synthetic)
        precondition(models.count == 1 && models.first?.id == "safe")
        print("PASS: unsupported override/null/malformed models fail closed individually; valid model survives")
        let (data,response) = try await URLSession.shared.data(from: URL(string: "https://openrouter.ai/api/v1/models")!)
        precondition((response as? HTTPURLResponse)?.statusCode == 200)
        let live = try OpenRouterSandbox.decodeCatalog(data)
        precondition(!live.isEmpty)
        let raw = try JSONSerialization.jsonObject(with: data) as! [String:Any]
        print("PASS: unauthenticated live catalog decoded with product parser: \(live.count) safely priced supported models / \((raw["data"] as? [Any])?.count ?? 0) catalog entries; no inference or API key used")
    }
}
