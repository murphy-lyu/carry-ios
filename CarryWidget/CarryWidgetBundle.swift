//
//  CarryWidgetBundle.swift
//  CarryWidget
//

import WidgetKit
import SwiftUI

@main
struct CarryWidgetBundle: WidgetBundle {
    var body: some Widget {
        CarryWidget()
#if canImport(ActivityKit)
        CarryWidgetLiveActivity()
#endif
    }
}
