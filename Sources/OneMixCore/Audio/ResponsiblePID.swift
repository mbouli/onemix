import Darwin

/// Maps a helper process (e.g. Safari's WebKit GPU process) to the app responsible for it.
/// Uses the private `responsibility_get_pid_responsible_for_pid`, and falls back to the PID itself.
public enum ResponsiblePID {
    private typealias Function = @convention(c) (pid_t) -> pid_t

    private static let function: Function? = {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(rtldDefault, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }()

    public static func of(_ pid: pid_t) -> pid_t {
        guard let function else { return pid }
        let responsible = function(pid)
        return responsible > 0 ? responsible : pid
    }
}
