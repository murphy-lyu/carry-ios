//
//  CarryWidgetBundle.swift
//  CarryWidget
//
//  Created by Murphy on 2026/5/29.
//

import WidgetKit
import SwiftUI

@main
struct CarryWidgetBundle: WidgetBundle {
    var body: some Widget {
#if canImport(ActivityKit)
        CarryWidgetLiveActivity()
#endif
    }
}
