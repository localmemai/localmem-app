import Foundation

public enum ProcessUtility {
    /// Discovers the current working directory of the parent process on macOS.
    public static func getParentCWD() -> String? {
        let ppid = getppid()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-p", String(ppid), "-a", "-d", "cwd", "-Fn"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // Silence stderr
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let lines = output.components(separatedBy: .newlines)
                for line in lines {
                    if line.hasPrefix("n") {
                        let path = String(line.dropFirst())
                        if !path.isEmpty && FileManager.default.fileExists(atPath: path) {
                            return path
                        }
                    }
                }
            }
        } catch {
            // Silent fallback
        }
        return nil
    }

    /// Walk up from a directory to find the nearest parent directory containing a `.git` folder.
    public static func findGitRoot(from startPath: String) -> String? {
        var currentPath = startPath
        let fileManager = FileManager.default
        
        while !currentPath.isEmpty && currentPath != "/" {
            let gitPath = (currentPath as NSString).appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: gitPath, isDirectory: &isDirectory) && isDirectory.boolValue {
                return currentPath
            }
            currentPath = (currentPath as NSString).deletingLastPathComponent
        }
        return nil
    }
}
