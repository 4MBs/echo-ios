import UIKit

// MARK: - The stand-in

/// What covers the PDF while it changes between one page and a spread: the
/// reader's backdrop, and on it a camera holding a picture of every page
/// involved. The camera is what moves; the pages ride on it.
final class PageLayoutTransitionStage: UIView {
    /// How far past the page a picture of it reaches, so PDFKit's page shadow
    /// travels with the page instead of being cut off at its edge.
    static let shadowMargin: CGFloat = 7

    let camera = UIView()
    var hasBegun = false
    private var entries: [Int: Entry] = [:]

    /// A page's picture, and the page's own rectangle inside it.
    private struct Entry {
        let view: UIView
        let pageFrame: CGRect
    }

    init(frame: CGRect, backdrop: UIColor) {
        super.init(frame: frame)
        backgroundColor = backdrop
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        camera.frame = bounds
        addSubview(camera)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var isEmpty: Bool { entries.isEmpty }

    func hasPage(_ index: Int) -> Bool { entries[index] != nil }

    /// Where the page itself — not its shadow margin — sits on the stage.
    func pageFrame(of index: Int) -> CGRect? {
        guard let entry = entries[index] else { return nil }
        return entry.pageFrame.offsetBy(dx: entry.view.frame.minX, dy: entry.view.frame.minY)
    }

    func pages(notIn indices: Set<Int>) -> [UIView] {
        var views: [UIView] = []
        for (index, entry) in entries where !indices.contains(index) {
            views.append(entry.view)
        }
        return views
    }

    func addBackdropPicture(_ picture: UIView) {
        picture.frame = bounds
        camera.addSubview(picture)
    }

    /// A page as it was drawn: a cut-out of the live view, `pageFrame` being
    /// the page's own rectangle inside the cut-out.
    func addPage(index: Int, picture: UIView, frame: CGRect, pageFrame: CGRect) {
        let holder = UIView(frame: frame)
        picture.frame = holder.bounds
        holder.addSubview(picture)
        camera.addSubview(holder)
        entries[index] = Entry(view: holder, pageFrame: pageFrame)
    }

    /// A page the old layout never drew. It brings its own shadow, close to
    /// the one PDFKit gives the live pages.
    @discardableResult
    func addRenderedPage(index: Int, image: CGImage, frame: CGRect) -> UIView {
        let holder = UIView(frame: frame)
        holder.layer.shadowColor = UIColor.black.cgColor
        holder.layer.shadowOpacity = 0.2
        holder.layer.shadowRadius = 4
        holder.layer.shadowOffset = CGSize(width: 0, height: 1.5)
        holder.layer.shadowPath = UIBezierPath(rect: holder.bounds).cgPath
        let picture = Self.imageView(image, frame: holder.bounds)
        holder.addSubview(picture)
        camera.addSubview(holder)
        entries[index] = Entry(view: holder, pageFrame: holder.bounds)
        return holder
    }

    /// Lays a sharp rendering over a cut-out page, leaving its shadow as it
    /// was.
    func sharpen(index: Int, with image: CGImage) {
        guard let entry = entries[index] else { return }
        entry.view.addSubview(Self.imageView(image, frame: entry.pageFrame))
    }

    func cancel() {
        layer.removeAllAnimations()
        camera.layer.removeAllAnimations()
        for entry in entries.values {
            entry.view.layer.removeAllAnimations()
        }
    }

    private static func imageView(_ image: CGImage, frame: CGRect) -> UIImageView {
        let view = UIImageView(image: UIImage(cgImage: image))
        view.frame = frame
        view.contentMode = .scaleToFill
        view.backgroundColor = .white
        view.layer.minificationFilter = .trilinear
        return view
    }
}

// MARK: - Rendering pages for the move

/// Renders a handful of pages off the main thread, from a document of its own:
/// PDFKit's document belongs to the view, and the view is busy relaying out.
final class PageLayoutRenders {
    typealias Images = [Int: CGImage]

    private let url: URL
    private let pages: Set<Int>
    private let maxPixelDimension: Int
    /// Read only on the main thread.
    private(set) var finished: Images = [:]

    init(url: URL, pages: Set<Int>, maxPixelDimension: Int) {
        self.url = url
        self.pages = pages
        self.maxPixelDimension = maxPixelDimension
    }

    func start(completion: @escaping (Images) -> Void) {
        let url = url
        let pages = pages
        let dimension = maxPixelDimension
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let rendered = RenderedPages(images: Self.render(url: url, pages: pages, maxPixelDimension: dimension))
            DispatchQueue.main.async {
                self?.finished = rendered.images
                completion(rendered.images)
            }
        }
    }

    private static func render(url: URL, pages: Set<Int>, maxPixelDimension: Int) -> Images {
        guard !pages.isEmpty, let document = CGPDFDocument(url as CFURL) else { return [:] }
        var images: Images = [:]
        for index in pages {
            guard let page = document.page(at: index + 1),
                  let image = render(page, maxPixelDimension: maxPixelDimension)
            else { continue }
            images[index] = image
        }
        return images
    }

    /// One page on white, `maxPixelDimension` along its longer side.
    ///
    /// Mapped by hand rather than with `getDrawingTransform`, which fits a
    /// box into a rectangle but never enlarges it: a page asked for at
    /// Retina size comes back at its printed point size.
    private static func render(_ page: CGPDFPage, maxPixelDimension: Int) -> CGImage? {
        let box = page.getBoxRect(.cropBox).standardized
        guard box.width > 0, box.height > 0 else { return nil }
        // /Rotate turns the sheet clockwise for display, so a quarter turn
        // trades the page's width for its height.
        let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
        let quarterTurned = rotation == 90 || rotation == 270
        let pageSize = quarterTurned ? CGSize(width: box.height, height: box.width) : box.size

        let scale = CGFloat(maxPixelDimension) / max(pageSize.width, pageSize.height)
        let width = max(1, Int((pageSize.width * scale).rounded(.up)))
        let height = max(1, Int((pageSize.height * scale).rounded(.up)))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(width) / pageSize.width, y: CGFloat(height) / pageSize.height)
        switch rotation {
        case 90:
            context.translateBy(x: 0, y: pageSize.height)
            context.rotate(by: -.pi / 2)
        case 180:
            context.translateBy(x: pageSize.width, y: pageSize.height)
            context.rotate(by: .pi)
        case 270:
            context.translateBy(x: pageSize.width, y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
        context.translateBy(x: -box.minX, y: -box.minY)
        context.clip(to: box)
        context.drawPDFPage(page)
        return context.makeImage()
    }
}

/// Carries the renders back to the main thread. Nothing touches the images
/// again on the worker once they are handed over.
private struct RenderedPages: @unchecked Sendable {
    let images: PageLayoutRenders.Images
}
