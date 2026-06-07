//
//  FriendsFeedWidgetBundle.swift
//  FriendsFeedWidget
//
//  Created by Hafizi Zaironi on 05/06/2026.
//

import WidgetKit
import SwiftUI

@main
struct FriendsFeedWidgetBundle: WidgetBundle {
    var body: some Widget {
        FriendsFeedWidget()      // Photo Feed
        NearbyMapWidget()        // Nearby Map
    }
}
