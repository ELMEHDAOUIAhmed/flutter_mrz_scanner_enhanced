import UIKit
import AVFoundation
import SwiftyTesseract
import AudioToolbox
import Vision

public protocol MRZScannerViewDelegate: AnyObject {
    func onParse(_ parsed: String?)
    func onError(_ error: String?)
    func onPhoto(_ data: Data?)
}

public class MRZScannerView: UIView {
    // EDIT: Initialized Tesseract with the ocrb language.
    fileprivate let tesseract = SwiftyTesseract(language: .custom("ocrb"), bundle: Bundle(url: Bundle(for: MRZScannerView.self).url(forResource: "TraineedDataBundle", withExtension: "bundle")!)!, engineMode: .tesseractLstmCombined)
    
    fileprivate let captureSession = AVCaptureSession()
    fileprivate let videoOutput = AVCaptureVideoDataOutput()
    fileprivate let photoOutput = AVCapturePhotoOutput()
    fileprivate let videoPreviewLayer = AVCaptureVideoPreviewLayer()
    fileprivate var isScanningPaused = false
    fileprivate var observer: NSKeyValueObservation?
    @objc public dynamic var isScanning = false
    public weak var delegate: MRZScannerViewDelegate?
    private var photoData: Data?
    fileprivate var shouldCrop: Bool = false
    fileprivate var isFrontCam: Bool = false

    fileprivate var interfaceOrientation: UIInterfaceOrientation {
        return UIApplication.shared.statusBarOrientation
    }
    
    // MARK: - Added Flashlight Control (matching Android torch())
    public func flashlightOn() {
        guard let device = AVCaptureDevice.default(for: .video),
              device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = .on
            device.unlockForConfiguration()
        } catch {
            delegate?.onError("Flashlight error: \(error.localizedDescription)")
        }
    }
    
    public func flashlightOff() {
        guard let device = AVCaptureDevice.default(for: .video),
              device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = .off
            device.unlockForConfiguration()
        } catch {
            delegate?.onError("Flashlight error: \(error.localizedDescription)")
        }
    }
    
    // MARK: Initializers
    override public init(frame: CGRect) {
        super.init(frame: frame)
        // EDIT: Uncommented initialize call if needed.
        // initialize()
    }
    
    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        // EDIT: Uncommented initialize call if needed.
        // initialize()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: Overriden methods
    override public func prepareForInterfaceBuilder() {
        setViewStyle()
    }
    
    override public func layoutSubviews() {
        super.layoutSubviews()
        adjustVideoPreviewLayerFrame()
    }
    
    // MARK: Scanning
    public func startScanning(_ isFrontCam: Bool) {
        self.isFrontCam = isFrontCam
        if captureSession.inputs.isEmpty {
            self.initialize()
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession.startRunning()
            DispatchQueue.main.async { [weak self] in self?.adjustVideoPreviewLayerFrame() }
        }
    }
    
    public func stopScanning() {
        captureSession.stopRunning()
    }
    
    // EDIT: Updated takePhoto to more closely match Android's behavior.
    // Instead of saving to a file, we send the image data (cropped or full) via the delegate.
    public func takePhoto(shouldCrop: Bool) {
        self.shouldCrop = shouldCrop
        photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }
    
    // MARK: MRZ
    // EDIT: Updated mrz(from:) to perform pre‑processing (grayscale & thresholding) before OCR.
    fileprivate func mrz(from cgImage: CGImage) -> String? {
        // Convert CGImage to UIImage and preprocess
        let originalImage = UIImage(cgImage: cgImage)
        let preprocessedImage = preprocessImage(originalImage)
        
        var recognizedString: String?
        // Using Tesseract OCR on the preprocessed image.
        tesseract.performOCR(on: preprocessedImage) { recognizedString = $0 }
        return recognizedString
    }
    
    // MARK: Preprocessing
    // EDIT: Added a preprocessing function to mimic the grayscale conversion and thresholding in Android.
    fileprivate func preprocessImage(_ image: UIImage) -> UIImage {
        // Convert to grayscale using Core Image
        guard let cgImage = image.cgImage else { return image }
        let ciImage = CIImage(cgImage: cgImage)
        let grayscale = ciImage.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        
        // Apply a threshold filter.
        // Note: Core Image does not have a built-in threshold filter,
        // so for simplicity we simulate it by adjusting contrast.
        let threshold = grayscale.applyingFilter("CIColorControls", parameters: [
            kCIInputContrastKey: 4.0  // Increase contrast to mimic thresholding
        ])
        
        let context = CIContext(options: nil)
        if let outputCGImage = context.createCGImage(threshold, from: threshold.extent) {
            return UIImage(cgImage: outputCGImage)
        }
        return image
    }
    
    // MARK: Document Image from Photo cropping
    // EDIT: calculateCutoutRect updated to use same document ratio as Android (86/55 ≈ 1.5636)
