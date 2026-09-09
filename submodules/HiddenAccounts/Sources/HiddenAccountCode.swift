import Foundation
import Security
import TelegramCore
import CryptoUtils
import TelegramUIPreferences

public enum HiddenAccountCodeValidation {
    case valid
    case malformed(requiredType: HiddenAccountCodeType)
    case duplicate
    case matchesAppPasscode
}

public enum HiddenAccountCode {
    private static let saltLength = 16
    public static let minimumAlphanumericLength = 4

    public static func requiredCodeType(forAppPasscode data: PostboxAccessChallengeData) -> HiddenAccountCodeType {
        switch data {
        case .none:
            return .digits4
        case let .numericalPassword(value):
            return value.count == 6 ? .digits6 : .digits4
        case .plaintextPassword:
            return .alphanumeric
        }
    }

    public static func isWellFormed(_ code: String, type: HiddenAccountCodeType) -> Bool {
        if let requiredLength = type.requiredLength {
            return code.count == requiredLength && isDigits(code)
        }
        return code.count >= minimumAlphanumericLength
    }

    public static func couldBeNumericCode(_ code: String) -> Bool {
        return (code.count == 4 || code.count == 6) && isDigits(code)
    }

    public static func makeEntry(accountId: Int64, code: String, type: HiddenAccountCodeType) -> HiddenAccountEntry? {
        guard let salt = generateSalt() else {
            return nil
        }
        return HiddenAccountEntry(accountId: accountId, salt: salt, hash: hash(code: code, salt: salt), codeType: type)
    }

    public static func verify(code: String, entry: HiddenAccountEntry) -> Bool {
        guard !entry.salt.isEmpty, !entry.hash.isEmpty else {
            return false
        }
        return constantTimeEquals(hash(code: code, salt: entry.salt), entry.hash)
    }

    private static func isDigits(_ code: String) -> Bool {
        return !code.isEmpty && code.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func generateSalt() -> Data? {
        var salt = Data(count: saltLength)
        let status = salt.withUnsafeMutableBytes { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(kSecRandomDefault, saltLength, baseAddress)
        }
        return status == errSecSuccess ? salt : nil
    }

    private static func hash(code: String, salt: Data) -> Data {
        var bytes = Data()
        bytes.append(salt)
        bytes.append(Data(code.utf8))
        bytes.append(salt)
        return bytes.withUnsafeBytes { buffer -> Data in
            guard let baseAddress = buffer.baseAddress else {
                return Data()
            }
            return CryptoSHA256(baseAddress, Int32(buffer.count))
        }
    }

    private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }
        var difference: UInt8 = 0
        for index in 0 ..< lhs.count {
            difference |= lhs[lhs.startIndex + index] ^ rhs[rhs.startIndex + index]
        }
        return difference == 0
    }
}
