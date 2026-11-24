import Foundation
import Security
import CryptoKit

/// 1:1 复刻自 Android `CertPinning.kt`（TOFU 证书指纹固定）：
/// 先按系统信任链正常校验；若为局域网 NAS 自签名 HTTPS 证书，仅当叶子证书 SHA-256 指纹与用户确认固定的指纹完全一致时才放行，绝不盲目信任一切证书。
public enum CertPinning {
    public struct UntrustedCertInfo: Sendable, Equatable {
        public let fingerprint: String
        public let host: String

        public init(fingerprint: String, host: String) {
            self.fingerprint = fingerprint
            self.host = host
        }
    }

    /// 首次遇到未信任的自签名 HTTPS 证书时抛出，供前端展示 SHA-256 指纹并由用户确认固定（TOFU）。
    public struct UntrustedCertError: LocalizedError, Sendable, Equatable {
        public let fingerprint: String
        public let host: String

        public init(fingerprint: String, host: String) {
            self.fingerprint = fingerprint
            self.host = host
        }

        public var errorDescription: String? {
            "服务器 \(host) 使用了系统未信任的证书（SHA-256：\(fingerprint)），请核对指纹后确认信任"
        }
    }

    /// 统一指纹格式：去掉空格/冒号并转大写，要求严格 64 位十六进制，按每两位以冒号分隔。
    public static func normalize(_ fp: String?) -> String? {
        guard let raw = fp else { return nil }
        let hex = raw.filter { $0.isLetter || $0.isNumber }.uppercased()
        guard hex.count == 64, hex.allSatisfy({ ("0"..."9").contains($0) || ("A"..."F").contains($0) }) else {
            return nil
        }
        var pairs: [String] = []
        pairs.reserveCapacity(32)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            pairs.append(String(hex[idx..<next]))
            idx = next
        }
        return pairs.joined(separator: ":")
    }

    public static func sha256Fingerprint(of derData: Data) -> String {
        SHA256.hash(data: derData).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    public static func leafFingerprint(from trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            return nil
        }
        let der = SecCertificateCopyData(leaf) as Data
        return sha256Fingerprint(of: der)
    }

    /// 构造绑定特定 SHA-256 证书指纹（及可选禁用自动重定向）的 URLSession 与代理句柄，便于调用方读取被拒证书指纹。
    public static func makeSessionWithDelegate(
        pinnedFingerprint: String?,
        followRedirects: Bool = true
    ) -> (session: URLSession, delegate: PinningSessionDelegate?) {
        let normalized = normalize(pinnedFingerprint)
        if normalized == nil && followRedirects {
            return (.shared, nil)
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 90
        let delegate = PinningSessionDelegate(pinnedFingerprint: normalized, followRedirects: followRedirects)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        return (session, delegate)
    }

    /// 构造绑定特定 SHA-256 证书指纹（及可选禁用自动重定向）的 URLSession（用于 WebDAV / 自签名 HTTPS NAS）。
    public static func makeSession(pinnedFingerprint: String?, followRedirects: Bool = true) -> URLSession {
        makeSessionWithDelegate(pinnedFingerprint: pinnedFingerprint, followRedirects: followRedirects).session
    }

    public final class PinningSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
        private let pinnedFingerprint: String?
        private let followRedirects: Bool
        private let lock = NSLock()
        private var _lastRejectedCert: UntrustedCertInfo?
        private var _lastPinFailureReason: String?
        public var lastRejectedCert: UntrustedCertInfo? {
            lock.lock(); defer { lock.unlock() }
            return _lastRejectedCert
        }
        public var lastPinFailureReason: String? {
            lock.lock(); defer { lock.unlock() }
            return _lastPinFailureReason
        }
        public func clearLastRejectedCert() {
            lock.lock(); _lastRejectedCert = nil; _lastPinFailureReason = nil; lock.unlock()
        }

        public init(pinnedFingerprint: String?, followRedirects: Bool = true) {
            self.pinnedFingerprint = pinnedFingerprint
            self.followRedirects = followRedirects
        }

        public func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(followRedirects ? request : nil)
        }

        public func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            // 1. 先尝试系统默认信任链验证
            var err: CFError?
            if SecTrustEvaluateWithError(trust, &err) {
                completionHandler(.useCredential, URLCredential(trust: trust))
                return
            }

            // 2. 系统不信任（如自签名 NAS 证书）时，严格核对叶子证书 SHA-256 指纹并使用基础 X.509 策略校验有效期（兼容无 IP SAN / 长有效期 NAS 证书，同时拒绝已过期证书）
            if let fp = CertPinning.leafFingerprint(from: trust) {
                if let pin = pinnedFingerprint, fp == pin {
                    if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                       let leaf = chain.first {
                        SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
                        SecTrustSetAnchorCertificates(trust, [leaf] as CFArray)
                        SecTrustSetAnchorCertificatesOnly(trust, true)
                        var pinErr: CFError?
                        if SecTrustEvaluateWithError(trust, &pinErr) {
                            completionHandler(.useCredential, URLCredential(trust: trust))
                            return
                        }
                        let reason = (pinErr as Error?)?.localizedDescription ?? "证书已过期或不符合 X.509 规范"
                        lock.lock(); _lastPinFailureReason = reason; lock.unlock()
                    } else {
                        lock.lock(); _lastPinFailureReason = "无法读取服务器叶子证书"; lock.unlock()
                    }
                    completionHandler(.cancelAuthenticationChallenge, nil)
                    return
                }
                lock.lock(); _lastRejectedCert = UntrustedCertInfo(fingerprint: fp, host: challenge.protectionSpace.host); lock.unlock()
            }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
