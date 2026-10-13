import Foundation

public enum DebugEval {
    /// 单行且不含 `return` / `;` 的代码视为表达式,自动加 `return`;否则原样作为函数体。
    public static func functionBody(for code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSingleLine = !trimmed.contains("\n")
        let hasReturn = trimmed.range(of: #"\breturn\b"#, options: .regularExpression) != nil
        if isSingleLine && !hasReturn && !trimmed.contains(";") {
            return "return (\(trimmed));"
        }
        return trimmed
    }
}
