load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

swift_library(
    name = "ShareController",
    module_name = "ShareController",
    srcs = glob([
		"Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/SaveToCameraRoll:SaveToCameraRoll",
        "//submodules/StickerResources:StickerResources",
        "//submodules/UrlEscaping:UrlEscaping",
        "//submodules/LocalizedPeerData:LocalizedPeerData",
        "//submodules/ActionSheetPeerItem:ActionSheetPeerItem",
        "//submodules/ChatListSearchRecentPeersNode:ChatListSearchRecentPeersNode",
        "//submodules/PeerPresenceStatusManager:PeerPresenceStatusManager",
        "//submodules/SelectablePeerNode:SelectablePeerNode",
        "//submodules/RadialStatusNode:RadialStatusNode",
        "//submodules/ActivityIndicator:ActivityIndicator",
        "//submodules/AppBundle:AppBundle",
        "//submodules/TelegramStringFormatting:TelegramStringFormatting",
        "//submodules/TelegramIntents:TelegramIntents",
        "//submodules/AccountContext:AccountContext",
        "//submodules/SegmentedControlNode:SegmentedControlNode",
        "//submodules/WallpaperBackgroundNode:WallpaperBackgroundNode",
        "//submodules/ShimmerEffect:ShimmerEffect",
        "//submodules/ContextUI:ContextUI",
        "//submodules/AnimatedStickerNode:AnimatedStickerNode",
        "//submodules/TelegramAnimatedStickerNode:TelegramAnimatedStickerNode",
        "//submodules/TelegramUniversalVideoContent:TelegramUniversalVideoContent",
        "//submodules/ComponentFlow:ComponentFlow",
        "//submodules/TelegramUI/Components/EmojiStatusComponent:EmojiStatusComponent",
        "//submodules/TelegramUI/Components/AnimationCache",
        "//submodules/TelegramUI/Components/MultiAnimationRenderer",
        "//submodules/UndoUI",
        "//submodules/Components/MultilineTextComponent",
        "//submodules/TelegramUI/Components/AnimatedTextComponent",
        "//submodules/Components/BundleIconComponent",
        "//submodules/TelegramUI/Components/LottieComponent",
        "//submodules/TelegramUI/Components/MessageInputPanelComponent",
        "//submodules/TelegramUI/Components/ChatEntityKeyboardInputNode",
        "//submodules/TelegramUI/Components/Chat/ChatMessagePaymentAlertController",
        "//submodules/TelegramUI/Components/ChatScheduleTimeController",
        "//submodules/ChatPresentationInterfaceState",
        "//submodules/CheckNode",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "ShareControllerTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    linkopts = [
        "-framework",
        "MediaPlayer",
    ],
    deps = [
        ":ShareController",
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/AccountContext:AccountContext",
    ],
)

ios_test_runner(
    name = "ShareControllerTestRunner",
    device_type = "iPhone 17",
    os_version = "26.5",
)

ios_unit_test(
    name = "ShareControllerTests",
    minimum_os_version = "15.0",
    runner = ":ShareControllerTestRunner",
    deps = [
        ":ShareControllerTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
