// Apple on-device models for code-index-lab.
//   embed    NLContextualEmbedding (Latin script, mean-pooled) for chunks and questions
//   rewrite  FoundationModels turns each question into an English keyword query
// Build: swiftc -O -parse-as-library apple/AppleLab.swift -o out/apple-lab
import Foundation
import FoundationModels
import NaturalLanguage

struct Chunk: Decodable { let path: String; let symbol: String; let text: String }
struct QFile: Decodable { let questions: [Q] }
struct Q: Decodable { let id: String; let q: String }

let lab = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let out = lab.appendingPathComponent("out")

func writeVecs(_ rows: [[Float]], _ name: String) throws {
  var d = Data()
  var n = UInt32(rows.count), dim = UInt32(rows.first?.count ?? 0)
  d.append(Data(bytes: &n, count: 4)); d.append(Data(bytes: &dim, count: 4))
  for r in rows { r.withUnsafeBufferPointer { d.append(Data(buffer: $0)) } }
  try d.write(to: out.appendingPathComponent(name))
}

func meanPool(_ m: NLContextualEmbedding, _ text: String) throws -> [Float] {
  let r = try m.embeddingResult(for: text, language: nil)
  var sum = [Double](repeating: 0, count: m.dimension)
  var n = 0.0
  r.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { v, _ in
    for i in 0..<v.count { sum[i] += v[i] }
    n += 1
    return true
  }
  return sum.map { Float($0 / max(n, 1)) }
}

@main struct Main {
  static func main() async throws {
    let mode = CommandLine.arguments.dropFirst().first ?? ""
    let qs = try JSONDecoder().decode(QFile.self, from: Data(contentsOf: lab.appendingPathComponent("questions.json"))).questions
    switch mode {
    case "embed":
      guard let m = NLContextualEmbedding(script: .latin) else { fatalError("no latin contextual embedding") }
      if !m.hasAvailableAssets {
        let r = try await m.requestAssets()
        print("assets:", r == .available ? "available" : "not available")
      }
      try m.load()
      print("model", m.modelIdentifier, "dim", m.dimension, "max tokens", m.maximumSequenceLength)
      let chunks = try JSONDecoder().decode([Chunk].self, from: Data(contentsOf: out.appendingPathComponent("chunks.json")))
      let t0 = Date()
      var rows: [[Float]] = []
      for c in chunks { rows.append(try meanPool(m, "\(c.path) \(c.symbol)\n\(c.text)")) }
      let el = Date().timeIntervalSince(t0)
      try writeVecs(rows, "emb-apple.bin")
      print(String(format: "apple: %d chunks in %.1fs (%.1f chunks/s)", rows.count, el, Double(rows.count) / el))
      var qrows: [[Float]] = [], ms: [Double] = []
      for q in qs {
        let t = Date()
        qrows.append(try meanPool(m, q.q))
        ms.append(Date().timeIntervalSince(t) * 1000)
      }
      try writeVecs(qrows, "qemb-apple.bin")
      try JSONEncoder().encode(ms).write(to: out.appendingPathComponent("qemb-apple-ms.json"))
    case "rewrite":
      let model = SystemLanguageModel.default
      guard case .available = model.availability else { fatalError("Apple model unavailable: \(model.availability)") }
      let instructions = """
        You help search a codebase. The app is Muya: a macOS desktop app (Tauri v2 Rust backend, \
        React + TypeScript frontend) that runs Claude Code sessions in terminal tabs, with SSH and \
        CyberArk PSMP connections, an encrypted credential vault, an MCP server for agents, a file \
        tree and editor, settings and auto-updates.
        Turn the developer's question (it may be in Turkish) into ONE line of English search \
        keywords: 6 to 12 words, including likely code identifiers in snake_case or camelCase. \
        Output only the keywords.
        """
      var res: [String: String] = [:]
      var ms: [Double] = []
      for q in qs {
        let s = LanguageModelSession(instructions: instructions)
        let t = Date()
        let r = try await s.respond(to: q.q)
        ms.append(Date().timeIntervalSince(t) * 1000)
        res[q.id] = r.content.replacingOccurrences(of: "\n", with: " ")
        print(q.id, "|", q.q, "=>", res[q.id]!)
      }
      try JSONEncoder().encode(res).write(to: out.appendingPathComponent("rewrite-apple.json"))
      let sorted = ms.sorted()
      print(String(format: "rewrite latency p50 %.0f ms, p95 %.0f ms", sorted[sorted.count / 2], sorted[Int(Double(sorted.count - 1) * 0.95)]))
    default:
      print("usage: apple-lab embed | rewrite")
    }
  }
}
