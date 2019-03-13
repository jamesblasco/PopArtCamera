/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Contains view controller code for previewing live-captured content.
*/

import UIKit
import AVFoundation
import CoreVideo
import Photos

@available(iOS 11.1, *)
class CameraViewController: UIViewController, AVCaptureDataOutputSynchronizerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    
    // MARK: - Properties
    
    @IBOutlet weak private var resumeButton: UIButton!
    
    @IBOutlet weak private var cameraUnavailableLabel: UILabel!
    
    @IBOutlet weak private var previewView: PreviewMetalView!
    
    private enum SessionSetupResult {
        case success
        case notAuthorized
        case configurationFailed
    }
    
    private var setupResult: SessionSetupResult = .success
    
    private let session = AVCaptureSession()
    
    private var isSessionRunning = false
    
    // Communicate with the session and other session objects on this queue.
    private let sessionQueue = DispatchQueue(label: "session queue", attributes: [], autoreleaseFrequency: .workItem)
    
    private var captureDevice: AVCaptureDevice!
    
    private var videoDeviceInput: AVCaptureDeviceInput!
    private var videoBackDeviceInput: AVCaptureDeviceInput!
    
    private let dataOutputQueue = DispatchQueue(label: "video data queue", qos: .userInitiated, attributes: [], autoreleaseFrequency: .workItem)
    
    private let videoDataOutput = AVCaptureVideoDataOutput()
    
    
    private let depthDataOutput = AVCaptureDepthDataOutput()
    
    private let metadataOutput = AVCaptureMetadataOutput()
    
    private var outputSynchronizer: AVCaptureDataOutputSynchronizer?
    
    private var renderingEnabled = true
    
    private let videoDeviceDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInTrueDepthCamera],
                                                                               mediaType: .video,
                                                                               position: .front)
    
    
    private var statusBarOrientation: UIInterfaceOrientation = .portrait
    
    private var currentFaceCenter: CGRect?
    
    private var blurRadius: Float = 5.0
    
    private var gamma: Float = 0.5
    
    private var depthCutOff: Float = 1.0
    
    private var backgroundImage: CIImage?
    
    private let imagePicker = UIImagePickerController()
    
    // MARK: - View Controller Life Cycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let rotateGesture = UIRotationGestureRecognizer(target: self, action: #selector(changeAlpha))
        previewView.addGestureRecognizer(rotateGesture)
        
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(hideBackground))
        previewView.addGestureRecognizer(tapGesture)
        
