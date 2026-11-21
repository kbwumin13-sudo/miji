import AppKit
import ApplicationServices

func value<T>(_ attribute: String, of element: AXUIElement, as type: T.Type) -> T? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
    return result as? T
}

func visibleMatch(in application: AXUIElement, filename: String) -> [String: String]? {
    var pending = value(kAXWindowsAttribute, of: application, as: [AXUIElement].self) ?? []
    var examined = Set<AXUIElement>()
    while let current = pending.popLast(), examined.count < 160 {
        guard examined.insert(current).inserted else { continue }
        let role = value(kAXRoleAttribute, of: current, as: String.self) ?? ""
        if role != kAXTextFieldRole && role != kAXWindowRole {
            for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                if let observed = value(attribute, of: current, as: String.self), observed.contains(filename) {
                    return ["role": role, "attribute": attribute, "value": observed]
                }
            }
        }
        let children = value(kAXChildrenAttribute, of: current, as: [AXUIElement].self) ?? []
        pending.append(contentsOf: children.reversed())
    }
    return nil
}

struct WindowCondition: Decodable {
    let id: String
    let present: String?
    let absent: String?
}

func inspectWindow(_ application: AXUIElement, query: String, candidates: Set<String>) -> (Bool, Set<String>) {
    var pending = value(kAXWindowsAttribute, of: application, as: [AXUIElement].self) ?? []
    var examined = Set<AXUIElement>()
    var foundQuery = false
    var results = Set<String>()
    while let current = pending.popLast(), examined.count < 160 {
        guard examined.insert(current).inserted else { continue }
        let role = value(kAXRoleAttribute, of: current, as: String.self) ?? ""
        if role == kAXTextFieldRole, value(kAXValueAttribute, of: current, as: String.self) == query {
            foundQuery = true
        }
        if role == kAXButtonRole,
           let name = value(kAXDescriptionAttribute, of: current, as: String.self)?.split(separator: "、").first,
           candidates.contains(String(name)) {
            results.insert(String(name))
        }
        let children = value(kAXChildrenAttribute, of: current, as: [AXUIElement].self) ?? []
        pending.append(contentsOf: children.reversed())
    }
    return (foundQuery, results)
}

func probeWindow(_ arguments: [String]) throws {
    guard arguments.count == 7, let pid = Int32(arguments[2]), let timeout = Double(arguments[3]), timeout > 0 else {
        fputs("usage: gui-probe window PID TIMEOUT_SECONDS QUERY ANCHOR CONDITIONS_JSON\n", stderr)
        exit(64)
    }
    let query = arguments[4]
    let anchor = arguments[5]
    let conditions = try JSONDecoder().decode([WindowCondition].self, from: Data(arguments[6].utf8))
    let application = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(application, 0.5)
    var candidates = Set(conditions.flatMap { [$0.present, $0.absent].compactMap { $0 } })
    candidates.insert(anchor)
    let started = ProcessInfo.processInfo.systemUptime
    var transitions: [String: UInt64] = [:]
    var samples = 0
    repeat {
        let (sameQuery, visible) = inspectWindow(application, query: query, candidates: candidates)
        let now = DispatchTime.now().uptimeNanoseconds
        samples += 1
        if sameQuery && visible.contains(anchor) {
            for condition in conditions where transitions[condition.id] == nil {
                if condition.present.map(visible.contains) ?? true, condition.absent.map({ !visible.contains($0) }) ?? true {
                    transitions[condition.id] = now
                }
            }
        }
        if transitions.count == conditions.count {
            let output: [String: Any] = ["visible_at_uptime_ns": transitions, "polls": samples, "anchor": anchor, "query": query]
            let encoded = try JSONSerialization.data(withJSONObject: output, options: .sortedKeys)
            print(String(decoding: encoded, as: UTF8.self))
            return
        }
        Thread.sleep(forTimeInterval: 0.05)
    } while ProcessInfo.processInfo.systemUptime - started < timeout
    let missing = conditions.filter { transitions[$0.id] == nil }.map(\.id)
    fputs("Timeout waiting for unchanged-query AX transitions: \(missing)\n", stderr)
    exit(1)
}

let arguments = CommandLine.arguments
if arguments.count == 2, arguments[1] == "clock" {
    print(DispatchTime.now().uptimeNanoseconds)
    exit(0)
}
if arguments.count > 1, arguments[1] == "window" {
    guard AXIsProcessTrusted() else {
        fputs("Accessibility access is unavailable for this process\n", stderr)
        exit(77)
    }
    try probeWindow(arguments)
    exit(0)
}
guard arguments.count == 4, let pid = Int32(arguments[1]), let timeout = Double(arguments[3]), timeout > 0 else {
    fputs("usage: gui-probe PID EXACT_FILENAME TIMEOUT_SECONDS\n", stderr)
    exit(64)
}
guard AXIsProcessTrusted() else {
    fputs("Accessibility access is unavailable for this process\n", stderr)
    exit(77)
}
let application = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(application, 0.5)
let began = ProcessInfo.processInfo.systemUptime
var samples = 0
repeat {
    samples += 1
    if let visible = visibleMatch(in: application, filename: arguments[2]) {
        let output: [String: Any] = ["matched": visible, "polls": samples,
                                     "secondsAfterProbeLaunch": ProcessInfo.processInfo.systemUptime - began]
        let encoded = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .fragmentsAllowed])
        print(String(decoding: encoded, as: UTF8.self))
        exit(0)
    }
    Thread.sleep(forTimeInterval: 0.05)
} while ProcessInfo.processInfo.systemUptime - began < timeout
fputs("Timed out waiting for the exact filename in a rendered AX result\n", stderr)
exit(1)
