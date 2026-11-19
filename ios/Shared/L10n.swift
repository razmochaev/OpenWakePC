import Foundation

/// Lightweight wrapper for NSLocalizedString across the app and widget extension.
public enum L10n {
    public static func tr(_ key: String) -> String {
        NSLocalizedString(key, tableName: nil, bundle: .main, value: key, comment: "")
    }

    public static func tr(_ key: String, _ args: CVarArg...) -> String {
        let format = NSLocalizedString(key, tableName: nil, bundle: .main, value: key, comment: "")
        return String(format: format, locale: .current, arguments: args)
    }
}