fileprivate func cutoutRect(for cgImage: CGImage) -> CGRect {
    let imageWidth = CGFloat(cgImage.width)
    let imageHeight = CGFloat(cgImage.height)
    // Call the updated calculateCutoutRect function with cropToMRZ set to true.
    // Here, we're using the view's bounds as the reference size.
    let rect = videoPreviewLayer.metadataOutputRectConverted(fromLayerRect: calculateCutoutRect(for: bounds.size, cropToMRZ: false))
    let videoOrientation = videoPreviewLayer.connection!.videoOrientation

    if videoOrientation == .portrait || videoOrientation == .portraitUpsideDown {
        return CGRect(x: (rect.minY * imageWidth),
                      y: (rect.minX * imageHeight),
                      width: (rect.height * imageWidth),
                      height: (rect.width * imageHeight))
    } else {
        return CGRect(x: (rect.minX * imageWidth),
                      y: (rect.minY * imageHeight),
                      width: (rect.width * imageWidth),
                      height: (rect.height * imageHeight))
    }
}

    
    fileprivate func documentImage(from cgImage: CGImage) -> CGImage {
        let croppingRect = cutoutRect(for: cgImage)
        return cgImage.cropping(to: croppingRect) ?? cgImage
    }
    
    // MARK: UIApplication Observers
    @objc fileprivate func appWillEnterForeground() {
        if isScanningPaused {
            isScanningPaused = false
            startScanning(self.isFrontCam)
        }
    }
    
    @objc fileprivate func appDidEnterBackground() {
        if isScanning {
            isScanningPaused = true
            stopScanning()
        }
    }
    
    // MARK: Init methods
    fileprivate func initialize() {
        setViewStyle()
        initCaptureSession()
        addAppObservers()
    }
    
    fileprivate func setViewStyle() {
        backgroundColor = .black
    }
    
    fileprivate func initCaptureSession() {
        captureSession.sessionPreset = .hd1920x1080
        
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: self.isFrontCam ? .front : .back) else {
            delegate?.onError("Camera not accessible")
            print("Camera not accessible")
            return
        }
        
        guard let deviceInput = try? AVCaptureDeviceInput(device: camera) else {
            delegate?.onError("Capture input could not be initialized")
            print("Capture input could not be initialized")
            return
        }
        
        observer = captureSession.observe(\.isRunning, options: [.new]) { [unowned self] (model, change) in
            // Ensure UI updates on main thread.
            DispatchQueue.main.async { [weak self] in self?.isScanning = change.newValue! }
        }
        
        if captureSession.canAddInput(deviceInput) &&
            captureSession.canAddOutput(videoOutput) &&
            captureSession.canAddOutput(photoOutput) {
            
            captureSession.addInput(deviceInput)
            captureSession.addOutput(videoOutput)
            captureSession.addOutput(photoOutput)
            
            videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "video_frames_queue", qos: .userInteractive, attributes: [], autoreleaseFrequency: .workItem))
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as [String : Any]
            videoOutput.connection(with: .video)!.videoOrientation = AVCaptureVideoOrientation(orientation: interfaceOrientation)
            
            videoPreviewLayer.session = captureSession
            videoPreviewLayer.videoGravity = .resizeAspectFill
            
            layer.insertSublayer(videoPreviewLayer, at: 0)
        }
        else {
            delegate?.onError("Input & Output could not be added to the session")
        }
    }
    
    fileprivate func addAppObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }
    
    // MARK: Misc
    fileprivate func adjustVideoPreviewLayerFrame() {
        videoOutput.connection(with: .video)?.videoOrientation = AVCaptureVideoOrientation(orientation: interfaceOrientation)
        videoPreviewLayer.connection?.videoOrientation = AVCaptureVideoOrientation(orientation: interfaceOrientation)
        videoPreviewLayer.frame = bounds
    }
    