//        let doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(changeCamera))
//        doubleTapGesture.numberOfTapsRequired = 2
//        previewView.addGestureRecognizer(doubleTapGesture)
        
        
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(panGestureDetected))
        previewView.addGestureRecognizer(panGesture)
        panGesture.delegate = self
        
        let downSwipeGesture = UISwipeGestureRecognizer(target: self, action: #selector(chooseBackground))
        downSwipeGesture.direction = .down
        downSwipeGesture.delegate = self
        previewView.addGestureRecognizer(downSwipeGesture)
        
        
        
        // Check video authorization status, video access is required
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            // The user has previously granted access to the camera
            break
            
        case .notDetermined:
            /*
             The user has not yet been presented with the option to grant video access
             We suspend the session queue to delay session setup until the access request has completed
             */
            sessionQueue.suspend()
            AVCaptureDevice.requestAccess(for: .video, completionHandler: { granted in
                if !granted {
                    self.setupResult = .notAuthorized
                }
                self.sessionQueue.resume()
            })
            
        default:
            // The user has previously denied access
            setupResult = .notAuthorized
        }
        
        /*
         Set up the capture session.
         In general it is not safe to mutate an AVCaptureSession or any of its
         inputs, outputs, or connections from multiple threads at the same time.
         
         Why not do all of this on the main queue?
         Because AVCaptureSession.startRunning() is a blocking call which can
         take a long time. We dispatch session setup to the sessionQueue so
         that the main queue isn't blocked, which keeps the UI responsive.
         */
        sessionQueue.async {
            self.configureSession()
        }
        imagePicker.delegate = self
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        let interfaceOrientation = UIApplication.shared.statusBarOrientation
        statusBarOrientation = interfaceOrientation
        
        UIApplication.shared.isIdleTimerDisabled = true
        
        sessionQueue.async {
            switch self.setupResult {
            case .success:
                // Only setup observers and start the session running if setup succeeded
                self.addObservers()
                let videoOrientation = self.videoDataOutput.connection(with: .video)!.videoOrientation
                let videoDevicePosition = self.videoDeviceInput.device.position
                let rotation = PreviewMetalView.Rotation(with: interfaceOrientation,
                                                         videoOrientation: videoOrientation,
                                                         cameraPosition: videoDevicePosition)
                self.previewView.mirroring = false
                if let rotation = rotation {
                    self.previewView.rotation = rotation
                }
                self.dataOutputQueue.async {
                    self.renderingEnabled = true
                }
                
                self.session.startRunning()
                self.isSessionRunning = self.session.isRunning
                
            case .notAuthorized:
                DispatchQueue.main.async {
                    let message = NSLocalizedString("TrueDepthBackdrop doesn't have permission to use the camera, please change privacy settings",
                                                    comment: "Alert message when the user has denied access to the camera")
                    let alertController = UIAlertController(title: "TrueDepthBackdrop", message: message, preferredStyle: .alert)
                    alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"),
                                                            style: .cancel,
                                                            handler: nil))
                    alertController.addAction(UIAlertAction(title: NSLocalizedString("Settings", comment: "Alert button to open Settings"),
                                                            style: .`default`,
                                                            handler: { _ in
                                                                UIApplication.shared.open(URL(string: UIApplicationOpenSettingsURLString)!,
                                                                                          options: [:],
                                                                                          completionHandler: nil)
                    }))
                    
                    self.present(alertController, animated: true, completion: nil)
                }
                
            case .configurationFailed:
                DispatchQueue.main.async {
                    self.cameraUnavailableLabel.isHidden = false
                    self.cameraUnavailableLabel.alpha = 0
                    UIView.animate(withDuration: 0.25) {
                        self.cameraUnavailableLabel.alpha = 1
                    }
                }
            }
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        dataOutputQueue.async {
            self.renderingEnabled = false
        }
        sessionQueue.async {
            if self.setupResult == .success {
                self.session.stopRunning()
                self.isSessionRunning = self.session.isRunning
            }
        }
        
        super.viewWillDisappear(animated)
    }
    
    @objc
    func didEnterBackground(notification: NSNotification) {
        // Free up resources
        dataOutputQueue.async {
            self.renderingEnabled = false
            self.previewView.image = nil
        }
    }
    
    @objc
    func willEnterForground(notification: NSNotification) {
        dataOutputQueue.async {
            self.renderingEnabled = true
        }
    }
    
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .all
    }
    
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        
        coordinator.animate(
            alongsideTransition: { _ in
                let interfaceOrientation = UIApplication.shared.statusBarOrientation
                self.statusBarOrientation = interfaceOrientation
                self.sessionQueue.async {
                    /*
                     The photo orientation is based on the interface orientation. You could also set the orientation of the photo connection based
                     on the device orientation by observing UIDeviceOrientationDidChangeNotification.
                     */
                    let videoOrientation = self.videoDataOutput.connection(with: .video)!.videoOrientation
                    if let rotation = PreviewMetalView.Rotation(with: interfaceOrientation, videoOrientation: videoOrientation,
                                                                cameraPosition: self.videoDeviceInput.device.position) {
                        self.previewView.rotation = rotation
                    }
                }
        }, completion: nil
        )
    }
    
    // MARK: - KVO and Notifications
    
    private func addObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground),
                                               name: NSNotification.Name.UIApplicationDidEnterBackground, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willEnterForground),
                                               name: NSNotification.Name.UIApplicationWillEnterForeground, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionRuntimeError),
                                               name: NSNotification.Name.AVCaptureSessionRuntimeError, object: session)
        
        captureDevice.addObserver(self, forKeyPath: "systemPressureState", options: NSKeyValueObservingOptions.new, context: nil)
        
        /*
         A session can only run when the app is full screen. It will be interrupted
         in a multi-app layout, introduced in iOS 9, see also the documentation of
         AVCaptureSessionInterruptionReason. Add observers to handle these session
         interruptions and show a preview is paused message. See the documentation
         of AVCaptureSessionWasInterruptedNotification for other interruption reasons.
         */
        NotificationCenter.default.addObserver(self, selector: #selector(sessionWasInterrupted),
                                               name: NSNotification.Name.AVCaptureSessionWasInterrupted,
                                               object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionInterruptionEnded),
                                               name: NSNotification.Name.AVCaptureSessionInterruptionEnded,
                                               object: session)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        captureDevice.removeObserver(self, forKeyPath: "systemPressureState", context: nil)
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "systemPressureState" {
            
            let level = captureDevice.systemPressureState.level
            
            var recommendedFrameRate: Int32
            switch level {
            case .nominal, .fair:
                recommendedFrameRate = 30
            case .serious, .critical:
                recommendedFrameRate = 15
            case .shutdown:
                // no need to do anything. iOS is going to shut us down anyway...
                return
            default:
                assertionFailure("unknown system pressure level")
                return
            }
            
            print("System pressure state is now \(level.rawValue). Will set frame rate to \(recommendedFrameRate)")
            
            do {
                try captureDevice.lockForConfiguration()
                captureDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: recommendedFrameRate)
                captureDevice.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: recommendedFrameRate)
                captureDevice.unlockForConfiguration()
            } catch {
                print("Could not lock device for configuration: \(error)")
            }
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
    
    // MARK: - Session Management
    
    // Call this on the session queue
    private func configureSession() {
        if setupResult != .success {
            return
        }
        
        let defaultVideoDevice: AVCaptureDevice? = videoDeviceDiscoverySession.devices.first
        
        guard let videoDevice = defaultVideoDevice else {
            print("Could not find any video device")
            setupResult = .configurationFailed
            return
        }
        
        captureDevice = videoDevice
        
        do {
            videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
          
        } catch {
            print("Could not create video device input: \(error)")
            setupResult = .configurationFailed
            return
        }
        
        do {
            
            if let device = AVCaptureDevice.default(.builtInDualCamera,
                                                    for: .video, position: .back) {
                videoBackDeviceInput = try AVCaptureDeviceInput(device: device)
            } else if let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                           for: .video, position: .back) {
                videoBackDeviceInput = try AVCaptureDeviceInput(device: device)
            } else {
               
                fatalError("Missing expected back camera device.")
            }
            
        } catch {
            print("Could not create video device input: \(error)")
            return
        }
        session.beginConfiguration()
        
        session.sessionPreset = AVCaptureSession.Preset.hd1280x720
        
        // Add a video input
        guard session.canAddInput(videoDeviceInput) else {
            print("Could not add video device input to the session")
            setupResult = .configurationFailed
            session.commitConfiguration()
            return
        }
        session.addInput(videoDeviceInput)
        
        // Add a video data output
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
            videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        } else {
            print("Could not add video data output to the session")
            setupResult = .configurationFailed
            session.commitConfiguration()
            return
        }
        
        // Add a depth data output
        if session.canAddOutput(depthDataOutput) {
            session.addOutput(depthDataOutput)
            depthDataOutput.isFilteringEnabled = true
            if let connection = depthDataOutput.connection(with: .depthData) {
                connection.isEnabled = true
            } else {
                print("No AVCaptureConnection")
            }
        } else {
            print("Could not add depth data output to the session")
            setupResult = .configurationFailed
            session.commitConfiguration()
            return
        }
        
        // Search for highest resolution with floating-point depth values
        let depthFormats = videoDevice.activeFormat.supportedDepthDataFormats
        let depth32formats = depthFormats.filter({
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat32
        })
        if depth32formats.isEmpty {
            print("Device does not support Float32 depth format")
            setupResult = .configurationFailed
            session.commitConfiguration()
            return
        }
        
        let selectedFormat = depth32formats.max(by: { first, second in
            CMVideoFormatDescriptionGetDimensions(first.formatDescription).width <
                CMVideoFormatDescriptionGetDimensions(second.formatDescription).width })
        
        do {
            try videoDevice.lockForConfiguration()
            videoDevice.activeDepthDataFormat = selectedFormat
            videoDevice.unlockForConfiguration()
        } catch {
            print("Could not lock device for configuration: \(error)")
            setupResult = .configurationFailed
            session.commitConfiguration()
            return
        }
        
        if self.session.canAddOutput(metadataOutput) {
            self.session.addOutput(metadataOutput)
            if metadataOutput.availableMetadataObjectTypes.contains(.face) {
                metadataOutput.metadataObjectTypes = [.face]
            }
        } else {
            print("Could not add face detection output to the session")
            setupResult = .configurationFailed
            session.commitConfiguration()
            return
        }
        
        // Use an AVCaptureDataOutputSynchronizer to synchronize the video data and depth data outputs.
        // The first output in the dataOutputs array, in this case the AVCaptureVideoDataOutput, is the "master" output.
        outputSynchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoDataOutput, depthDataOutput, metadataOutput])
        outputSynchronizer!.setDelegate(self, queue: dataOutputQueue)
        session.commitConfiguration()
    }
    
    @objc
    func sessionWasInterrupted(notification: NSNotification) {
        // In iOS 9 and later, the userInfo dictionary contains information on why the session was interrupted.
        if let userInfoValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as AnyObject?,
            let reasonIntegerValue = userInfoValue.integerValue,
            let reason = AVCaptureSession.InterruptionReason(rawValue: reasonIntegerValue) {
            print("Capture session was interrupted with reason \(reason)")
            
            if reason == .videoDeviceInUseByAnotherClient {
                // Simply fade-in a button to enable the user to try to resume the session running.
                resumeButton.isHidden = false
                resumeButton.alpha = 0.0
                UIView.animate(withDuration: 0.25) {
                    self.resumeButton.alpha = 1.0
                }
            } else if reason == .videoDeviceNotAvailableWithMultipleForegroundApps {
                // Simply fade-in a label to inform the user that the camera is unavailable.
                cameraUnavailableLabel.isHidden = false
                cameraUnavailableLabel.alpha = 0.0
                UIView.animate(withDuration: 0.25) {
                    self.cameraUnavailableLabel.alpha = 1.0
                }
            }
        }
    }
    
    @objc
    func sessionInterruptionEnded(notification: NSNotification) {
        if !resumeButton.isHidden {
            UIView.animate(withDuration: 0.25,
                           animations: {
                            self.resumeButton.alpha = 0
            }, completion: { _ in
                self.resumeButton.isHidden = true
            }
            )
        }
        if !cameraUnavailableLabel.isHidden {
            UIView.animate(withDuration: 0.25,
                           animations: {
                            self.cameraUnavailableLabel.alpha = 0
            }, completion: { _ in
                self.cameraUnavailableLabel.isHidden = true
            }
            )
        }
    }
    
    @objc
    func sessionRuntimeError(notification: NSNotification) {
        guard let errorValue = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError else {
            return
        }
        
        let error = AVError(_nsError: errorValue)
        print("Capture session runtime error: \(error)")
        
        /*
         Automatically try to restart the session running if media services were
         reset and the last start running succeeded. Otherwise, enable the user
         to try to resume the session running.
         */
        if error.code == .mediaServicesWereReset {
            sessionQueue.async {
                if self.isSessionRunning {
                    self.session.startRunning()
                    self.isSessionRunning = self.session.isRunning
                } else {
                    DispatchQueue.main.async {
                        self.resumeButton.isHidden = false
                    }
                }
            }
        } else {
            resumeButton.isHidden = false
        }
    }
    
    @IBAction private func resumeInterruptedSession(_ sender: UIButton) {
        sessionQueue.async {
            /*
             The session might fail to start running. A failure to start the session running will be communicated via
             a session runtime error notification. To avoid repeatedly failing to start the session
             running, we only try to restart the session running in the session runtime error handler
             if we aren't trying to resume the session running.
             */
            self.session.startRunning()
            self.isSessionRunning = self.session.isRunning
            if !self.session.isRunning {
                DispatchQueue.main.async {
                    let message = NSLocalizedString("Unable to resume", comment: "Alert message when unable to resume the session running")
                    let alertController = UIAlertController(title: "TrueDepthViewer", message: message, preferredStyle: .alert)
                    let cancelAction = UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"), style: .cancel, handler: nil)
                    alertController.addAction(cancelAction)
                    self.present(alertController, animated: true, completion: nil)
                }
            } else {
                DispatchQueue.main.async {
                    self.resumeButton.isHidden = true
                }
            }
        }
    }
    
    var isFrontCamera: Bool = true
    @objc
    func changeCamera(_ gesture: UITapGestureRecognizer) {
        isFrontCamera = !isFrontCamera
        if isFrontCamera {
            sessionQueue.async {
              
                if self.session.canAddInput(self.videoDeviceInput) {
                    self.session.addInput(self.videoDeviceInput)
                }
                
                self.session.addOutput(self.depthDataOutput)
                self.session.removeInput(self.videoBackDeviceInput)
                self.session.commitConfiguration()
            }

        
        } else {
            sessionQueue.async {
                if self.session.canAddInput(self.videoBackDeviceInput) {
                    self.session.addInput(self.videoBackDeviceInput)
                }
                
                self.session.removeOutput(self.depthDataOutput)
                self.session.removeInput(self.videoDeviceInput)
                self.session.commitConfiguration()
            }
        }
        
        
    }
    
    var lastRotation: CGFloat = 0
   
    
    @objc
    func changeAlpha(_ gesture: UIRotationGestureRecognizer) {
         var originalRotation = CGFloat()
        if gesture.state == .began {
            gesture.rotation = lastRotation
            originalRotation = gesture.rotation
        } else if gesture.state == .changed {
            let newRotation = gesture.rotation + originalRotation
            
//            gesture.view?.transform = CGAffineTransform(rotationAngle: newRotation)
            var alpha = previewView.alpha + newRotation/2
            if alpha > 1 || alpha < 0 {
                alpha =  min(1, max(0, alpha))
                gesture.rotation = lastRotation
            }
            lastRotation = gesture.rotation
            alphaBackground = alpha
            print("rotated: \(gesture.rotation), alpha: \(alpha)")
        } else if gesture.state == .ended {
            lastRotation = gesture.rotation
        }
       
    }
    
    var isBackgroundHidden: Bool = true
    @objc
    func hideBackground(_ gesture: UITapGestureRecognizer) {
        isBackgroundHidden = !isBackgroundHidden
    }
    
   
    var hueValue: Float = 0
    var lastPosition: CGPoint = .zero
    @objc
    func panGestureDetected(_ gesture: UIPanGestureRecognizer) {
    
        var originalPosition  = CGPoint()
        if gesture.state == .began {
            gesture.setTranslation(lastPosition, in: nil)
            originalPosition = gesture.translation(in: nil)
        } else if gesture.state == .changed {
            
            let newPos = CGPoint(x: originalPosition.x + gesture.translation(in: nil).x,
                                 y: originalPosition.y + gesture.translation(in: nil).y)
            
            //            gesture.view?.transform = CGAffineTransform(rotationAngle: newRotation)
            var value = newPos.x/1000
            if value > 1 || value < 0 {
                value =  min(1, max(0, value))
                gesture.setTranslation(lastPosition, in: nil)
            }
            lastPosition = gesture.translation(in: nil)
            hueValue = Float(value)
            print("paned: \(gesture.translation(in: nil).x), progress: \(value)")
        } else if gesture.state == .ended {
            lastPosition = gesture.translation(in: nil)
        }
        
    }
    
    
    
    
    
    // MARK: - Background Loading
    
    @objc
    func chooseBackground(_ gesture: UISwipeGestureRecognizer) {
        imagePicker.allowsEditing = false
        imagePicker.sourceType = .savedPhotosAlbum
        
        present(imagePicker, animated: true, completion: nil)
    }
    
    func rotateToRightOrientation(image: UIImage) -> UIImage? {
        let size = CGSize(width: image.size.height, height: image.size.width)
        var rotationAngle: CGFloat
        var translation = CGSize(width: 0, height: 0)
        
        rotationAngle = -.pi / 2
        translation.width = -size.height
        
        UIGraphicsBeginImageContext(size)
        guard let cgContext = UIGraphicsGetCurrentContext() else {
            return nil
        }
        
        cgContext.rotate(by: rotationAngle)
        cgContext.translateBy(x: translation.width, y: translation.height)
        
        image.draw(at: CGPoint(x: 0, y: 0))
        
        let result = UIGraphicsGetImageFromCurrentImageContext()
        
        UIGraphicsEndImageContext()
        
        return result
    }
    
    func loadBackground(image: UIImage) -> CIImage? {
        guard let rotatedImage = rotateToRightOrientation(image: image) else {
            return nil
        }
        
        guard let cgImage = rotatedImage.cgImage else {
            assertionFailure()
            return nil
        }
        
        let imageWidth = cgImage.width
        let imageHeight = cgImage.height
        
        // Video preview is running at 1280x720. Downscale background to same resolution
        let videoWidth = 1280
        let videoHeight = 720
        
        let scaleX = CGFloat(imageWidth) / CGFloat(videoWidth)
        let scaleY = CGFloat(imageHeight) / CGFloat(videoHeight)
        
        let scale = min(scaleX, scaleY)
        
        // crop the image to have the right aspect ratio
        let cropSize = CGSize(width: CGFloat(videoWidth) * scale, height: CGFloat(videoHeight) * scale)
        let croppedImage = cgImage.cropping(to: CGRect(origin: CGPoint(
            x: (imageWidth - Int(cropSize.width)) / 2,
            y: (imageHeight - Int(cropSize.height)) / 2), size: cropSize))
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: videoWidth,
                                      height: videoHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                                        print("error")
                                        return nil
        }
        
        let bounds = CGRect(origin: CGPoint(x: 0, y: 0), size: CGSize(width: videoWidth, height: videoHeight))
        context.clear(bounds)
        
        context.draw(croppedImage!, in: bounds)
        
        guard let scaledImage = context.makeImage() else {
            print("failed")
            return nil
        }
        
        return CIImage(cgImage: scaledImage)
    }
    
    // MARK: - Image Picker Delegate
    
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [String: Any]) {
        if let pickedImage = info[UIImagePickerControllerOriginalImage] as? UIImage {
            self.backgroundImage = loadBackground(image: pickedImage)
        }
        
        dismiss(animated: true, completion: nil)
    }
    
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        dismiss(animated: true, completion: nil)
    }
    
    var alphaBackground: CGFloat = 1
    
    // MARK: - Video + Depth Output Synchronizer Delegate
    
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        
        
        // Read all outputs
        guard renderingEnabled,
           
            let syncedVideoData: AVCaptureSynchronizedSampleBufferData =
            synchronizedDataCollection.synchronizedData(for: videoDataOutput) as? AVCaptureSynchronizedSampleBufferData else {
                // only work on synced pairs
                return
        }

        guard let videoPixelBuffer = CMSampleBufferGetImageBuffer(syncedVideoData.sampleBuffer) else {
            return
        }
        
        let image = CIImage(cvPixelBuffer: videoPixelBuffer)
        var output: CIImage
        if !isBackgroundHidden {
              output = image
        } else {
            guard  let syncedDepthData: AVCaptureSynchronizedDepthData =
                synchronizedDataCollection.synchronizedData(for: depthDataOutput) as? AVCaptureSynchronizedDepthData
                else {return}
             let depthPixelBuffer = syncedDepthData.depthData.depthDataMap
            if syncedDepthData.depthDataWasDropped || syncedVideoData.sampleBufferWasDropped {
                return
            }
            
            // Check if there's a face in the scene. If so - use it to decide on depth cutoff
            if let syncedMetaData: AVCaptureSynchronizedMetadataObjectData =
                synchronizedDataCollection.synchronizedData(for: metadataOutput) as? AVCaptureSynchronizedMetadataObjectData,
                let firstFace = syncedMetaData.metadataObjects.first,
                let connection = self.videoDataOutput.connection(with: AVMediaType.video),
                let face = videoDataOutput.transformedMetadataObject(for: firstFace, connection: connection) {
                let faceCenter = CGPoint(x: face.bounds.midX, y: face.bounds.midY)
                
                let scaleFactor = CGFloat(CVPixelBufferGetWidth(depthPixelBuffer)) / CGFloat(CVPixelBufferGetWidth(videoPixelBuffer))
                let pixelX = Int((faceCenter.x * scaleFactor).rounded())
                let pixelY = Int((faceCenter.y * scaleFactor).rounded())
                
                CVPixelBufferLockBaseAddress(depthPixelBuffer, .readOnly)
                
                let rowData = CVPixelBufferGetBaseAddress(depthPixelBuffer)! + pixelY * CVPixelBufferGetBytesPerRow(depthPixelBuffer)
                let faceCenterDepth = rowData.assumingMemoryBound(to: Float32.self)[pixelX]
                CVPixelBufferUnlockBaseAddress(depthPixelBuffer, .readOnly)
                self.depthCutOff = faceCenterDepth + 0.25
            }
            
            // Convert depth map in-place: every pixel above cutoff is converted to 1. otherwise it's 0
            let depthWidth = CVPixelBufferGetWidth(depthPixelBuffer)
            let depthHeight = CVPixelBufferGetHeight(depthPixelBuffer)
            
            CVPixelBufferLockBaseAddress(depthPixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
            
            for yMap in 0 ..< depthHeight {
                let rowData = CVPixelBufferGetBaseAddress(depthPixelBuffer)! + yMap * CVPixelBufferGetBytesPerRow(depthPixelBuffer)
                let data = UnsafeMutableBufferPointer<Float32>(start: rowData.assumingMemoryBound(to: Float32.self), count: depthWidth)
                for index in 0 ..< depthWidth {
                    if data[index] > 0 && data[index] <= depthCutOff {
                        data[index] = 1.0
                    } else {
                        data[index] = 0.0
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(depthPixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
            
            // Create the mask from that pixel buffer.
            let depthMaskImage = CIImage(cvPixelBuffer: depthPixelBuffer, options: [:])
            
            // Smooth edges to create an alpha matte, then upscale it to the RGB resolution.
            let alphaUpscaleFactor = Float(CVPixelBufferGetWidth(videoPixelBuffer)) / Float(depthWidth)
            let alphaMatte = depthMaskImage.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": blurRadius])
                .applyingFilter("CIGammaAdjust", parameters: ["inputPower": gamma])
                .cropped(to: depthMaskImage.extent)
                .applyingFilter("CIBicubicScaleTransform", parameters: ["inputScale": alphaUpscaleFactor])
           
            
            // Apply alpha matte to the video.
            var parameters = ["inputMaskImage": alphaMatte]
            if let background = self.backgroundImage {
                
                let context = CIContext(options: nil)
                
                //            if let currentFilter = CIFilter(name: "CISepiaTone") {
                //                currentFilter.setValue(background, forKey: kCIInputImageKey)
                //                currentFilter.setValue(alphaBackground, forKey: kCIInputIntensityKey)
                //
                //                if let output = currentFilter.outputImage {
                //                    if let cgimg = context.createCGImage(output, from: output.extent) {
                //                        parameters["inputBackgroundImage"] = CIImage(cgImage: cgimg)
                //                        // do something interesting with the processed image
                //                    }
                //                }
                //            }
                
                if let currentFilter = CIFilter(name: "CIColorControls") {
                    currentFilter.setValue(background, forKey: kCIInputImageKey)
                    currentFilter.setValue(alphaBackground, forKey: kCIInputSaturationKey)
                    
                    if let output = currentFilter.outputImage {
                        if let cgimg = context.createCGImage(output, from: output.extent) {
                            
                            parameters["inputBackgroundImage"] = CIImage(cgImage: cgimg)
                            
         
                            
                            // do something interesting with the processed image
                        }
                    }
                }
                
                
                
            }
            
            output = image.applyingFilter("CIBlendWithMask", parameters: parameters)
        }
        
        
        
        let chromaKeyFilter = chromaFilter(hue: hueValue)
        chromaKeyFilter.setValue(output, forKey: kCIInputImageKey)
        if let filteredImage = chromaKeyFilter.outputImage {
            output = filteredImage
        }
        previewView.image = output
       
    }
}


extension AVCaptureVideoOrientation {
    init?(interfaceOrientation: UIInterfaceOrientation) {
        switch interfaceOrientation {
        case .portrait: self = .portrait
        case .portraitUpsideDown: self = .portraitUpsideDown
        case .landscapeLeft: self = .landscapeLeft
        case .landscapeRight: self = .landscapeRight
        default: return nil
        }
    }
}

extension PreviewMetalView.Rotation {
    
    init?(with interfaceOrientation: UIInterfaceOrientation, videoOrientation: AVCaptureVideoOrientation, cameraPosition: AVCaptureDevice.Position) {
        /*
         Calculate the rotation between the videoOrientation and the interfaceOrientation.
         The direction of the rotation depends upon the camera position.
         */
        switch videoOrientation {
            
        case .portrait:
            switch interfaceOrientation {
            case .landscapeRight:
                self = cameraPosition == .front ? .rotate90Degrees : .rotate270Degrees
                
            case .landscapeLeft:
                self = cameraPosition == .front ? .rotate270Degrees : .rotate90Degrees
                
            case .portrait:
                self = .rotate0Degrees
                
            case .portraitUpsideDown:
                self = .rotate180Degrees
                
            default: return nil
            }
            
        case .portraitUpsideDown:
            switch interfaceOrientation {
            case .landscapeRight:
                self = cameraPosition == .front ? .rotate270Degrees : .rotate90Degrees
                
            case .landscapeLeft:
                self = cameraPosition == .front ? .rotate90Degrees : .rotate270Degrees
                
            case .portrait:
                self = .rotate180Degrees
                
            case .portraitUpsideDown:
                self = .rotate0Degrees
                
            default: return nil
            }
            
        case .landscapeRight:
            switch interfaceOrientation {
            case .landscapeRight:
                self = .rotate0Degrees
                
            case .landscapeLeft:
                self = .rotate180Degrees
                
            case .portrait:
                self = cameraPosition == .front ? .rotate270Degrees : .rotate90Degrees
                
            case .portraitUpsideDown:
                self = cameraPosition == .front ? .rotate90Degrees : .rotate270Degrees
                
            default: return nil
            }
            
        case .landscapeLeft:
            switch interfaceOrientation {
            case .landscapeLeft:
                self = .rotate0Degrees
                
            case .landscapeRight:
                self = .rotate180Degrees
                
            case .portrait:
                self = cameraPosition == .front ? .rotate90Degrees : .rotate270Degrees
                
            case .portraitUpsideDown:
                self = cameraPosition == .front ? .rotate270Degrees : .rotate90Degrees
                
            default: return nil
            }
        }
    }
}


extension CameraViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }

}






func RGBtoHSV(_ r : Float, g : Float, b : Float) -> (h : Float, s : Float, v : Float) {
    var h : CGFloat = 0
    var s : CGFloat = 0
    var v : CGFloat = 0
    let col = UIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1.0)
    col.getHue(&h, saturation: &s, brightness: &v, alpha: nil)
    return (Float(h), Float(s), Float(v))
}

