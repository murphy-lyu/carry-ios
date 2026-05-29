//
//  CarryWidgetLiveActivity.swift
//  CarryWidget
//
//  Created by Murphy on 2026/5/29.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct CarryWidgetAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        var emoji: String
    }

    // Fixed non-changing properties about your activity go here!
    var name: String
}

struct CarryWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CarryWidgetAttributes.self) { context in
            // Lock screen/banner UI goes here
            VStack {
                Text("Hello \(context.state.emoji)")
            }
            .activityBackgroundTint(Color.cyan)
            .activitySystemActionForegroundColor(Color.black)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    Text("Leading")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Trailing")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Bottom \(context.state.emoji)")
                    // more content
                }
            } compactLeading: {
                Text("L")
            } compactTrailing: {
                Text("T \(context.state.emoji)")
            } minimal: {
                Text(context.state.emoji)
            }
            .widgetURL(URL(string: "http://www.apple.com"))
            .keylineTint(Color.red)
        }
    }
}

extension CarryWidgetAttributes {
    fileprivate static var preview: CarryWidgetAttributes {
        CarryWidgetAttributes(name: "World")
    }
}

extension CarryWidgetAttributes.ContentState {
    fileprivate static var smiley: CarryWidgetAttributes.ContentState {
        CarryWidgetAttributes.ContentState(emoji: "😀")
     }
     
     fileprivate static var starEyes: CarryWidgetAttributes.ContentState {
         CarryWidgetAttributes.ContentState(emoji: "🤩")
     }
}

#Preview("Notification", as: .content, using: CarryWidgetAttributes.preview) {
   CarryWidgetLiveActivity()
} contentStates: {
    CarryWidgetAttributes.ContentState.smiley
    CarryWidgetAttributes.ContentState.starEyes
}
