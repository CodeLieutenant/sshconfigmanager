import Foundation

@testable import SSHConfigMacUI

extension AppDatabase {
    static func testDatabase(at url: URL) -> AppDatabase {
        do {
            return try AppDatabase(url: url)
        } catch {
            fatalError("cannot open test database at \(url.path): \(error)")
        }
    }
}
