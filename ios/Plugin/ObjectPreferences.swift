//
//  UserDefaultsExtension.swift
//  UserDefaultsExtension
//
//  Created by Ankit Bhana on 15/08/20.
//  Copyright © 2020 Ankit Bhana. All rights reserved.
//
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

//
//// MARK: - Methods
//public extension UserDefaults {
//    /// SwifterSwift: get object from UserDefaults by using subscript.
//    ///
//    /// - Parameter key: key in the current user's defaults database.
//    subscript(key: String) -> Any? {
//        get {
//            return object(forKey: key)
//        }
//        set {
//            set(newValue, forKey: key)
//        }
//    }
//
//    /// SwifterSwift: Float from UserDefaults.
//    ///
//    /// - Parameter key: key to find float for.
//    /// - Returns: Float object for key (if exists).
//    func float(forKey key: String) -> Float? {
//        return object(forKey: key) as? Float
//    }
//
//    /// SwifterSwift: Date from UserDefaults.
//    ///
//    /// - Parameter key: key to find date for.
//    /// - Returns: Date object for key (if exists).
//    func date(forKey key: String) -> Date? {
//        return object(forKey: key) as? Date
//    }
//
//    /// SwifterSwift: Retrieves a Codable object from UserDefaults.
//    ///
//    /// - Parameters:
//    ///   - type: Class that conforms to the Codable protocol.
//    ///   - key: Identifier of the object.
//    ///   - decoder: Custom JSONDecoder instance. Defaults to `JSONDecoder()`.
//    /// - Returns: Codable object for key (if exists).
//    func object<T: Codable>(_ type: T.Type, with key: String, usingDecoder decoder: JSONDecoder = JSONDecoder()) -> T? {
//        guard let data = value(forKey: key) as? Data else { return nil }
//        return try? decoder.decode(type.self, from: data)
//    }
//
//    /// SwifterSwift: Allows storing of Codable objects to UserDefaults.
//    ///
//    /// - Parameters:
//    ///   - object: Codable object to store.
//    ///   - key: Identifier of the object.
//    ///   - encoder: Custom JSONEncoder instance. Defaults to `JSONEncoder()`.
//    func set<T: Codable>(object: T, forKey key: String, usingEncoder encoder: JSONEncoder = JSONEncoder()) {
//        let data = try? encoder.encode(object)
//        set(data, forKey: key)
//    }
//}
//
