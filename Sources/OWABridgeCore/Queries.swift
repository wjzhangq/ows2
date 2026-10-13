import Foundation

/// `GET /messages` 的参数校验。
public struct MessagesQuery: Equatable {
    public static let maxTop = 50

    public var folder: String
    public var top: Int
    public var unread: Bool
    public var debug: Bool

    public init(folder: String = "inbox", top: Int = 10, unread: Bool = false, debug: Bool = false) {
        self.folder = folder
        self.top = top
        self.unread = unread
        self.debug = debug
    }

    public static func parse(_ req: HTTPRequest) -> Result<MessagesQuery, APIError> {
        var q = MessagesQuery()
        if let folder = req.query["folder"]?.trimmingCharacters(in: .whitespaces), !folder.isEmpty {
            q.folder = folder
        }
        if let topString = req.query["top"] {
            guard let top = Int(topString), top >= 1 else {
                return .failure(.badRequest("top must be an integer between 1 and \(maxTop)"))
            }
            q.top = min(top, maxTop)
        }
        q.unread = req.boolQuery("unread")
        q.debug = req.boolQuery("debug")
        return .success(q)
    }

    public var jsArgs: [String: Any] {
        ["folder": folder, "top": top, "unread": unread, "debug": debug]
    }
}

/// `GET /messages/{id}` 的参数。
public struct MessageQuery: Equatable {
    public var id: String
    public var bodyType: String
    public var debug: Bool

    public static func parse(id: String?, _ req: HTTPRequest) -> Result<MessageQuery, APIError> {
        guard let id, !id.isEmpty else { return .failure(.badRequest("message id is required")) }
        let bodyType = (req.query["bodyType"] ?? "text").lowercased()
        guard bodyType == "text" || bodyType == "html" else {
            return .failure(.badRequest("bodyType must be text or html"))
        }
        return .success(MessageQuery(id: id, bodyType: bodyType, debug: req.boolQuery("debug")))
    }

    public var jsArgs: [String: Any] {
        ["id": id, "bodyType": bodyType, "debug": debug]
    }
}
