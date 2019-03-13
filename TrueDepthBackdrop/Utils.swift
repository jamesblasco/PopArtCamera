//
//  Utils.swift
//  TrueDepthBackdrop
//
//  Created by Jaime on 12/03/2019.
//  Copyright © 2019 Apple. All rights reserved.
//

import UIKit


extension UIImage {
    
    func alpha(_ value:CGFloat) -> UIImage {
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        draw(at: CGPoint.zero, blendMode: .normal, alpha: value)
        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return newImage!
    }
}
