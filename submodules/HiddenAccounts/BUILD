load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

swift_library(
    name = "HiddenAccounts",
    module_name = "HiddenAccounts",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/CryptoUtils:CryptoUtils",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "HiddenAccountsTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":HiddenAccounts",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
    ],
)

ios_test_runner(
    name = "HiddenAccountsTestRunner",
    device_type = "iPhone 17",
    os_version = "26.5",
)

ios_unit_test(
    name = "HiddenAccountsTests",
    # 15.0, not the 13.0 the older test target uses: the iOS 27 SDK's libc++
    # hard-errors below it (see the Xcode 27 notes in CLAUDE.md).
    minimum_os_version = "15.0",
    runner = ":HiddenAccountsTestRunner",
    deps = [
        ":HiddenAccountsTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
