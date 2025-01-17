//
//  QRScannerView.swift
//  QRScanner
//
//  Created by wbi on 2019/10/16.
//  Copyright © 2019 Mercari, Inc. All rights reserved.
//

import UIKit
import AVFoundation

// MARK: - QRScannerViewDelegate
public protocol QRScannerViewDelegate: AnyObject {
    // Required
    func qrScannerView(_ qrScannerView: QRScannerView, didFailure error: QRScannerError)
    func qrScannerView(_ qrScannerView: QRScannerView, didSuccess code: String)
    // Optional
    func qrScannerView(_ qrScannerView: QRScannerView, didChangeTorchActive isOn: Bool)
}

public extension QRScannerViewDelegate {
    func qrScannerView(_ qrScannerView: QRScannerView, didChangeTorchActive isOn: Bool) {}
}

// MARK: - QRScannerView
@IBDesignable
public class QRScannerView: UIView {

    // MARK: - Input
    public struct Input {
        let focusImage: UIImage?
        let focusImagePadding: CGFloat?
        let animationDuration: Double?
        let isBlurEffectEnabled: Bool?

        public static var `default`: Input {
            return .init(focusImage: nil, focusImagePadding: nil, animationDuration: nil, isBlurEffectEnabled: nil)
        }

        public init(focusImage: UIImage? = nil, focusImagePadding: CGFloat? = nil, animationDuration: Double? = nil, isBlurEffectEnabled: Bool? = nil) {
            self.focusImage = focusImage
            self.focusImagePadding = focusImagePadding
            self.animationDuration = animationDuration
            self.isBlurEffectEnabled = isBlurEffectEnabled
        }
    }

    // MARK: - Public Properties
    @IBInspectable
    public var focusImage: UIImage?

    @IBInspectable
    public var focusImagePadding: CGFloat = 8.0

    @IBInspectable
    public var animationDuration: Double = 0.5

    @IBInspectable
    public var isBlurEffectEnabled: Bool = false

    // MARK: - Public
    public var delegate: QRScannerViewDelegate?

    public func configure(input: Input = .default) {
        if let focusImage = input.focusImage {
            self.focusImage = focusImage
        }
        if let focusImagePadding = input.focusImagePadding {
            self.focusImagePadding = focusImagePadding
        }
        if let animationDuration = input.animationDuration {
            self.animationDuration = animationDuration
        }
        if let isBlurEffectEnabled = input.isBlurEffectEnabled {
            self.isBlurEffectEnabled = isBlurEffectEnabled
        }

        configureSession()
        addPreviewLayer()
        setupBlurEffectView()
        setupImageViews()
    }

    public override var bounds: CGRect {
        didSet {
            if oldValue.size.width != frame.size.width || oldValue.size.height != frame.size.height {
                // called in layoutSubviews makes animation broken
                updateFocusImageView()
            }
        }
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        updateFocusImageView() // For SwiftUI, updateFocusImageView() in bounds didSet is not called when wrapped in UIViewRepresentable
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        updateCameraView()
    }

    public var isRunning: Bool {
        session.isRunning == true
    }

    public func startRunning() {
        guard isAuthorized() else { return }
        guard !session.isRunning else { return }
        videoDataOutputEnable = false
        metadataOutputEnable = true
        metadataQueue.async { [weak self] in
            self?.session.startRunning()
        }
    }

    public func stopRunning() {
        guard session.isRunning else { return }
        videoDataQueue.async { [weak self] in
            self?.session.stopRunning()
        }
        metadataOutputEnable = false
        videoDataOutputEnable = false
    }

    public func rescan() {
        guard isAuthorized() else { return }
        blurEffectView.isHidden = isBlurEffectEnabled
        focusImageView.removeFromSuperview()
        qrCodeImageView.removeFromSuperview()
        setupImageViews()
        qrCodeImage = nil
        videoDataOutputEnable = false
        metadataOutputEnable = true
    }

    public func setTorchActive(isOn: Bool) {
        assert(Thread.isMainThread)

        guard let videoDevice = AVCaptureDevice.default(for: .video),
            videoDevice.hasTorch, videoDevice.isTorchAvailable,
            (metadataOutputEnable || videoDataOutputEnable) else {
                return
        }
        try? videoDevice.lockForConfiguration()
        videoDevice.torchMode = isOn ? .on : .off
        videoDevice.unlockForConfiguration()
    }

    deinit {
        setTorchActive(isOn: false)
        focusImageView.removeFromSuperview()
        qrCodeImageView.removeFromSuperview()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        removePreviewLayer()
        torchActiveObservation = nil
    }

    // MARK: - Private
    private let metadataQueue = DispatchQueue(label: "metadata.session.qrreader.queue")
    private let videoDataQueue = DispatchQueue(label: "videoData.session.qrreader.queue")
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var focusImageView = UIImageView()
    private var qrCodeImageView = UIImageView()
    private var metadataOutput = AVCaptureMetadataOutput()
    private var videoDataOutput = AVCaptureVideoDataOutput()
    private var metadataOutputEnable = false
    private var videoDataOutputEnable = false
    private var torchActiveObservation: NSKeyValueObservation?
    private var qrCodeImage: UIImage?
    private lazy var blurEffectView: UIVisualEffectView = {
        let blurEffectView = UIVisualEffectView(effect: UIBlurEffect(style: .light))
        blurEffectView.frame = self.bounds
        blurEffectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        return blurEffectView
    }()

