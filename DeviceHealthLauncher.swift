import AppKit

extension Launcher {
    func configureDeviceHealth() {
        deviceHealth.usePhone(phoneSerial)
        deviceHealth.onChange = { [weak self] in self?.refreshDeviceHealth() }
        bridge.onDevice = { [weak self] info in
            guard let self else { return }; self.deviceHealth.usePhone(phoneSerial); self.deviceHealth.update(info)
        }
    }

    func refreshDeviceHealth() {
        deviceHealth.connectionState(bridge.syncHealthy || adbVerified(within: 12))
        deviceHealth.adbConnected = adbVerified(within: 12)
        deviceHealth.cameraInstalled = calls.cameraSetupAvailable
        deviceHealth.microphoneInstalled = calls.microphoneSetupAvailable
        deviceHealth.mirrorLive = mirror?.isRunning == true && sawVideo
        deviceHealth.cameraLive = calls.camera == .active
        deviceHealth.microphoneLive = calls.microphone == .active
        deviceHealth.screenOffLive = phoneScreenOff && screenOffGuardActive && mirror?.isRunning == true && sawVideo
        deviceHealth.audioLive = deviceHealth.audioLive && audioEnabled && mirror?.isRunning == true
        deviceHealthWindow?.render(deviceHealth, checking: healthChecking)
        if let data = deviceHealth.report, data != lastHealthReport || -lastHealthReportTime.timeIntervalSinceNow > 15 {
            lastHealthReport = data; lastHealthReportTime = Date(); bridge.sendDeviceReport(data)
        }
    }

    @objc func showDeviceHealth() {
        popover.performClose(nil)
        if deviceHealthWindow == nil {
            let panel = DeviceHealthWindow()
            panel.onCheck = { [weak self] in self?.checkDeviceHealth(force: true) }
            panel.onDetails = { [weak self] feature in self?.showFeatureIssue(feature, details: true) }
            deviceHealthWindow = panel
        }
        refreshDeviceHealth(); deviceHealthWindow?.open()
        if deviceHealth.info == nil { checkDeviceHealth() }
    }

    func showFeatureIssue(_ feature: DeviceFeature, details: Bool = false) {
        refreshDeviceHealth()
        let status = deviceHealth.status(feature)
        guard details || status.state == "red" || status.label == "Not checked" else { return }
        let alert = NSAlert(); alert.messageText = feature.title + " · " + status.label
        alert.informativeText = status.reason + (status.nextStep.isEmpty ? "" : "\n\n" + status.nextStep)
        alert.alertStyle = status.state == "red" ? .warning : .informational
        alert.addButton(withTitle: "OK")
        if let owner = NSApp.keyWindow, !(owner is NSPanel), owner.isVisible, owner.attachedSheet == nil {
            alert.beginSheetModal(for: owner)
        } else if NSApp.isActive || details { NSApp.activate(ignoringOtherApps: true); alert.runModal() }
    }

    func featureFailed(_ feature: DeviceFeature, _ message: String, show: Bool = false) {
        let lower = message.lowercased()
        let next: String
        if lower.contains("changed") || lower.contains("no longer") { next = "Refresh the library, select the current file and try again. The phone or source changed since it was listed." }
        else if feature == .gallery && (lower.contains("preview") || lower.contains("decode")) { next = "This phone could not create a preview for that file. Use Open Original or Save to Mac to view the original. Other files can still work." }
        else if feature == .camera { next = "Close other apps using the phone camera. Check Camera & Microphone Setup on the Mac, then start again." }
        else { next = "Reconnect the paired phone and try again. If permission is mentioned, unlock the phone and approve this Mac." }
        deviceHealth.record(feature, success: false, reason: message,
            nextStep: next)
        if show { showFeatureIssue(feature) }
    }

