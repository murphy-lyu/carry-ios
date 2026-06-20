//
//  UIApplication+ActivityPresenter.swift
//  Carry
//
//  系统分享面板（UIActivityViewController）的统一呈现入口。
//  UIKit 细节隔离在此，不暴露给上层 SwiftUI。
//

import UIKit
import UniformTypeIdentifiers
import LinkPresentation

extension UIApplication {
    /// 当前最顶层可用作 presenter 的 view controller：
    /// 从 key window 的 rootViewController 起，沿 `presentedViewController` 链一路走到最顶。
    ///
    /// 为什么必须走到最顶：根级去 TabView 后，Settings / 行程详情等都以 `.sheet` 呈现，
    /// 此时 rootViewController 已经有 `presentedViewController`（那个 sheet）。直接对
    /// rootViewController 调 `present(_:)` 会因「已有 presentation 进行中」被 UIKit 静默吞掉
    /// ——表现就是「点了没反应」。必须在最顶层的 presented controller 上再 present。
    var topMostPresenter: UIViewController? {
        let scenes = connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first,
              let root = window.rootViewController else { return nil }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    /// 在最顶层 presenter 上呈现系统分享面板。
    /// iPad / Mac Catalyst 下 popover 需要 anchor——统一锚到 presenter 视图中心、无箭头。
    func presentActivitySheet(items: [Any], applicationActivities: [UIActivity]? = nil) {
        guard let presenter = topMostPresenter else { return }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: applicationActivities)
        if let pop = vc.popoverPresentationController {
            pop.sourceView = presenter.view
            pop.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        presenter.present(vc, animated: true)
    }
}

/// 物品清单分享的「混合」item source：同一次分享按目标给不同表现——
/// - **聊天 / 复制 / 邮件等**：给纯文本，保住「贴进对话内联可读」的体验；
/// - **AirDrop / 存到「文件」**：给一份带规范文件名（`行程名 打包清单 (月份).txt`、
///   与行程「发送给朋友」同风格、加「打包清单」区分字段）的 `.txt`，避免系统自动起的难看名字。
///
/// 机制：`placeholderItem` 用 **文件 URL**，让分享面板把「存到文件」也列出来、并在顶部预览
/// 直接显示规范文件名；`itemForActivityType` 再对聊天类目标回退成纯文本，故两头都不损失。
/// 写临时文件失败时整体降级为纯文本（与旧行为一致）。
final class PackingListShareItemSource: NSObject, UIActivityItemSource {
    private let text: String
    /// 文件名主体（不含扩展名），如「云南 打包清单 (6月)」。
    private let baseName: String
    /// 预生成的临时 `.txt`（文件名即 `baseName`）。失败为 nil → 全程降级纯文本。
    private let fileURL: URL?

    init(text: String, baseName: String) {
        self.text = text
        self.baseName = baseName
        self.fileURL = Self.writeTempFile(text: text, baseName: baseName)
        super.init()
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any {
        fileURL ?? text
    }

    func activityViewController(_ controller: UIActivityViewController,
                               itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        guard let fileURL else { return text }
        guard let activityType else { return text }
        // 仅「文件型」目标拿文件；其余（聊天/复制/邮件/未知三方）一律回退纯文本以保内联可读。
        return Self.fileTargets.contains(activityType.rawValue) ? fileURL : text
    }

    func activityViewController(_ controller: UIActivityViewController,
                               subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        baseName
    }

    func activityViewController(_ controller: UIActivityViewController,
                               dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
        UTType.plainText.identifier
    }

    func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = baseName   // 分享面板顶部预览显示规范名，而非正文首行
        return metadata
    }

    /// 拿文件名（而非内联文本）的目标：AirDrop + 存到「文件」。Save-to-Files 的标识符为非公开字符串，
    /// 但稳定多年；命中失败时该目标只会拿到纯文本、不会出错，属可接受的优雅降级。
    private static let fileTargets: Set<String> = [
        UIActivity.ActivityType.airDrop.rawValue,
        "com.apple.DocumentManagerUICore.SaveToFiles",
    ]

    private static func writeTempFile(text: String, baseName: String) -> URL? {
        guard let data = text.data(using: .utf8) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(baseName)
            .appendingPathExtension("txt")
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
    }
}
