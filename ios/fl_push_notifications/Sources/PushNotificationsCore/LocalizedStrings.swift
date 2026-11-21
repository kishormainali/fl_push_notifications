import Foundation

/// Resolves `title-loc-key` / `body-loc-key` style keys against the app's
/// `Localizable.strings`.
public enum LocalizedStrings {
  /// Returns the formatted string, or nil when the app has no entry for `key`.
  public static func resolve(
    key: String, args: [String], bundle: Bundle = .main
  ) -> String? {
    let missing = "\u{1}missing\u{1}"
    let format = bundle.localizedString(forKey: key, value: missing, table: nil)
    if format == missing { return nil }
    if args.isEmpty { return format }
    return String(format: format, arguments: args.map { $0 as CVarArg })
  }
}
