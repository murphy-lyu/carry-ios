//
//  UIApplication+ActivityPresenter.swift
//  Carry
//
//  系统分享面板（UIActivityViewController）的统一呈现入口。
//  UIKit 细节隔离在此，不暴露给上层 SwiftUI。
//

import UIKit

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