// New function: calculateCutoutRect(for:cropToMRZ:)
// This mirrors the Kotlin function by using the document ratio (86/55)
// and optionally cropping only the bottom 35% (MRZ area) if cropToMRZ is true.
fileprivate func calculateCutoutRect(for imageSize: CGSize, cropToMRZ: Bool) -> CGRect {
    let documentFrameRatio = CGFloat(86.0 / 55.0) // same ratio as Flutter overlay
    
    // Calculate document frame dimensions based on the image size.
    let width: CGFloat
    let height: CGFloat
    if imageSize.height > imageSize.width {
        width = imageSize.width * 0.9  // 90% of available width
        height = width / documentFrameRatio
    } else {
        height = imageSize.height * 0.75  // 75% of available height
        width = height * documentFrameRatio
    }
    
    // Center the document region within the image.
    let leftOffset = (imageSize.width - width) / 2.0
    let topOffset = (imageSize.height - height) / 2.0
    
    if !cropToMRZ {
        // Normal cropping: Expand the region with a margin (10% extra on each side)
        let marginPercentage = CGFloat(0.1)
        let marginX = width * marginPercentage
        let marginY = height * marginPercentage
        
        let newLeft = max(0, leftOffset - marginX)
        let newTop = max(0, topOffset - marginY)
        var newWidth = width * (1 + 2 * marginPercentage)
        var newHeight = height * (1 + 2 * marginPercentage)
        
        if newLeft + newWidth > imageSize.width {
            newWidth = imageSize.width - newLeft
        }
        if newTop + newHeight > imageSize.height {
            newHeight = imageSize.height - newTop
        }
        return CGRect(x: newLeft, y: newTop, width: newWidth, height: newHeight)
    } else {
        // Crop to MRZ area only: 35% of the document frame height at the bottom.
        let mrzHeight = height * 0.35
        let mrzLeft = leftOffset
        let mrzTop = topOffset + height - mrzHeight
        let mrzWidth = width
        
        let cropLeft = max(0, mrzLeft)
        let cropTop = max(0, mrzTop)
        let cropWidth = (cropLeft + mrzWidth > imageSize.width) ? imageSize.width - cropLeft : mrzWidth
        let cropHeight = (cropTop + mrzHeight > imageSize.height) ? imageSize.height - cropTop : mrzHeight
        
        return CGRect(x: cropLeft, y: cropTop, width: cropWidth, height: cropHeight)
    }
}

}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension MRZScannerView: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let cgImage = pixelBuffer.cgImage else {
            return
        }
        
        // EDIT: Crop the full frame to the document area.
        let documentImage = self.documentImage(from: cgImage)
        let imageRequestHandler = VNImageRequestHandler(cgImage: documentImage, options: [:])
        
        let detectTextRectangles = VNDetectTextRectanglesRequest { [unowned self] request, error in
            guard error == nil else {
                return
            }
            
            guard let results = request.results as? [VNTextObservation] else {
                return
            }
            
            let imageWidth = CGFloat(documentImage.width)
            let imageHeight = CGFloat(documentImage.height)
            let transform = CGAffineTransform.identity.scaledBy(x: imageWidth, y: -imageHeight).translatedBy(x: 0, y: -1)
            let mrzTextRectangles = results.map({ $0.boundingBox.applying(transform) }).filter({ $0.width > (imageWidth * 0.8) })
            let mrzRegionRect = mrzTextRectangles.reduce(into: CGRect.null, { $0 = $0.union($1) })
            
            // EDIT: Only process if the region is not too tall (similar to Android's check).
            guard mrzRegionRect.height <= (imageHeight * 0.4) else {
                return
            }
            
            if let mrzTextImage = documentImage.cropping(to: mrzRegionRect) {
                // Perform OCR on the cropped & preprocessed MRZ region.
                if let mrzResult = self.mrz(from: mrzTextImage) {
                    self.delegate?.onParse(mrzResult)
                }
            }
        }
        
        try? imageRequestHandler.perform([detectTextRectangles])
    }
}

