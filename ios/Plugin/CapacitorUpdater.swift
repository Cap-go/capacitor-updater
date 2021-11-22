import Foundation
import SSZipArchive
import Just

extension FileManager {
    open func secureCopyItem(at srcURL: URL, to dstURL: URL) -> Bool {
        do {
            if FileManager.default.fileExists(atPath: dstURL.path) {
                try FileManager.default.removeItem(at: dstURL)
            }
            try FileManager.default.copyItem(at: srcURL, to: dstURL)
        } catch (let error) {
            print("Cannot copy item at \(srcURL) to \(dstURL): \(error)")
            return false
        }
        return true
    }
}

@objc public class CapacitorUpdater: NSObject {
    
    @objc private func randomString(length: Int) -> String {
        let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<length).map{ _ in letters.randomElement()! })
    }
    
    @objc public func updateApp(url: URL) -> Bool {
        print(url)
        let documentsUrl =  FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let destZip = documentsUrl.appendingPathComponent(randomString(length: 10))
        let dest = documentsUrl.appendingPathComponent(randomString(length: 10))
        let publicFolder = documentsUrl.appendingPathComponent("public")
        let r = Just.get(url)
        if r.ok {
            if (FileManager.default.createFile(atPath: destZip.path, contents: r.content, attributes: nil)) {
                print("File created successfully.", destZip.path)
                SSZipArchive.unzipFile(atPath: destZip.path, toDestination: dest.path)
                do {
                    let files = try FileManager.default.contentsOfDirectory(atPath: dest.path)
                    print(files)
                    for file in files {
                        let urlFile = URL.init(string: file)!
                        FileManager.default.secureCopyItem(at: urlFile, to: publicFolder)
                    }
                } catch {
                    print("Error getting zip files")
                    return false
                }
                return true
            } else {
                print("File not created.")
            }
        } else {
            print("Error downloading zip file", r.error)
        }
        return false
    }
}