    private enum AuthorizationStatus {
        case authorized, notDetermined, restrictedOrDenied
    }

    private func isAuthorized() -> Bool {
        return authorizationStatus() == .authorized
    }

    private func authorizationStatus() -> AuthorizationStatus {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .authorized
        case .notDetermined:
            failure(.unauthorized(.notDetermined))
            return .notDetermined
        case .denied:
            failure(.unauthorized(.denied))
            return .restrictedOrDenied
        case .restricted:
            failure(.unauthorized(.restricted))
            return .restrictedOrDenied
        @unknown default:
            return .restrictedOrDenied
        }
    }

    private func configureSession() {
        // check device initialize
        guard let videoDevice = AVCaptureDevice.default(for: .video) else {
            failure(.deviceFailure(.videoUnavailable))
            return
        }

        // check input
        guard let videoInput = try? AVCaptureDeviceInput(device: videoDevice), session.canAddInput(videoInput) else {
            failure(.deviceFailure(.inputInvalid))
            return
        }

        // check metadata output
        guard session.canAddOutput(metadataOutput) else {
            failure(.deviceFailure(.metadataOutputFailure))
            return
        }

        // check videoData output
        guard session.canAddOutput(videoDataOutput) else {
            failure(.deviceFailure(.videoDataOutputFailure))
            return
        }

        // commit session
        session.beginConfiguration()
        session.addInput(videoInput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: metadataQueue)
        session.addOutput(metadataOutput)
        metadataOutput.metadataObjectTypes = [.qr]

        videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoDataOutput.setSampleBufferDelegate(self, queue: videoDataQueue)
        session.addOutput(videoDataOutput)

        session.commitConfiguration()

        // torch observation
        if videoDevice.hasTorch {
            torchActiveObservation = videoDevice.observe(\.isTorchActive, options: .new) { [weak self] _, change in
                self?.didChangeTorchActive(isOn: change.newValue ?? false)
            }
        }

        // start running
        if authorizationStatus() == .notDetermined {
            videoDataOutputEnable = false
            metadataOutputEnable = true
            metadataQueue.async { [weak self] in
                self?.session.startRunning()
            }
        }
    }

    private func setupBlurEffectView() {
        guard isBlurEffectEnabled else { return }
        blurEffectView.isHidden = true
        addSubview(blurEffectView)
    }

    private func setupImageViews() {
        focusImageView = UIImageView()
        updateFocusImageView()
        focusImageView.image = focusImage ?? UIImage(named: "scan_qr_focus", in: .module, compatibleWith: nil)
        addSubview(focusImageView)

        if isBlurEffectEnabled {
            qrCodeImageView = UIImageView()
            qrCodeImageView.contentMode = .scaleAspectFill
            addSubview(qrCodeImageView)
        }
    }

    private func addPreviewLayer() {
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = self.bounds
        layer.addSublayer(previewLayer)

        self.previewLayer = previewLayer
    }

    private func removePreviewLayer() {
        previewLayer?.removeFromSuperlayer()
    }

    private func moveImageViews(qrCode: String, corners: [CGPoint]) {
        assert(Thread.isMainThread)

        let path = UIBezierPath()
        path.move(to: corners[0])
        corners[1..<corners.count].forEach() {
            path.addLine(to: $0)
        }
        path.close()

        let aSide: CGFloat
        let bSide: CGFloat
        if corners[0].x < corners[1].x {
            aSide = corners[0].x - corners[1].x
            bSide = corners[1].y - corners[0].y
        } else {
            aSide = corners[2].y - corners[1].y
            bSide = corners[2].x - corners[1].x
        }
        let degrees = atan(aSide / bSide)

        var maxSide: CGFloat = hypot(corners[3].x - corners[0].x, corners[3].y - corners[0].y)
        for (i, _) in corners.enumerated() {
            if i == 3 { break }
            let side = hypot(corners[i].x - corners[i+1].x, corners[i].y - corners[i+1].y)
            maxSide = side > maxSide ? side : maxSide
        }
        maxSide += focusImagePadding * 2

        UIView.animate(withDuration: animationDuration, animations: { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.focusImageView.frame = path.bounds
            let center = strongSelf.focusImageView.center
            strongSelf.focusImageView.frame.size = CGSize(width: maxSide, height: maxSide)
            strongSelf.focusImageView.center = center
            strongSelf.focusImageView.transform = CGAffineTransform.identity.rotated(by: degrees)

            if strongSelf.isBlurEffectEnabled {
                strongSelf.qrCodeImageView.frame = path.bounds
                strongSelf.qrCodeImageView.center = center
            }

        }, completion: { [weak self] _ in
            guard let strongSelf = self else { return }
            if strongSelf.isBlurEffectEnabled {
                strongSelf.qrCodeImageView.image = strongSelf.qrCodeImage
                strongSelf.blurEffectView.isHidden = false
            }
            strongSelf.focusImageView.isHidden = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (strongSelf.isBlurEffectEnabled ? 0.3 : 0)) {
                strongSelf.success(qrCode)
            }
        })
    }

    private func failure(_ error: QRScannerError) {
        delegate?.qrScannerView(self, didFailure: error)
    }

    private func success(_ code: String) {
        delegate?.qrScannerView(self, didSuccess: code)
    }

    private func didChangeTorchActive(isOn: Bool) {
        delegate?.qrScannerView(self, didChangeTorchActive: isOn)
    }
}

