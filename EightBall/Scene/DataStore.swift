import Foundation
import UIKit

/// Access to the files in the app bundle's `Data` folder (models, textures, skins, art) exported by tools/export_ios_data.py.
/// All paths are relative to `Data/`, e.g. `DataStore.image("tex/avatar_you.png")`.
enum DataStore {
    static let root: URL = {
        let base: URL = Bundle.main.resourceURL ?? URL(fileURLWithPath: Bundle.main.bundlePath)
        return base.appendingPathComponent("Data", isDirectory: true)
    }()

    static let audioRoot: URL = {
        let base: URL = Bundle.main.resourceURL ?? URL(fileURLWithPath: Bundle.main.bundlePath)
        return base.appendingPathComponent("Audio", isDirectory: true)
    }()

    private static let imageCache = NSCache<NSString, UIImage>()

    static func url(_ path: String) -> URL {
        return root.appendingPathComponent(path)
    }

    static func exists(_ path: String) -> Bool {
        return FileManager.default.fileExists(atPath: url(path).path)
    }

    /// Whole file, memory mapped when possible (the animation frames are 37 MB).
    static func data(_ path: String) -> Data? {
        return try? Data(contentsOf: url(path), options: .mappedIfSafe)
    }

    /// Parsed JSON (dictionary or array).
    static func json(_ path: String) -> Any? {
        guard let d = data(path) else { return nil }
        return try? JSONSerialization.jsonObject(with: d, options: [])
    }

    /// Image from the Data folder (cached); nil when the file is missing.
    static func image(_ path: String) -> UIImage? {
        let key = path as NSString
        if let cached = imageCache.object(forKey: key) {
            return cached
        }
        guard let img = UIImage(contentsOfFile: url(path).path) else { return nil }
        imageCache.setObject(img, forKey: key)
        return img
    }
}
