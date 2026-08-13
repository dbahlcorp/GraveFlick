import SwiftUI
import UIKit

enum UIArt: String, CaseIterable {
    case logo = "ui_graveflick_logo"

    var image: UIImage? { UIImage(named: rawValue) }

    static var hasCompleteSet: Bool {
        allCases.allSatisfy { art in
            guard let image = art.image else { return false }
            return image.size.width > 1 && image.size.height > 1
        }
    }
}
