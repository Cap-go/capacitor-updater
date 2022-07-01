import Foundation

protocol ObjectSavable {
    func setObj<Object>(_ object: Object, forKey: String) throws where Object: Encodable
    func getObj<Object>(forKey: String, castTo type: Object.Type) throws -> Object where Object: Decodable
}

enum ObjectSavableError: String, LocalizedError {
    case unableToEncode = "Unable to encode object into data"
    case noValue = "No data object found for the given key"
    case unableToDecode = "Unable to decode object into given type"

    var errorDescription: String? {
        rawValue
    }
}

extension UserDefaults: ObjectSavable {
    func setObj<Object>(_ object: Object, forKey: String) throws where Object: Encodable {
        let encoder = JSONEncoder()
        do {
            let data = try encoder.encode(object)
            set(data, forKey: forKey)
        } catch {
            throw ObjectSavableError.unableToEncode
        }
    }

    func getObj<Object>(forKey: String, castTo type: Object.Type) throws -> Object where Object: Decodable {
        print("forKey", forKey)
        guard let data = data(forKey: forKey) else { throw ObjectSavableError.noValue }
        print("data", data)
        let decoder = JSONDecoder()
        do {
            let object = try decoder.decode(type, from: data)
            return object
        } catch {
            throw ObjectSavableError.unableToDecode
        }
    }
}