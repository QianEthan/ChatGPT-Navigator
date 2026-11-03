import CoreFoundation
import Foundation

struct ConversationIdentity: Equatable, CustomStringConvertible {
    let localID: String
    let remoteID: String?

    var description: String {
        if let remoteID {
            return "local=\(localID) remote=\(remoteID)"
        }
        return "local=\(localID)"
    }

    static func selectedConversation() -> ConversationIdentity? {
        let applicationID = AccessibilityClient.classicBundleIdentifier as CFString
        CFPreferencesAppSynchronize(applicationID)

        guard let storedValue = CFPreferencesCopyAppValue(
            "lastSelectedConversation" as CFString,
            applicationID
        ) else {
            return nil
        }

        guard let object = jsonObject(from: storedValue),
              let localID = string(in: object, path: ["localID"]),
              !localID.isEmpty else {
            return nil
        }

        let remoteID = string(
            in: object,
            path: ["conversationID", "remote", "_0"]
        ) ?? string(in: object, path: ["conversationID", "remote"])
            ?? string(in: object, path: ["conversationID"])

        return ConversationIdentity(localID: localID, remoteID: remoteID)
    }

    private static func jsonObject(from value: Any) -> Any? {
        if let dictionary = value as? [String: Any] {
            return dictionary
        }
        if let dictionary = value as? NSDictionary {
            return dictionary
        }

        let data: Data?
        if let value = value as? Data {
            data = value
        } else if let value = value as? String {
            data = value.data(using: .utf8)
        } else {
            data = nil
        }

        guard let data else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func string(in object: Any, path: [String]) -> String? {
        var current: Any = object

        for component in path {
            if let dictionary = current as? [String: Any],
               let next = dictionary[component] {
                current = next
            } else if let dictionary = current as? NSDictionary,
                      let next = dictionary[component] {
                current = next
            } else {
                return nil
            }
        }

        if let string = current as? String {
            return string
        }
        if let uuid = current as? UUID {
            return uuid.uuidString
        }
        return nil
    }
}
