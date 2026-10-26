import Foundation

/// The Model Context Protocol (MCP) side of the assistant server: answers JSON-RPC
/// messages with Work Tracker's tools. Stateless, so any message can arrive on any
/// connection, also after the app restarted (for an update) between two of them.
@MainActor
final class MCPHandler {
    /// Newest first; a client asking for another version gets the newest.
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    static let instructions = """
        Work Tracker records working time against a Swiss (Zurich) work schedule. Dates are \
        YYYY-MM-DD and times HH:MM (24-hour), both in Zurich time; dates also accept today and \
        yesterday. A time entry lies within one day (its end may be 24:00) and can't overlap \
        another. Expected hours come from the work schedule, Zurich public holidays and \
        absences; balance = worked − expected, so a positive balance is overtime. Hours are \
        decimal (7.5 = 7h 30m). Call get_overview first for today's date, balances and the \
        timer. Changes save immediately and sync to the user's other Macs, and they can't be \
        undone in the app, so check with the user before deleting or replacing data.
        """

    let tools: AssistantTools

    init(tools: AssistantTools) { self.tools = tools }

    /// The response to a POSTed message (or batch), or nil when there's nothing to answer
    /// (notifications and responses).
    func handle(_ body: Data) -> Data? {
        guard let message = try? JSONSerialization.jsonObject(with: body) else {
            return encode(failure(-32700, "Parse error", id: NSNull()))
        }
        if let batch = message as? [Any] {
            guard !batch.isEmpty else { return encode(failure(-32600, "Invalid Request", id: NSNull())) }
            let responses = batch.compactMap { respond(to: $0) }
            return responses.isEmpty ? nil : encode(responses)
        }
        return respond(to: message).flatMap(encode)
    }

    private func respond(to message: Any) -> [String: Any]? {
        guard let message = message as? [String: Any], message["jsonrpc"] as? String == "2.0" else {
            return failure(-32600, "Invalid Request", id: NSNull())
        }
        // Responses to requests this server never sends, and notifications, get no answer.
        guard let method = message["method"] as? String, let id = message["id"], !(id is NSNull) else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            return success(id: id, [
                "protocolVersion": Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": [
                    "name": "work-tracker",
                    "title": "Work Tracker",
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
                ],
                "instructions": Self.instructions,
            ])
        case "ping":
            return success(id: id, [:])
        case "tools/list":
            return success(id: id, ["tools": AssistantTools.definitions.map(\.json)])
        case "tools/call":
            guard let name = params["name"] as? String, AssistantTools.definition(named: name) != nil else {
                return failure(-32602, "Unknown tool: \(params["name"] as? String ?? "")", id: id)
            }
            return success(id: id, call(name, ToolArguments(params["arguments"] as? [String: Any] ?? [:])))
        default:
            return failure(-32601, "Method not found: \(method)", id: id)
        }
    }

    /// A tool's result, or its error as a result the assistant can read and act on.
    private func call(_ name: String, _ arguments: ToolArguments) -> [String: Any] {
        func result(_ text: String, isError: Bool) -> [String: Any] {
            ["content": [["type": "text", "text": text]], "isError": isError]
        }
        do {
            let value = try tools.call(name, arguments)
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
                  let text = String(data: data, encoding: .utf8) else {
                return result("The result couldn't be encoded.", isError: true)
            }
            return result(text, isError: false)
        } catch let error as ToolError {
            return result(error.message, isError: true)
        } catch {
            return result(error.localizedDescription, isError: true)
        }
    }

    private func success(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func failure(_ code: Int, _ message: String, id: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message] as [String: Any]]
    }

    private func encode(_ value: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes])
    }
}
