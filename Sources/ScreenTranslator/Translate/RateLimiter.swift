import Foundation

/// Token bucket theo phút (cửa sổ trượt) + bộ đếm theo ngày (reset 00:00 giờ Pacific, như quota Gemini).
actor RateLimiter {
    var rpm: Int
    var rpd: Int

    private var minuteStamps: [Date] = []
    private var dayKey: String = ""
    private var dayCount: Int = 0
    private var cooldownUntil: Date?

    private static let pacific = TimeZone(identifier: "America/Los_Angeles")!
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = pacific; return f
    }()

    init(rpm: Int, rpd: Int) {
        self.rpm = rpm; self.rpd = rpd
        dayKey = Self.dayFmt.string(from: Date())
        dayCount = UserDefaults.standard.integer(forKey: "rpd.\(dayKey)")
    }

    func configure(rpm: Int, rpd: Int) { self.rpm = rpm; self.rpd = rpd }

    private func rollDay() {
        let key = Self.dayFmt.string(from: Date())
        if key != dayKey {
            dayKey = key
            dayCount = UserDefaults.standard.integer(forKey: "rpd.\(key)")
        }
    }

    enum Denial { case cooldown(TimeInterval), minute, day }

    /// Trả về nil nếu được phép (và đã trừ token), ngược lại lý do từ chối.
    func acquire() -> Denial? {
        rollDay()
        let now = Date()
        if let c = cooldownUntil {
            if now < c { return .cooldown(c.timeIntervalSince(now)) }
            cooldownUntil = nil
        }
        minuteStamps.removeAll { now.timeIntervalSince($0) > 60 }
        if minuteStamps.count >= rpm { return .minute }
        if dayCount >= rpd { return .day }
        minuteStamps.append(now)
        dayCount += 1
        UserDefaults.standard.set(dayCount, forKey: "rpd.\(dayKey)")
        return nil
    }

    func reportRateLimited(retryAfter: TimeInterval?) {
        cooldownUntil = Date().addingTimeInterval(retryAfter ?? 60)
    }

    var usedToday: Int { rollDay(); return dayCount }
    var cooldownRemaining: TimeInterval? {
        guard let c = cooldownUntil else { return nil }
        let r = c.timeIntervalSinceNow
        return r > 0 ? r : nil
    }
}
