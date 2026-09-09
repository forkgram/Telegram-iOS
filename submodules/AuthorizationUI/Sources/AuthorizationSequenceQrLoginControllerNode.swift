import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramPresentationData
import Markdown
import QrCode
import SolidRoundedButtonNode

private final class QrLoginStepNode: ASDisplayNode {
    private let numberBackgroundNode: ASImageNode
    private let numberNode: ImmediateTextNode
    private let textNode: ImmediateTextNode

    private let numberDiameter: CGFloat = 24.0
    private let numberSpacing: CGFloat = 12.0

    init(theme: PresentationTheme, index: Int, text: String) {
        self.numberBackgroundNode = ASImageNode()
        self.numberBackgroundNode.displaysAsynchronously = false
        self.numberBackgroundNode.displayWithoutProcessing = true
        self.numberBackgroundNode.image = generateFilledCircleImage(diameter: self.numberDiameter, color: theme.list.itemAccentColor)

        self.numberNode = ImmediateTextNode()
        self.numberNode.displaysAsynchronously = false
        self.numberNode.attributedText = NSAttributedString(string: "\(index)", font: Font.semibold(14.0), textColor: theme.list.itemCheckColors.foregroundColor)

        self.textNode = ImmediateTextNode()
        self.textNode.displaysAsynchronously = false
        self.textNode.maximumNumberOfLines = 0
        self.textNode.attributedText = parseMarkdownIntoAttributedString(text, attributes: MarkdownAttributes(
            body: MarkdownAttributeSet(font: Font.regular(15.0), textColor: theme.list.itemPrimaryTextColor),
            bold: MarkdownAttributeSet(font: Font.semibold(15.0), textColor: theme.list.itemPrimaryTextColor),
            link: MarkdownAttributeSet(font: Font.regular(15.0), textColor: theme.list.itemAccentColor),
            linkAttribute: { _ in nil }
        ))

        super.init()

        self.addSubnode(self.numberBackgroundNode)
        self.addSubnode(self.numberNode)
        self.addSubnode(self.textNode)
    }

    func updateLayout(width: CGFloat) -> CGSize {
        let textWidth = max(1.0, width - self.numberDiameter - self.numberSpacing)
        let textSize = self.textNode.updateLayout(CGSize(width: textWidth, height: .greatestFiniteMagnitude))

        let height = max(self.numberDiameter, textSize.height)
        self.numberBackgroundNode.frame = CGRect(origin: CGPoint(), size: CGSize(width: self.numberDiameter, height: self.numberDiameter))

        let numberSize = self.numberNode.updateLayout(CGSize(width: self.numberDiameter, height: self.numberDiameter))
        self.numberNode.frame = CGRect(origin: CGPoint(x: floorToScreenPixels((self.numberDiameter - numberSize.width) / 2.0), y: floorToScreenPixels((self.numberDiameter - numberSize.height) / 2.0)), size: numberSize)

        self.textNode.frame = CGRect(origin: CGPoint(x: self.numberDiameter + self.numberSpacing, y: floorToScreenPixels((self.numberDiameter - min(textSize.height, self.numberDiameter)) / 2.0)), size: textSize)

        return CGSize(width: width, height: height)
    }
}

final class AuthorizationSequenceQrLoginControllerNode: ASDisplayNode {
    private let theme: PresentationTheme
    private let strings: PresentationStrings

    private let titleNode: ImmediateTextNode
    private let subtitleNode: ImmediateTextNode
    private let codeBackgroundNode: ASImageNode
    private let codeImageNode: ASImageNode
    private let stepNodes: [QrLoginStepNode]
    private let phoneLoginButtonNode: HighlightableButtonNode

    private var validLayout: (ContainerViewLayout, CGFloat)?

    private var currentUrl: String?
    private var renderedCodeSize: CGFloat?
    private let codeDisposable = MetaDisposable()

    var loginWithPhone: (() -> Void)?

