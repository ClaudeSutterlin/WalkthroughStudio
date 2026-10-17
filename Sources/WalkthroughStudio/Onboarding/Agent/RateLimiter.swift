// RateLimiter.swift — "Onboard to a Codebase", milestone M6 (LLM runtime).
//
// Everything about *when* to try again (ARCHITECTURE 4.5). Deliberately split:
//
//   RateLimiter      pure decisions and arithmetic — what is retryable, how long to wait
//   CircuitBreaker   shared state across units — stop the fleet when the API is gone
//
// The arithmetic is a value type with injectable jitter and an injectable sleep so
// `backoffProbe` can walk the whole ladder, including a 429 that carries
// retry-after and a 400 that must not be retried at all, in no time at all. A
// retry policy that can only be tested by waiting is a retry policy nobody tests.

import Foundation

/// Suspends for `seconds`. Injected so a probe can assert the ladder without
/// living through it.
typealias AgentSleep = @Sendable (Double) async throws -> Void

/// Suspends by actually sleeping.
let agentRealSleep: AgentSleep = { seconds in
    guard seconds > 0 else { return }
    try await Task.sleep(nanoseconds: UInt64(min(seconds, 600) * 1_000_000_000))
}

struct RateLimiter: Sendable, Equatable {
    /// Attempts per *request* (ARCHITECTURE 4.5). The sixth failure is reported.
    var maxAttempts: Int = 6
    /// First wait, doubling from there.
    var baseDelay: Double = 1
    /// Ceiling on our own backoff ladder.
    var maxDelay: Double = 32
    /// A server's `retry-after` is honored above `maxDelay`, but not without limit:
    /// past this, the run stops and says so rather than appearing to hang. Someone
    /// watching a progress view deserves to know the wait is minutes, not seconds.
    var maxRetryAfter: Double = 120
    /// Jitter spread, as a fraction of the delay. Two units retrying in lockstep
    /// after a shared 429 would just collide again.
    var jitterFraction: Double = 0.25
    /// Attempts per *unit* before it is marked failed and its dependents skipped.
    var maxUnitAttempts: Int = 3
    /// Consecutive transport failures that trip the breaker.
    var breakerThreshold: Int = 5

    init() {}

    /// Whether another attempt is worth making.
    ///
    /// Retryable: a broken connection (any URLError), 429, 529, and any 5xx.
    /// Not retryable: everything the server decided on purpose — a malformed
    /// request, a rejected key, a model that does not exist. Retrying those burns
    /// six attempts and six times the latency to arrive at the same answer.
    func isRetryable(_ error: MessagesAPIError) -> Bool {
        if error.isTransport { return true }
        if error.status == 429 || error.status == 529 { return true }
        if error.status >= 500 && error.status <= 599 { return true }
        return false
    }

    /// Whether to make attempt number `attempt + 1`, given what just failed.
    func shouldRetry(_ error: MessagesAPIError, afterAttempt attempt: Int) -> Bool {
        guard attempt < maxAttempts else { return false }
        guard isRetryable(error) else { return false }
        if let retryAfter = error.retryAfter, retryAfter > maxRetryAfter { return false }
        return true
    }

    /// Seconds to wait before attempt `attempt + 1`. `attempt` is 1-based: the
    /// wait after the first failure is `baseDelay`.
    ///
    /// `jitter` is a 0...1 value supplied by the caller (`Double.random(in: 0...1)`
    /// in production, a fixed sequence in the probe). A server's `retry-after` is a
    /// floor, never a ceiling: waiting less than it was asked for is how a client
    /// earns a longer ban.
    func delay(afterAttempt attempt: Int, retryAfter: Double?, jitter: Double) -> Double {
        let exponent = max(0, attempt - 1)
        let doubled = baseDelay * pow(2, Double(min(exponent, 16)))
        let capped = min(doubled, maxDelay)
        let spread = capped * jitterFraction
        let clampedJitter = min(max(jitter, 0), 1)
        let jittered = capped - spread + (2 * spread * clampedJitter)
        guard let retryAfter, retryAfter.isFinite, retryAfter > 0 else {
            return max(0, jittered)
        }
        return min(max(jittered, retryAfter), maxRetryAfter)
    }

    /// The whole ladder for a run of failures, for the probe and for the docs.
    func ladder(jitter: Double = 0.5) -> [Double] {
        (1..<maxAttempts).map { delay(afterAttempt: $0, retryAfter: nil, jitter: jitter) }
    }
}

/// Stops the fleet when the API has gone away, instead of letting forty units each
/// spend six attempts discovering it.
///
/// Only *transport* failures count. A run of 429s means the key works and the
/// service is up — backing off is the right answer and the breaker must stay shut,
/// or a busy account would look like an outage.
actor CircuitBreaker {
    private let threshold: Int
    private var consecutiveTransportFailures = 0
    private(set) var isTripped = false

    init(threshold: Int = 5) {
        self.threshold = max(1, threshold)
    }

    /// Any reply at all — including an error the server chose to send — means the
    /// API is reachable.
    func recordReachable() {
        consecutiveTransportFailures = 0
    }

    /// Returns true when this failure trips the breaker.
    @discardableResult
    func recordTransportFailure() -> Bool {
        consecutiveTransportFailures += 1
        if consecutiveTransportFailures >= threshold {
            isTripped = true
            return true
        }
        return false
    }

    /// What Resume does.
    func reset() {
        consecutiveTransportFailures = 0
        isTripped = false
    }

    var failureCount: Int { consecutiveTransportFailures }

    static let trippedNotice = "Paused: API unreachable. Resume when ready."
}
