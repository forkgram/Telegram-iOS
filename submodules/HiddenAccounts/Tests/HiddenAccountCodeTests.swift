import XCTest
import TelegramCore
import TelegramUIPreferences
import HiddenAccounts

final class HiddenAccountCodeTests: XCTestCase {
    // MARK: - Required code type follows the app passcode

    func testRequiredCodeTypeForFourDigitPasscode() {
        XCTAssertEqual(HiddenAccountCode.requiredCodeType(forAppPasscode: .numericalPassword(value: "1234")), .digits4)
    }

    func testRequiredCodeTypeForSixDigitPasscode() {
        XCTAssertEqual(HiddenAccountCode.requiredCodeType(forAppPasscode: .numericalPassword(value: "123456")), .digits6)
    }

    func testRequiredCodeTypeForAlphanumericPasscode() {
        XCTAssertEqual(HiddenAccountCode.requiredCodeType(forAppPasscode: .plaintextPassword(value: "hunter2")), .alphanumeric)
    }

    func testRequiredCodeTypeWithoutPasscodeIsNumeric() {
        XCTAssertEqual(HiddenAccountCode.requiredCodeType(forAppPasscode: .none), .digits4)
        XCTAssertTrue(HiddenAccountCode.requiredCodeType(forAppPasscode: .none).isNumeric)
    }

    // MARK: - Well-formedness per type

    func testDigitsTypesRequireExactLength() {
        XCTAssertTrue(HiddenAccountCode.isWellFormed("1234", type: .digits4))
        XCTAssertFalse(HiddenAccountCode.isWellFormed("123", type: .digits4))
        XCTAssertFalse(HiddenAccountCode.isWellFormed("12345", type: .digits4))

        XCTAssertTrue(HiddenAccountCode.isWellFormed("123456", type: .digits6))
        XCTAssertFalse(HiddenAccountCode.isWellFormed("1234", type: .digits6))
    }

    func testDigitsTypesRejectNonDigits() {
        XCTAssertFalse(HiddenAccountCode.isWellFormed("12a4", type: .digits4))
        XCTAssertFalse(HiddenAccountCode.isWellFormed("١٢٣٤", type: .digits4), "non-ASCII digits are not typeable on the numeric passcode field")
    }

    func testAlphanumericAcceptsAnyLongEnoughString() {
        XCTAssertTrue(HiddenAccountCode.isWellFormed("hunter2", type: .alphanumeric))
        XCTAssertTrue(HiddenAccountCode.isWellFormed("1234", type: .alphanumeric))
        XCTAssertFalse(HiddenAccountCode.isWellFormed("abc", type: .alphanumeric))
    }

    // MARK: - Hashing

    func testVerifyAcceptsOnlyTheOriginalCode() throws {
        let entry = try XCTUnwrap(HiddenAccountCode.makeEntry(accountId: 1, code: "4821", type: .digits4))

        XCTAssertTrue(HiddenAccountCode.verify(code: "4821", entry: entry))
        XCTAssertFalse(HiddenAccountCode.verify(code: "4822", entry: entry))
        XCTAssertFalse(HiddenAccountCode.verify(code: "", entry: entry))
    }

    func testCodeIsNotStoredInTheClear() throws {
        let code = "4821"
        let entry = try XCTUnwrap(HiddenAccountCode.makeEntry(accountId: 1, code: code, type: .digits4))

        XCTAssertFalse(entry.hash.isEmpty)
        XCTAssertFalse(entry.salt.isEmpty)
        XCTAssertNil(entry.hash.range(of: Data(code.utf8)))
        XCTAssertNil(entry.salt.range(of: Data(code.utf8)))
    }

    func testEqualCodesGetDifferentSalts() throws {
        let first = try XCTUnwrap(HiddenAccountCode.makeEntry(accountId: 1, code: "4821", type: .digits4))
        let second = try XCTUnwrap(HiddenAccountCode.makeEntry(accountId: 2, code: "4821", type: .digits4))

        XCTAssertNotEqual(first.salt, second.salt)
        XCTAssertNotEqual(first.hash, second.hash)
        XCTAssertTrue(HiddenAccountCode.verify(code: "4821", entry: first))
        XCTAssertTrue(HiddenAccountCode.verify(code: "4821", entry: second))
    }

    func testEntryRecordsItsCodeType() throws {
        let entry = try XCTUnwrap(HiddenAccountCode.makeEntry(accountId: 1, code: "123456", type: .digits6))
        XCTAssertEqual(entry.codeType, .digits6)
    }

    // MARK: - Surviving a change of app passcode shape

    func testCodeStaysUsableAfterPasscodeLengthChanges() throws {
        let entry = try XCTUnwrap(HiddenAccountCode.makeEntry(accountId: 1, code: "4821", type: .digits4))

        let newRequiredType = HiddenAccountCode.requiredCodeType(forAppPasscode: .numericalPassword(value: "123456"))
        XCTAssertEqual(newRequiredType, .digits6)
        XCTAssertNotEqual(entry.codeType, newRequiredType, "this is exactly the stale case the screen warns about")

        XCTAssertTrue(HiddenAccountCode.isWellFormed("4821", type: entry.codeType))
        XCTAssertTrue(HiddenAccountCode.verify(code: "4821", entry: entry))
    }

    func testCodeStaysUsableAfterPasscodeBecomesAlphanumeric() throws {
        let entry = try XCTUnwrap(HiddenAccountCode.makeEntry(accountId: 1, code: "4821", type: .digits4))

        let newRequiredType = HiddenAccountCode.requiredCodeType(forAppPasscode: .plaintextPassword(value: "hunter2"))
        XCTAssertEqual(newRequiredType, .alphanumeric)
        XCTAssertTrue(HiddenAccountCode.verify(code: "4821", entry: entry))
    }

    func testAlphanumericCodeSurvivesPasscodeBecomingNumeric() throws {
        let entry = try XCTUnwrap(HiddenAccountCode.makeEntry(accountId: 1, code: "correct horse", type: .alphanumeric))

        XCTAssertEqual(HiddenAccountCode.requiredCodeType(forAppPasscode: .numericalPassword(value: "1234")), .digits4)
        XCTAssertTrue(HiddenAccountCode.isWellFormed("correct horse", type: entry.codeType))
        XCTAssertTrue(HiddenAccountCode.verify(code: "correct horse", entry: entry))
    }

    // MARK: - Search pre-check

    func testSearchPreCheckAcceptsOnlyNumericCodeShapes() {
        XCTAssertTrue(HiddenAccountCode.couldBeNumericCode("1234"))
        XCTAssertTrue(HiddenAccountCode.couldBeNumericCode("123456"))
        XCTAssertFalse(HiddenAccountCode.couldBeNumericCode("12345"))
        XCTAssertFalse(HiddenAccountCode.couldBeNumericCode("hello"))
        XCTAssertFalse(HiddenAccountCode.couldBeNumericCode(""))
    }

    // MARK: - Settings round-trip

    func testSettingsIdentifyHiddenAccounts() throws {
        let entry = try XCTUnwrap(HiddenAccountCode.makeEntry(accountId: 42, code: "4821", type: .digits4))
        let settings = HiddenAccountsSettings(stealthMode: false, restrictSettingsToHiddenAccounts: false, entries: [entry])

        XCTAssertTrue(settings.isHidden(accountId: 42))
        XCTAssertFalse(settings.isHidden(accountId: 43))
        XCTAssertEqual(settings.hiddenAccountIds, Set([42]))
        XCTAssertEqual(settings.entry(accountId: 42)?.codeType, .digits4)
    }
}
