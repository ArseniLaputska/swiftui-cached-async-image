//
//  File.swift
//  swiftui-cached-async-image
//
//  Created by Arseni Laputska on 18.11.24.
//

import SwiftUI

@available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
public struct CachedAsyncUIImage<Content>: View where Content: View {
    
    @State private var phase: AsyncUIImagePhase = .empty
    
    private let urlRequest: URLRequest?
    private let url: URL?
    
    private let urlSession: URLSession
    
    private let scale: CGFloat
    
    private let transaction: Transaction
    
    private var content: (AsyncUIImagePhase) -> Content
    
    public var body: some View {
        content(phase)
            .task(id: urlRequest, load)
    }

    public init(url: URL?, urlCache: URLCache = .shared, scale: CGFloat = 1, transaction: Transaction = Transaction(), @ViewBuilder content: @escaping (AsyncUIImagePhase) -> Content) {
        let urlRequest = url == nil ? nil : URLRequest(url: url!)
        self.init(urlRequest: urlRequest, urlCache: urlCache, scale: scale, transaction: transaction, content: content)
    }
    
    /// Loads and displays a modifiable image from the specified URL in phases.
    ///
    /// If you set the asynchronous image's URL to `nil`, or after you set the
    /// URL to a value but before the load operation completes, the phase is
    /// ``AsyncImagePhase/empty``. After the operation completes, the phase
    /// becomes either ``AsyncImagePhase/failure(_:)`` or
    /// ``AsyncImagePhase/success(_:)``. In the first case, the phase's
    /// ``AsyncImagePhase/error`` value indicates the reason for failure.
    /// In the second case, the phase's ``AsyncImagePhase/image`` property
    /// contains the loaded image. Use the phase to drive the output of the
    /// `content` closure, which defines the view's appearance:
    ///
    ///     CachedAsyncImage(url: URL(string: "https://example.com/icon.png")) { phase in
    ///         if let image = phase.image {
    ///             image // Displays the loaded image.
    ///         } else if phase.error != nil {
    ///             Color.red // Indicates an error.
    ///         } else {
    ///             Color.blue // Acts as a placeholder.
    ///         }
    ///     }
    ///
    /// To add transitions when you change the URL, apply an identifier to the
    /// ``CachedAsyncImage``.
    ///
    /// - Parameters:
    ///   - urlRequest: The URL request of the image to display.
    ///   - urlCache: The URL cache for providing cached responses to requests within the session.
    ///   - scale: The scale to use for the image. The default is `1`. Set a
    ///     different value when loading images designed for higher resolution
    ///     displays. For example, set a value of `2` for an image that you
    ///     would name with the `@2x` suffix if stored in a file on disk.
    ///   - transaction: The transaction to use when the phase changes.
    ///   - content: A closure that takes the load phase as an input, and
    ///     returns the view to display for the specified phase.

    public init(urlRequest: URLRequest?, urlCache: URLCache = .shared, scale: CGFloat = 1, transaction: Transaction = Transaction(), @ViewBuilder content: @escaping (AsyncUIImagePhase) -> Content) {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = urlCache
        self.urlRequest = urlRequest
        self.url = urlRequest?.url
        self.urlSession =  URLSession(configuration: configuration)
        self.scale = scale
        self.transaction = transaction
        self.content = content
        
        self._phase = State(wrappedValue: .empty)
        do {
            if isLocal {
                loadLocally()
            } else {
                if let urlRequest = urlRequest, let image = try cachedImage(from: urlRequest, cache: urlCache) {
                    self._phase = State(wrappedValue: .success(image))
                }
            }
        } catch {
            self._phase = State(wrappedValue: .failure(error))
        }
    }
    
    private var isLocal: Bool {
        guard let url else { return false }
        return url.scheme == "file" || url.scheme == "base64"
    }
    
    private func loadLocally() {
        if #available(iOS 16.0, *) {
            if let url, url.scheme == "file" {
                if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                    phase = .success(image)
                    return
                }
            }
            
            if let url, url.scheme == "base64" {
                let base64String = String(url.absoluteString.trimmingPrefix("base64://"))
                if let data = Data(base64Encoded: base64String), let image = UIImage(data: data) {
                    phase = .success(image)
                    return
                }
            }
        }
    }
    
    @Sendable
    private func load() async {
        guard !isLocal else { return }
        do {
            if let urlRequest = urlRequest {
                let (image, metrics) = try await remoteImage(from: urlRequest, session: urlSession)
                if metrics.transactionMetrics.last?.resourceFetchType == .localCache {
                    // WARNING: This does not behave well when the url is changed with another
                    phase = .success(image)
                } else {
                    withAnimation(transaction.animation) {
                        phase = .success(image)
                    }
                }
            } else {
                withAnimation(transaction.animation) {
                    phase = .empty
                }
            }
        } catch {
            withAnimation(transaction.animation) {
                phase = .failure(error)
            }
        }
    }
}

@available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
private extension CachedAsyncUIImage {
    private func remoteImage(from request: URLRequest, session: URLSession) async throws -> (UIImage, URLSessionTaskMetrics) {
        let (data, _, metrics) = try await session.data(for: request)
        if metrics.redirectCount > 0, let lastResponse = metrics.transactionMetrics.last?.response {
            let requests = metrics.transactionMetrics.map { $0.request }
            requests.forEach(session.configuration.urlCache!.removeCachedResponse)
            let lastCachedResponse = CachedURLResponse(response: lastResponse, data: data)
            session.configuration.urlCache!.storeCachedResponse(lastCachedResponse, for: request)
        }
        return (try uiImage(from: data), metrics)
    }

    private func cachedImage(from request: URLRequest, cache: URLCache) throws -> UIImage? {
        guard let cachedResponse = cache.cachedResponse(for: request) else { return nil }
        return try uiImage(from: cachedResponse.data)
    }

    private func uiImage(from data: Data) throws -> UIImage {
#if os(macOS)
        if let nsImage = NSImage(data: data) {
            return nsImage
        } else {
            throw AsyncImage<Content>.LoadingError()
        }
#else
        if let uiImage = UIImage(data: data, scale: scale) {
            return uiImage
        } else {
            throw AsyncImage<Content>.LoadingError()
        }
#endif
    }
}