func HSVtoRGB(_ h : Float, s : Float, v : Float) -> (r : Float, g : Float, b : Float) {
    var r : Float = 0
    var g : Float = 0
    var b : Float = 0
    let C = s * v
    let HS = h * 6.0
    let X = C * (1.0 - fabsf(fmodf(HS, 2.0) - 1.0))
    if (HS >= 0 && HS < 1) {
        r = C
        g = X
        b = 0
    } else if (HS >= 1 && HS < 2) {
        r = X
        g = C
        b = 0
    } else if (HS >= 2 && HS < 3) {
        r = 0
        g = C
        b = X
    } else if (HS >= 3 && HS < 4) {
        r = 0
        g = X
        b = C
    } else if (HS >= 4 && HS < 5) {
        r = X
        g = 0
        b = C
    } else if (HS >= 5 && HS < 6) {
        r = C
        g = 0
        b = X
    }
    let m = v - C
    r += m
    g += m
    b += m
    return (r, g, b)
}

func chromaFilter(hue: Float) -> CIFilter {
    
    let size = 64
    let defaultHue: Float = 0 //default color of blue truck
    let hueRange: Float = 60 //hue angle that we want to replace
    
    let centerHueAngle: Float = defaultHue/360.0
    var destCenterHueAngle: Float = hue
    let minHueAngle: Float = (defaultHue - hueRange/2.0) / 360
    let maxHueAngle: Float = (defaultHue + hueRange/2.0) / 360
    let hueAdjustment = centerHueAngle - destCenterHueAngle
    if destCenterHueAngle == 0  {
        destCenterHueAngle = 1 //force red if slider angle is 0
    }
    
    var cubeData = [Float](repeating: 0, count: (size * size * size * 4))
    var offset = 0
    var x : Float = 0, y : Float = 0, z : Float = 0, a :Float = 1.0
    
    for b in 0..<size {
        x = Float(b)/Float(size)
        for g in 0..<size {
            y = Float(g)/Float(size)
            for r in 0..<size {
                z = Float(r)/Float(size)
                var hsv = RGBtoHSV(z, g: y, b: x)
                
                if (hsv.h > minHueAngle && hsv.h < maxHueAngle) {
                    hsv.h = destCenterHueAngle == 1 ? 0 : hsv.h - hueAdjustment //force red if slider angle is 360
                    let newRgb = HSVtoRGB(hsv.h, s:hsv.s, v:hsv.v)
                    
                    cubeData[offset] = newRgb.r
                    cubeData[offset+1] = newRgb.g
                    cubeData[offset+2] = newRgb.b
                } else {
                    cubeData[offset] = z
                    cubeData[offset+1] = y
                    cubeData[offset+2] = x
                }
                cubeData[offset+3] =  a
                offset += 4
            }
        }
    }
    
    let b = cubeData.withUnsafeBufferPointer{ Data(buffer:$0) }
    let data = b as NSData
    let colorCube = CIFilter(name: "CIColorCube", withInputParameters: ["inputCubeDimension": size, "inputCubeData" : data])
    return colorCube!
}
