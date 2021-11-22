import Foundation
import SSZipArchive
import Just

extension URL {
    var isDirectory: Bool {
       (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}

@objc public class CapacitorUpdater: NSObject {
    
    @objc private func randomString(length: Int) -> String {
        let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<length).map{ _ in letters.randomElement()! })
    }
    
    @objc public func updateApp(url: URL) -> URL? {
        print(url)
        let documentsUrl =  FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let destZip = documentsUrl.appendingPathComponent(randomString(length: 10))
        let dest = documentsUrl.appendingPathComponent(randomString(length: 10))
        let index = dest.appendingPathComponent("index.html")
        let r = Just.get(url)
        if r.ok {
            if (FileManager.default.createFile(atPath: destZip.path, contents: r.content, attributes: nil)) {
                print("File created successfully.", destZip.path)
                SSZipArchive.unzipFile(atPath: destZip.path, toDestination: dest.path)
                do {
                    let files = try FileManager.default.contentsOfDirectory(atPath: dest.path)
                    if (files.count == 1 && dest.appendingPathComponent(files[0]).isDirectory && !FileManager.default.fileExists(atPath: index.path)) {
                        return dest.appendingPathComponent(files[0])
                    } else if (FileManager.default.fileExists(atPath: index.path)) {
                        return dest
                    }
                } catch {
                    print("FILE NOT AVAILABLE" + index.path)
                    return nil
                }
                do {
                    try FileManager.default.removeItem(atPath: dest.path)
                } catch {
                    print("File not removed.")
                    return nil
                }
                return dest
            } else {
                print("File not created.")
            }
        } else {
            print("Error downloading zip file", r.error)
        }
        return nil
    }
}