    init(theme: PresentationTheme, strings: PresentationStrings) {
        self.theme = theme
        self.strings = strings

        self.titleNode = ImmediateTextNode()
        self.titleNode.displaysAsynchronously = false
        self.titleNode.maximumNumberOfLines = 0
        self.titleNode.textAlignment = .center
        self.titleNode.attributedText = NSAttributedString(string: strings.Login_QrTitle, font: Font.bold(28.0), textColor: theme.list.itemPrimaryTextColor, paragraphAlignment: .center)

        self.subtitleNode = ImmediateTextNode()
        self.subtitleNode.displaysAsynchronously = false
        self.subtitleNode.maximumNumberOfLines = 0
        self.subtitleNode.textAlignment = .center
        self.subtitleNode.attributedText = NSAttributedString(string: strings.Login_QrSubtitle, font: Font.regular(16.0), textColor: theme.list.itemSecondaryTextColor, paragraphAlignment: .center)

        self.codeBackgroundNode = ASImageNode()
        self.codeBackgroundNode.displaysAsynchronously = false
        self.codeBackgroundNode.displayWithoutProcessing = true
        self.codeBackgroundNode.image = generateStretchableFilledCircleImage(radius: 16.0, color: .white)

        self.codeImageNode = ASImageNode()
        self.codeImageNode.displaysAsynchronously = false
        self.codeImageNode.contentMode = .scaleAspectFit

        self.stepNodes = [
            QrLoginStepNode(theme: theme, index: 1, text: strings.Login_QrStep1),
            QrLoginStepNode(theme: theme, index: 2, text: strings.Login_QrStep2),
            QrLoginStepNode(theme: theme, index: 3, text: strings.Login_QrStep3)
        ]

        self.phoneLoginButtonNode = HighlightableButtonNode()
        self.phoneLoginButtonNode.setTitle(strings.Login_QrUsePhoneNumber, with: Font.regular(17.0), with: theme.list.itemAccentColor, for: .normal)

        super.init()

        self.backgroundColor = theme.list.plainBackgroundColor

        self.addSubnode(self.titleNode)
        self.addSubnode(self.subtitleNode)
        self.addSubnode(self.codeBackgroundNode)
        self.addSubnode(self.codeImageNode)
        for stepNode in self.stepNodes {
            self.addSubnode(stepNode)
        }
        self.addSubnode(self.phoneLoginButtonNode)

        self.phoneLoginButtonNode.addTarget(self, action: #selector(self.phoneLoginPressed), forControlEvents: .touchUpInside)
    }

    deinit {
        self.codeDisposable.dispose()
    }

    @objc private func phoneLoginPressed() {
        self.loginWithPhone?()
    }

    func updateUrl(_ url: String) {
        guard url != self.currentUrl else {
            return
        }
        self.currentUrl = url
        self.renderedCodeSize = nil
        self.renderCodeIfNeeded()
    }

    private func renderCodeIfNeeded() {
        guard let url = self.currentUrl, let (layout, _) = self.validLayout else {
            return
        }
        let side = self.codeSide(layout: layout)
        guard self.renderedCodeSize != side else {
            return
        }
        self.renderedCodeSize = side

        let size = CGSize(width: side, height: side)
        self.codeDisposable.set((qrCode(string: url, color: .black, backgroundColor: .white, icon: .none)
        |> deliverOnMainQueue).startStrict(next: { [weak self] _, generate in
            guard let self else {
                return
            }
            let context = generate(TransformImageArguments(corners: ImageCorners(), imageSize: size, boundingSize: size, intrinsicInsets: UIEdgeInsets()))
            self.codeImageNode.image = context?.generateImage()
        }))
    }

    private func codeSide(layout: ContainerViewLayout) -> CGFloat {
        let maximumWidth = min(430.0, layout.size.width)
        return floor(min(240.0, maximumWidth - 120.0))
    }

    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        self.validLayout = (layout, navigationBarHeight)

        var insets = layout.insets(options: [])
        insets.top = max(insets.top, navigationBarHeight)

        let sideInset: CGFloat = 24.0
        let maximumWidth = min(430.0, layout.size.width)
        let contentWidth = maximumWidth - sideInset * 2.0
        let contentOriginX = floorToScreenPixels((layout.size.width - contentWidth) / 2.0)

        let codePadding: CGFloat = 16.0
        let codeSide = self.codeSide(layout: layout)
        self.renderCodeIfNeeded()

        let titleSize = self.titleNode.updateLayout(CGSize(width: contentWidth, height: .greatestFiniteMagnitude))
        let subtitleSize = self.subtitleNode.updateLayout(CGSize(width: contentWidth, height: .greatestFiniteMagnitude))
        var stepSizes: [CGSize] = []
        for stepNode in self.stepNodes {
            stepSizes.append(stepNode.updateLayout(width: contentWidth))
        }

        let buttonHeight: CGFloat = 50.0
        let buttonFrame = CGRect(origin: CGPoint(x: contentOriginX, y: layout.size.height - insets.bottom - buttonHeight - 8.0), size: CGSize(width: contentWidth, height: buttonHeight))
        transition.updateFrame(node: self.phoneLoginButtonNode, frame: buttonFrame)

        let titleSpacing: CGFloat = 12.0
        let codeSpacing: CGFloat = 24.0
        let stepsSpacing: CGFloat = 24.0
        let stepSpacing: CGFloat = 16.0

        var contentHeight = titleSize.height + titleSpacing + subtitleSize.height + codeSpacing + codeSide + codePadding * 2.0 + stepsSpacing
        for (index, stepSize) in stepSizes.enumerated() {
            contentHeight += stepSize.height
            if index != stepSizes.count - 1 {
                contentHeight += stepSpacing
            }
        }

        let availableHeight = buttonFrame.minY - insets.top
        var originY = insets.top + max(0.0, floor((availableHeight - contentHeight) / 2.0))

        transition.updateFrame(node: self.titleNode, frame: CGRect(origin: CGPoint(x: floorToScreenPixels((layout.size.width - titleSize.width) / 2.0), y: originY), size: titleSize))
        originY += titleSize.height + titleSpacing

        transition.updateFrame(node: self.subtitleNode, frame: CGRect(origin: CGPoint(x: floorToScreenPixels((layout.size.width - subtitleSize.width) / 2.0), y: originY), size: subtitleSize))
        originY += subtitleSize.height + codeSpacing

        let codeBackgroundSide = codeSide + codePadding * 2.0
        let codeBackgroundFrame = CGRect(origin: CGPoint(x: floorToScreenPixels((layout.size.width - codeBackgroundSide) / 2.0), y: originY), size: CGSize(width: codeBackgroundSide, height: codeBackgroundSide))
        transition.updateFrame(node: self.codeBackgroundNode, frame: codeBackgroundFrame)
        transition.updateFrame(node: self.codeImageNode, frame: CGRect(origin: CGPoint(x: codeBackgroundFrame.minX + codePadding, y: codeBackgroundFrame.minY + codePadding), size: CGSize(width: codeSide, height: codeSide)))
        originY += codeBackgroundSide + stepsSpacing

        for (index, stepNode) in self.stepNodes.enumerated() {
            transition.updateFrame(node: stepNode, frame: CGRect(origin: CGPoint(x: contentOriginX, y: originY), size: stepSizes[index]))
            originY += stepSizes[index].height + stepSpacing
        }
    }
}
