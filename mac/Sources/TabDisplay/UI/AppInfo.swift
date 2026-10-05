import Foundation

enum AppInfo {
    /// This app's version ("1.0.0"); the Android app is built from the same VERSION file.
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"

    /// Android versionCode for a version string, matching android/app/build.gradle.kts.
    static func versionCode(_ v: String) -> Int {
        let p = v.split(separator: ".").map { Int($0) ?? 0 } + [0, 0, 0]
        return p[0] * 10000 + p[1] * 100 + p[2]
    }

    /// Inverse of `versionCode`.
    static func versionName(code: Int) -> String { "\(code / 10000).\(code / 100 % 100).\(code % 100)" }

    /// -1, 0, 1 comparing dotted versions numerically.
    static func compare(_ a: String, _ b: String) -> Int {
        let x = versionCode(a), y = versionCode(b)
        return x < y ? -1 : x > y ? 1 : 0
    }
}