    func readDeviceInfo(_ serial: String, completion: @escaping (Bool) -> Void) {
        let identity = phoneSerial
        DispatchQueue.global(qos: .utility).async {
            let verified = command(["-s", serial, "shell", "getprop", "ro.serialno"], timeout: 4)
            guard verified.code == 0, verified.output.trimmingCharacters(in: .whitespacesAndNewlines) == identity else {
                DispatchQueue.main.async { completion(false) }; return
            }
            let properties = command(["-s", serial, "shell", "getprop"], timeout: 5)
            var values: [String: String] = [:]
            for line in properties.output.split(separator: "\n") {
                for key in ["ro.product.manufacturer", "ro.product.model", "ro.build.version.release", "ro.build.version.sdk"] {
                    let prefix = "[" + key + "]: ["
                    if line.hasPrefix(prefix), line.hasSuffix("]") { values[key] = String(line.dropFirst(prefix.count).dropLast()) }
                }
            }
            let sdk = Int(values["ro.build.version.sdk"] ?? "") ?? 0
            let info = PhoneDeviceInfo(model: (values["ro.product.manufacturer"] ?? "Android") + " " + (values["ro.product.model"] ?? "phone"),
                android: values["ro.build.version.release"] ?? "unknown", sdk: sdk, hasCamera: true, hasMicrophone: true,
                notificationAccess: false, notificationEnabled: true, touchGuard: false)
            DispatchQueue.main.async {
                guard phoneSerial == identity, self.currentSerial == serial, properties.code == 0, info.valid else { completion(false); return }
                noteADBVerified()
                if self.deviceHealth.info == nil { self.deviceHealth.update(info) }
                completion(true)
            }
        }
    }

    func withDeviceFeature(_ feature: DeviceFeature, action: @escaping () -> Void) {
        if deviceHealth.info != nil {
            if deviceHealth.unsupported(feature) { showFeatureIssue(feature, details: true); return }
            action(); return
        }
        guard !deviceProbeBusy, let serial = currentSerial else {
            featureFailed(feature, "The phone's Android version could not be checked. Reconnect the paired phone before starting this feature.", show: true); return
        }
        deviceProbeBusy = true
        readDeviceInfo(serial) { [weak self] ok in
            guard let self else { return }; self.deviceProbeBusy = false
            if ok { self.withDeviceFeature(feature, action: action) }
            else { self.featureFailed(feature, "Could not read this phone's Android version. Unlock it, approve debugging for this Mac and reconnect.", show: true) }
        }
    }

    @objc func checkDeviceHealth(force: Bool = false) {
        guard !healthChecking, let serial = currentSerial, !phoneSerial.isEmpty else { refreshDeviceHealth(); return }
        let identity = phoneSerial
        if force { deviceHealth.resetChecks() }
        healthChecking = true; healthCheckGeneration = UUID(); let generation = healthCheckGeneration
        healthCheckCancellation?.cancel(); let cancellation = PhoneFileCancellation(); healthCheckCancellation = cancellation
        refreshDeviceHealth()
        readDeviceInfo(serial) { [weak self] ok in
            guard let self else { return }
            guard self.healthCheckGeneration == generation else { return }
            guard ok else { self.healthChecking = false; self.checkedHealthSerial = nil; self.refreshDeviceHealth(); return }
            DispatchQueue.global(qos: .utility).async {
                var results: [(DeviceFeature, Result<String, Error>)] = []
                do {
                    let connection = try self.phoneFilesClient.connect(serial: serial, identity: identity)
                    for feature in [DeviceFeature.files, .gallery] {
                        let result = Result { () -> String in
                            var counts: [String] = []
                            for mode in feature == .files ? ["list"] : ["photo", "video", "audio"] {
                                try cancellation.check()
                                let list = try self.phoneFilesClient.list(connection, path: "", mode: mode, cancel: cancellation)
                                counts.append("\(mode): \(list.items.count.formatted())")
                            }
                            return feature == .files ? "Shared storage is readable (\(counts.joined(separator: ", "))). Transfers are verified when used."
                                : "Media listings checked: \(counts.joined(separator: ", ")). Previews and originals are validated when opened."
                        }
                        results.append((feature, result))
                    }
                } catch { results = [(.files, .failure(error)), (.gallery, .failure(error))] }
                DispatchQueue.main.async {
                    guard self.healthCheckGeneration == generation else { return }
                    self.healthChecking = false; self.healthCheckCancellation = nil
                    guard phoneSerial == identity, self.currentSerial == serial else { self.refreshDeviceHealth(); return }
                    self.checkedHealthSerial = serial
                    for (feature, result) in results {
                        switch result {
                        case .success(let reason):
                            if feature == .files { self.deviceHealth.ready(feature, reason: reason) }
                            else { self.deviceHealth.record(feature, success: true, reason: reason) }
                        case .failure(let error): self.featureFailed(feature, error.localizedDescription)
                        }
                    }
                    self.refreshDeviceHealth()
                }
            }
        }
    }
}