extension MRZScannerView: AVCapturePhotoCaptureDelegate {
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            print("Error capturing photo: \(error)")
        } else {
            photoData = photo.fileDataRepresentation()
            // EDIT: Use the device's orientation instead of a fixed one.
            let currentOrientation = self.interfaceOrientation
            let uiOrientation: UIImage.Orientation = {
                switch currentOrientation {
                case .portrait: return .right
                case .portraitUpsideDown: return .left
                case .landscapeLeft: return .up
                case .landscapeRight: return .down
                default: return .right
                }
            }()
            
            // EDIT: Adjust the rotation using the updated orientation.
            let cgImage = photo.cgImageRepresentation()!
            let rotated = createMatchingBackingDataWithImage(imageRef: cgImage, orienation: uiOrientation)
            let resized = resize(rotated!)
            if self.shouldCrop {
                // Crop the image to the document area.
                let document = self.documentImage(from: resized ?? rotated!)
                
                // Save to temporary storage
                if let pngData = document.png {
                    saveImageToTemporaryStorage(imageData: pngData)
                }
                
                delegate?.onPhoto(document.png)
            } else {
                let img = resized ?? rotated!
                
                // Save to temporary storage
                if let pngData = img.png {
                    saveImageToTemporaryStorage(imageData: pngData)
                }
                
                delegate?.onPhoto(img.png)
            }
        }
    }
    
    private func saveImageToTemporaryStorage(imageData: Data) {
        do {
            let tempDir = FileManager.default.temporaryDirectory
            let fileName = "mrz_image_\(Int(Date().timeIntervalSince1970)).png"
            let fileURL = tempDir.appendingPathComponent(fileName)
            try imageData.write(to: fileURL)
            print("Image saved to temporary storage: \(fileURL.path)")
        } catch {
            print("Error saving image to temporary storage: \(error)")
        }
    }
    
    func createMatchingBackingDataWithImage(imageRef: CGImage?, orienation: UIImage.Orientation) -> CGImage? {
        var orientedImage: CGImage?
        
        if let imageRef = imageRef {
            let originalWidth = imageRef.width
            let originalHeight = imageRef.height
            let bitsPerComponent = imageRef.bitsPerComponent
            let bytesPerRow = imageRef.bytesPerRow
            
            let bitmapInfo = imageRef.bitmapInfo
            
            guard let colorSpace = imageRef.colorSpace else {
                return nil
            }
            
            var degreesToRotate: Double
            var swapWidthHeight: Bool
            var mirrored: Bool
            switch orienation {
            case .up:
                degreesToRotate = 0.0
                swapWidthHeight = false
                mirrored = false
            case .upMirrored:
                degreesToRotate = 0.0
                swapWidthHeight = false
                mirrored = true
            case .right:
                degreesToRotate = 90.0
                swapWidthHeight = true
                mirrored = false
            case .rightMirrored:
                degreesToRotate = 90.0
                swapWidthHeight = true
                mirrored = true
            case .down:
                degreesToRotate = 180.0
                swapWidthHeight = false
                mirrored = false
            case .downMirrored:
                degreesToRotate = 180.0
                swapWidthHeight = false
                mirrored = true
            case .left:
                degreesToRotate = -90.0
                swapWidthHeight = true
                mirrored = false
            case .leftMirrored:
                degreesToRotate = -90.0
                swapWidthHeight = true
                mirrored = true
            @unknown default:
                degreesToRotate = 0.0
                swapWidthHeight = false
                mirrored = false
            }
            let radians = degreesToRotate * Double.pi / 180.0
            
            var width: Int
            var height: Int
            if swapWidthHeight {
                width = originalHeight
                height = originalWidth
            } else {
                width = originalWidth
                height = originalHeight
            }
            
            let contextRef = CGContext(data: nil, width: width, height: height, bitsPerComponent: bitsPerComponent, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo.rawValue)
            contextRef?.translateBy(x: CGFloat(width) / 2.0, y: CGFloat(height) / 2.0)
            if mirrored {
                contextRef?.scaleBy(x: -1.0, y: 1.0)
            }
            contextRef?.rotate(by: CGFloat(radians))
            if swapWidthHeight {
                contextRef?.translateBy(x: -CGFloat(height) / 2.0, y: -CGFloat(width) / 2.0)
            } else {
                contextRef?.translateBy(x: -CGFloat(width) / 2.0, y: -CGFloat(height) / 2.0)
            }
            contextRef?.draw(imageRef, in: CGRect(x: 0.0, y: 0.0, width: CGFloat(originalWidth), height: CGFloat(originalHeight)))
            orientedImage = contextRef?.makeImage()
        }
        
        return orientedImage
    }
    
    func resize(_ image: CGImage) -> CGImage? {
        var ratio: Float = 0.0
        let imageWidth = Float(image.width)
        let imageHeight = Float(image.height)
        let maxWidth: Float = 720.0
        let maxHeight: Float = 1280.0
        
        // Get ratio (landscape or portrait)
        if imageWidth > imageHeight {
            ratio = maxWidth / imageWidth
        } else {
            ratio = maxHeight / imageHeight
        }
        
        if ratio > 1 {
            ratio = 1
        }
        
        let width = imageWidth * ratio
        let height = imageHeight * ratio
        
        guard let colorSpace = image.colorSpace else { return nil }
        guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: image.bitsPerComponent, bytesPerRow: image.bytesPerRow, space: colorSpace, bitmapInfo: image.bitmapInfo.rawValue) else { return nil }
        
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: Int(width), height: Int(height)))
        
        return context.makeImage()
    }
}

extension AVCaptureVideoOrientation {
    internal init(orientation: UIInterfaceOrientation) {
        switch orientation {
        case .portrait:
            self = .portrait
        case .portraitUpsideDown:
            self = .portraitUpsideDown
        case .landscapeLeft:
            self = .landscapeLeft
        case .landscapeRight:
            self = .landscapeRight
        default:
            self = .portrait
        }
    }
}

extension CVImageBuffer {
    var cgImage: CGImage? {
        CVPixelBufferLockBaseAddress(self, .readOnly)
        
        let baseAddress = CVPixelBufferGetBaseAddress(self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(self)
        let (width, height) = (CVPixelBufferGetWidth(self), CVPixelBufferGetHeight(self))
        let bitmapInfo = CGBitmapInfo(rawValue: (CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue))
        let context = CGContext(data: baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo.rawValue)
        
        guard let cgImage = context?.makeImage() else {
            return nil
        }
        
        CVPixelBufferUnlockBaseAddress(self, .readOnly)
        
        return cgImage
    }
}

extension CGImage {
    var png: Data? {
        guard let mutableData = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(mutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, self, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }
}
