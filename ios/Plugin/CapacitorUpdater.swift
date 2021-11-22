import Foundation
import SSZipArchive
import Just

extension URL {
    var isDirectory: Bool {
       (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}

@objc public class CapacitorUpdater: NSObject {
    
    private var lastPath = ""

    @objc private func randomString(length: Int) -> String {
        let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<length).map{ _ in letters.randomElement()! })
    }
    
    @objc public func download(url: URL) -> String? {
        print("URL " + url.path)
        let documentsUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let destZip = documentsUrl.appendingPathComponent(randomString(length: 10))
        let version = randomString(length: 10)
        let dest = documentsUrl.appendingPathComponent("versions").appendingPathComponent(version)
        let r = Just.get(url)
        if r.ok {
            if (FileManager.default.createFile(atPath: destZip.path, contents: r.content, attributes: nil)) {
                print("File created successfully.", destZip.path)
                SSZipArchive.unzipFile(atPath: destZip.path, toDestination: dest.path)
                do {
                    try FileManager.default.removeItem(atPath: destZip.path)
                } catch {
                    print("File not removed.")
                    return nil
                }
                return version
            } else {
                print("File not created.")
            }
        } else {
            print("Error downloading zip file", r.error)
        }
        return nil
    }

    @objc public func list() -> [String] {
        let documentsUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dest = documentsUrl.appendingPathComponent("versions")
        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: dest.path)
            return files
        } catch {
            print("NO version available" + dest.path)
            return []
        } 
    }
    
    @objc public func delete(version: String) -> Bool {
        let documentsUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dest = documentsUrl.appendingPathComponent("versions").appendingPathComponent(version)
        do {
            try FileManager.default.removeItem(atPath: dest.path)
        } catch {
            print("File not removed.")
            return false
        }
        return true
    }

    @objc public func set(version: String) -> Bool {
        let documentsUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dest = documentsUrl.appendingPathComponent("versions").appendingPathComponent(version)
        let index = dest.appendingPathComponent("index.html")
        if (dest.isDirectory) {
            do {
                let files = try FileManager.default.contentsOfDirectory(atPath: dest.path)
                if (files.count == 1 && dest.appendingPathComponent(files[0]).isDirectory && !FileManager.default.fileExists(atPath: index.path)) {
                    lastPath = dest.appendingPathComponent(files[0]).path
                } else {
                    lastPath = dest.path
                }
            } catch {
                print("FILE NOT AVAILABLE" + dest.path)
                return false
            }
            return true
        }
        return false
    }
    @objc public func getLastPath() -> String {
        return lastPath
    }
}