// MARK: - AVCaptureMetadataOutputObjectsDelegate

extension QRScannerView: AVCaptureMetadataOutputObjectsDelegate {
    public func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard metadataOutputEnable else { return }
        if let metadataObject = metadataObjects.first {
            guard let readableObject = previewLayer?.transformedMetadataObject(for: metadataObject) as? AVMetadataMachineReadableCodeObject, metadataObject.type == .qr else { return }
            guard let stringValue = readableObject.stringValue else { return }
            metadataOutputEnable = false
            videoDataOutputEnable = true

            // 魔法值0.15是为了等待下一次AVCaptureVideoDataOutputSampleBufferDelegate有输出，确保有二维码出现。
            DispatchQueue.main.asyncAfter(deadline: .now() + (isBlurEffectEnabled ? 0.15 : 0)) { [weak self] in
                guard let strongSelf = self else { return }
                strongSelf.setTorchActive(isOn: false)
                strongSelf.moveImageViews(qrCode: stringValue, corners: readableObject.corners)
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension QRScannerView: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard videoDataOutputEnable else { return }
        guard let qrCodeImage = getImageFromSampleBuffer(sampleBuffer: sampleBuffer) else { return }
        self.qrCodeImage = qrCodeImage
        videoDataOutputEnable = false
    }

    private func getImageFromSampleBuffer(sampleBuffer: CMSampleBuffer) -> UIImage? {
        let scale = UIScreen.main.scale
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let context = CGContext(data: baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else { return nil }
        guard let cgImage = context.makeImage() else { return nil }

        let sampleBuffer = UIImage(cgImage: cgImage, scale: scale, orientation: .up)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)

        return readQRCode(sampleBuffer)
    }

    private func readQRCode(_ image: UIImage) -> UIImage? {
        guard let ciImage = CIImage(image: image) else { return nil }
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        guard let features = detector?.features(in: ciImage) else { return nil }
        guard let feature = features.first as? CIQRCodeFeature else { return nil }

        let transform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -ciImage.extent.size.height)
        let path = UIBezierPath()
        path.move(to: feature.topLeft.applying(transform))
        path.addLine(to: feature.topRight.applying(transform))
        path.addLine(to: feature.bottomRight.applying(transform))
        path.addLine(to: feature.bottomLeft.applying(transform))
        path.close()
        return image.crop(path)
    }
}

extension QRScannerView {

    private func updateFocusImageView() {
        let width = min(self.bounds.width, self.bounds.height) * 0.618
        let x = (self.bounds.width > self.bounds.height) ? (self.bounds.width - width) / 2 : self.bounds.width * 0.191
        let y = self.bounds.height * 0.191
        focusImageView.frame = CGRect(x: x, y: y, width: width, height: width)
    }

    private func updateCameraView() {
        previewLayer?.connection?.videoOrientation = getOrientation()
        previewLayer?.frame = bounds
    }

    private func getOrientation() -> AVCaptureVideoOrientation {
        let interfaceOrientation: UIInterfaceOrientation
        if #available(iOS 13.0, *) {
            interfaceOrientation = window?.windowScene?.interfaceOrientation ?? .portrait
        } else {
            interfaceOrientation = UIApplication.shared.statusBarOrientation
        }
        switch interfaceOrientation {
        case .unknown:
            return .portrait
        case .portrait:
            return .portrait
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .landscapeLeft:
            return .landscapeLeft
        case .landscapeRight:
            return .landscapeRight
        @unknown default:
            return .portrait
        }
    }
}

private extension UIImage {
    func crop(_ path: UIBezierPath) -> UIImage? {
        let rect = CGRect(origin: CGPoint(), size: CGSize(width: size.width * scale, height: size.height * scale))
        UIGraphicsBeginImageContextWithOptions(rect.size, false, scale)

        UIColor.clear.setFill()
        UIRectFill(rect)
        path.addClip()
        draw(in: rect)

        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        guard let croppedImage = image?.cgImage?.cropping(to: CGRect(x: path.bounds.origin.x * scale, y: path.bounds.origin.y * scale, width: path.bounds.size.width * scale, height: path.bounds.size.height * scale)) else { return nil }
        return UIImage(cgImage: croppedImage, scale: scale, orientation: imageOrientation)
    }
}
