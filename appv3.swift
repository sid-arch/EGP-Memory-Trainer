import SwiftUI
import Speech
import AVFoundation
import AVFAudio

// ============================================================
// EGP Memory Trainer (Euler / Gold / Pi)
// Live speech → Monkeytype-style grading (green/red)
// Vertical transcript with wrap, auto-scroll to bottom
// Orange "–" pause token when gap > 2.0s
// Auto-end at 10 wrong; results + persistent logs per constant
// Deletion: swipe-to-delete items + Clear All button
// Fuzzy matching to handle speech recognition gaps
// ============================================================

// MARK: - Digit sequences (REPLACE with your 1000-digit strings)
let PI_DIGITS  = "31415926535897932384626433832795028841971693993751058209749445923078164062862089986280348253421170679821480865132823066470938446095505822317253594081284811174502841027019385211055596446229489549303819644288109756659334461284756482337867831652712019091456485669234603486104543266482133936072602491412737245870066063155881748815209209628292540917153643678925903600113305305488204665213841469519415116094330572703657595919530921861173819326117931051185480744623799627495673518857527248912279381830119491298336733624406566430860213949463952247371907021798609437027705392171762931767523846748184676694051320005681271452635608277857713427577896091736371787214684409012249534301465495853710507922796892589235420199561121290219608640344181598136297747713099605187072113499999983729780499510597317328160963185950244594553469083026425223082533446850352619311881710100031378387528865875332083814206171776691473035982534904287554687311595628638823537875937519577818577805321712268066130019278766111959092164201989"   // Replace with full Pi digits (include leading 3)
let PHI_DIGITS = "16180339887498948482045868343656381177203091798057628621354486227052604628189024497072072041893911374847540880753868917521266338622235369317931800607667263544333890865959395829056383226613199282902678806752087668925017116962070322210432162695486262963136144381497587012203408058879544547492461856953648644492410443207713449470495658467885098743394422125448770664780915884607499887124007652170575179788341662562494075890697040002812104276217711177780531531714101170466659914669798731761356006708748071013179523689427521948435305678300228785699782977834784587822891109762500302696156170025046433824377648610283831268330372429267526311653392473167111211588186385133162038400522216579128667529465490681131715993432359734949850904094762132229810172610705961164562990981629055520852479035240602017279974717534277759277862561943208275051312181562855122248093947123414517022373580577278616008688382952304592647878017889921990270776903895321968198615143780314997411069260886742962267575605231727775203536139362"   // Replace with full Phi digits (include leading 1)
let E_DIGITS   = "2718281828459045235360287471352662497757247093699959574966967627724076630353547594571382178525166427427466391932003059921817413596629043572900334295260595630738132328627943490763233829880753195251019011573834187930702154089149934884167509244761460668082264800168477411853742345442437107539077744992069551702761838606261331384583000752044933826560297606737113200709328709127443747047230696977209310141692836819025515108657463772111252389784425056953696770785449969967946864454905987931636889230098793127736178215424999229576351482208269895193668033182528869398496465105820939239829488793320362509443117301238197068416140397019837679320683282376464804295311802328782509819455815301756717361332069811250996181881593041690351598888519345807273866738589422879228499892086805825749279610484198444363463244968487560233624827041978623209002160990235304369941849146314093431738143640546253152096183690888707016768396424378140592714563549061303107208510383750510115747704171"   // Replace with full e digits (include leading 2)

// Pause threshold (seconds) between digits → insert orange "–"
let PAUSE_THRESHOLD: TimeInterval = 2.0

// MARK: - Models

enum ConstantKind: String, Codable, CaseIterable, Identifiable {
    case e = "e", phi = "φ", pi = "π"        // order here isn't the tab order; just identifiers
    var id: String { rawValue }

    var title: String { rawValue }
    var target: String {
        switch self {
        case .pi:  return PI_DIGITS
        case .phi: return PHI_DIGITS
        case .e:   return E_DIGITS
        }
    }
    // ASCII filenames so we don't put π/φ in disk names
    var fileName: String {
        switch self {
        case .pi:  return "pi_sessions.json"
        case .phi: return "phi_sessions.json"
        case .e:   return "e_sessions.json"
        }
    }
    // Tab labels as requested
    var tabLabel: String {
        switch self {
        case .e:   return "Euler"
        case .phi: return "Gold"
        case .pi:  return "Pi"
        }
    }
}

enum TokenKind: Codable {
    case digit(d: String, correct: Bool)
    case pause // render as "–" in orange
}

struct GradedToken: Identifiable, Codable {
    let id: UUID
    let kind: TokenKind

    init(id: UUID = UUID(), kind: TokenKind) {
        self.id = id
        self.kind = kind
    }
}

struct SessionRecord: Identifiable, Codable {
    let id: UUID
    let constant: ConstantKind
    let startDate: Date
    let durationSec: Double
    let digitsRecited: Int
    let correct: Int
    let wrong: Int
    let pauses: Int
    let accuracy: Double   // 0.0 ... 1.0
    let tokens: [GradedToken]

    init(
        id: UUID = UUID(),
        constant: ConstantKind,
        startDate: Date,
        durationSec: Double,
        digitsRecited: Int,
        correct: Int,
        wrong: Int,
        pauses: Int,
        accuracy: Double,
        tokens: [GradedToken]
    ) {
        self.id = id
        self.constant = constant
        self.startDate = startDate
        self.durationSec = durationSec
        self.digitsRecited = digitsRecited
        self.correct = correct
        self.wrong = wrong
        self.pauses = pauses
        self.accuracy = accuracy
        self.tokens = tokens
    }
}

// MARK: - Persistent store (JSON per constant)

final class SessionStore: ObservableObject {
    @Published var records: [ConstantKind: [SessionRecord]] = [
        .pi: [], .phi: [], .e: []
    ]

    init() {
        // load all at startup
        [.pi, .phi, .e].forEach { kind in
            self.records[kind] = load(kind) ?? []
        }
    }

    func add(_ record: SessionRecord) {
        var arr = records[record.constant] ?? []
        arr.insert(record, at: 0) // newest first
        records[record.constant] = arr
        save(record.constant)
    }

    func remove(kind: ConstantKind, at offsets: IndexSet) {
        guard var arr = records[kind] else { return }
        arr.remove(atOffsets: offsets)
        records[kind] = arr
        save(kind)
    }

    func clear(kind: ConstantKind) {
        records[kind] = []
        save(kind)
    }

    // File IO
    private func url(for kind: ConstantKind) -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent(kind.fileName)
    }

    private func save(_ kind: ConstantKind) {
        do {
            let arr = records[kind] ?? []
            let data = try JSONEncoder().encode(arr)
            try data.write(to: url(for: kind), options: [.atomic])
        } catch {
            print("Save error [\(kind)]: \(error)")
        }
    }

    private func load(_ kind: ConstantKind) -> [SessionRecord]? {
        let path = url(for: kind)
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        do {
            let data = try Data(contentsOf: path)
            return try JSONDecoder().decode([SessionRecord].self, from: data)
        } catch {
            print("Load error [\(kind)]: \(error)")
            return []
        }
    }
}

// MARK: - Speech recognizer (digits only)

final class DigitSpeechRecognizer: ObservableObject {
    @Published private(set) var isRecording = false

    private let recognizer: SFSpeechRecognizer? = {
        let r = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        if #available(iOS 16.0, *) { r?.defaultTaskHint = .dictation }
        return r
    }()

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    // dedupe partial segments
    private var lastSegmentTimestamp: TimeInterval = -1

    // callback for recognized digit "0"..."9"
    var onDigit: ((String) -> Void)?

    func start() {
        // Permissions
        SFSpeechRecognizer.requestAuthorization { _ in }
        if #available(iOS 17.0, *) {
            if AVAudioApplication.shared.recordPermission == .undetermined {
                AVAudioApplication.requestRecordPermission { _ in }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { _ in }
        }

        if audioEngine.isRunning { stop() } // clean restart

        lastSegmentTimestamp = -1
        isRecording = true

        // Low-latency audio session
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? session.setPreferredSampleRate(44_100)
        try? session.setPreferredIOBufferDuration(0.005)
        try? session.setActive(true, options: .notifyOthersOnDeactivation)

        // Request
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if #available(iOS 13.0, *) { req.requiresOnDeviceRecognition = false }
        self.request = req

        // Mic tap
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 256, format: format) { [weak self] buf, _ in
            self?.request?.append(buf)
        }

        audioEngine.prepare()
        try? audioEngine.start()

        // Recognition task
        task = recognizer?.recognitionTask(with: req) { [weak self] result, _ in
            guard let self = self else { return }
            guard self.isRecording else { return }
            guard let res = result, let seg = res.bestTranscription.segments.last else { return }

            // Deduplicate repeated partial callbacks
            if seg.timestamp == self.lastSegmentTimestamp { return }

            let token = seg.substring.lowercased().trimmingCharacters(in: .whitespaces)
            guard let digit = Self.mapToDigit(token) else { return }

            self.lastSegmentTimestamp = seg.timestamp
            DispatchQueue.main.async {
                self.onDigit?(digit)
            }
        }
    }

    func stop() {
        isRecording = false
        audioEngine.stop()
        request?.endAudio()
        task?.cancel()
        audioEngine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        task = nil
        request = nil
    }

    private static func mapToDigit(_ token: String) -> String? {
        switch token {
        case "zero", "0": return "0"
        case "one", "1": return "1"
        case "two", "2": return "2"
        case "three", "3": return "3"
        case "four", "4": return "4"
        case "five", "5": return "5"
        case "six", "6": return "6"
        case "seven", "7": return "7"
        case "eight", "8": return "8"
        case "nine", "9": return "9"
        default: return nil
        }
    }
}

// MARK: - App Shell

struct ContentView: View {
    @StateObject private var store = SessionStore()

    var body: some View {
        TabView {
            // ORDER: Euler, Gold, Pi
            TrainerView(constant: .e, store: store)
                .tabItem { Image(systemName: "circle.righthalf.fill"); Text(ConstantKind.e.tabLabel) }

            TrainerView(constant: .phi, store: store)
                .tabItem { Image(systemName: "circle.lefthalf.fill"); Text(ConstantKind.phi.tabLabel) }

            TrainerView(constant: .pi, store: store)
                .tabItem { Image(systemName: "circle.fill"); Text(ConstantKind.pi.tabLabel) }
        }
    }
}

// MARK: - Trainer Screen

struct TrainerView: View {
    let constant: ConstantKind
    @ObservedObject var store: SessionStore

    // Live session state
    @State private var digitCount = 0
    @State private var transcript: [GradedToken] = []
    @State private var correct = 0
    @State private var wrong = 0
    @State private var pauses = 0
    @State private var isSessionActive = false

    // Target sequence
    @State private var targetDigits: [String] = []

    // Timing
    @State private var lastDigitTime: Date?
    @State private var sessionStart: Date?

    // Speech
    @StateObject private var recognizer = DigitSpeechRecognizer()

    // Results
    @State private var showResults = false
    @State private var lastRecord: SessionRecord?

    // For auto-scrolling transcript downward
    @State private var bottomAnchor: UUID = UUID()

    var body: some View {
        VStack(spacing: 18) {

            // Main area: Left (trainer) + Right (log)
            HStack(alignment: .top, spacing: 24) {

                // LEFT: Title, counter, downward transcript
                VStack(spacing: 24) {
                    Text("\(constant.title) Trainer")
                        .font(.largeTitle).bold()

                    Text("\(digitCount)")
                        .font(.system(size: 120, weight: .bold))
                        .foregroundColor(.yellow)
                        .lineLimit(1)
                        .minimumScaleFactor(0.3)

                    // Vertical transcript that wraps; auto-scroll to bottom
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(attributedTokens(transcript))
                                    .font(.title2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Color.clear.frame(height: 1).id(bottomAnchor) // anchor
                            }
                            .padding(.horizontal)
                        }
                        .frame(height: 220)
                        .background(Color.black.opacity(0.05))
                        .cornerRadius(10)
                        .onChange(of: transcript.count) {
                            withAnimation { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)

                // RIGHT: Session Log + Clear All + swipe-to-delete
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Session Log")
                            .font(.title2).bold()
                        Spacer()
                        Button {
                            store.clear(kind: constant)
                        } label: {
                            Label("Clear All", systemImage: "trash")
                                .labelStyle(.iconOnly)
                                .foregroundColor(.red)
                                .padding(8)
                        }
                        .accessibilityLabel("Clear All Sessions")
                    }

                    if let list = store.records[constant], !list.isEmpty {
                        // Use List for swipe-to-delete
                        List {
                            ForEach(list) { rec in
                                SessionRow(record: rec)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        lastRecord = rec
                                        showResults = true
                                    }
                            }
                            .onDelete { offsets in
                                store.remove(kind: constant, at: offsets)
                            }
                        }
                        .listStyle(.plain)
                        .frame(minWidth: 360, maxWidth: 420, maxHeight: .infinity)
                    } else {
                        Text("No sessions yet.")
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: 420, maxHeight: .infinity, alignment: .topLeading)
            }

            // STATS (moved to bottom)
            HStack(spacing: 28) {
                StatBox(title: "Correct", value: "\(correct)", color: .green)
                StatBox(title: "Wrong",   value: "\(wrong)",   color: .red)
                StatBox(title: "Pauses",  value: "\(pauses)",  color: .orange)
                let acc = digitCount > 0 ? Int(round(Double(correct)/Double(digitCount)*100)) : 0
                StatBox(title: "Accuracy", value: "\(acc)%", color: .blue)
            }
            .padding(.top, 6)

            // Controls row (bottom-most)
            HStack(spacing: 20) {
                Button(isSessionActive ? "End Session" : "Start Session") {
                    isSessionActive ? endSession(auto: false) : startSession()
                }
                .font(.title2)
                .padding()
                .frame(width: 220, height: 56)
                .background(isSessionActive ? Color.red : Color.green)
                .foregroundColor(.white)
                .cornerRadius(14)

                Button("Reset") { resetSession() }
                    .font(.title2)
                    .padding()
                    .frame(width: 140, height: 56)
                    .background(Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(14)
            }
            .padding(.top, 2)
        }
        .padding()
        .onAppear {
            // Build target once
            targetDigits = constant.target.map { String($0) }
            // Wire callback
            recognizer.onDigit = { digit in processIncomingDigit(digit) }
        }
        .sheet(isPresented: $showResults) {
            if let rec = lastRecord {
                ResultsView(record: rec)
                    .presentationDetents([.medium, .large])
            } else { Text("No record.") }
        }
    }

    // MARK: - Lifecycle

    private func startSession() {
        digitCount = 0
        transcript.removeAll()
        correct = 0
        wrong = 0
        pauses = 0
        lastDigitTime = nil
        sessionStart = Date()
        isSessionActive = true
        bottomAnchor = UUID() // reset scroll anchor

        recognizer.start()
    }

    private func endSession(auto: Bool) {
        isSessionActive = false
        recognizer.stop()

        let duration = (sessionStart != nil) ? Date().timeIntervalSince(sessionStart!) : 0
        let acc = digitCount > 0 ? Double(correct)/Double(digitCount) : 0

        let record = SessionRecord(
            constant: constant,
            startDate: sessionStart ?? Date(),
            durationSec: duration,
            digitsRecited: digitCount,
            correct: correct,
            wrong: wrong,
            pauses: pauses,
            accuracy: acc,
            tokens: transcript
        )

        store.add(record)
        lastRecord = record
        showResults = true
    }

    private func resetSession() {
        isSessionActive = false
        recognizer.stop()
        digitCount = 0
        transcript.removeAll()
        correct = 0
        wrong = 0
        pauses = 0
        lastDigitTime = nil
        sessionStart = nil
        bottomAnchor = UUID()
    }

    // MARK: - Processing with Fuzzy Matching

    private func processIncomingDigit(_ d: String) {
        guard isSessionActive else { return }
        
        let now = Date()
        
        // Pause detection first
        if let last = lastDigitTime, now.timeIntervalSince(last) > PAUSE_THRESHOLD {
            transcript.append(GradedToken(kind: .pause))
            pauses += 1
        }
        lastDigitTime = now
        
        // Handle case where we've exceeded target length
        guard digitCount < targetDigits.count else {
            // Past the end of sequence - treat as wrong
            transcript.append(GradedToken(kind: .digit(d: d, correct: false)))
            wrong += 1
            digitCount += 1
            
            if wrong >= 10 {
                endSession(auto: true)
                return
            }
            return
        }
        
        // Fuzzy matching with 2-digit lookahead window
        let lookAheadWindow = 2
        let maxLookAhead = min(lookAheadWindow, targetDigits.count - digitCount)
        var found = false
        
        for i in 0..<maxLookAhead {
            let checkIndex = digitCount + i
            if d == targetDigits[checkIndex] {
                
                // Add missed digits as "recognition gaps" 
                for missedIndex in digitCount..<checkIndex {
                    let missedDigit = targetDigits[missedIndex]
                    transcript.append(GradedToken(kind: .digit(d: missedDigit, correct: false)))
                    // Count these as wrong in stats but don't trigger session end
                    wrong += 1
                }
                
                // Mark current digit as correct
                transcript.append(GradedToken(kind: .digit(d: d, correct: true)))
                correct += 1
                digitCount = checkIndex + 1
                found = true
                break
            }
        }
        
        if !found {
            // This is a genuine user error
            transcript.append(GradedToken(kind: .digit(d: d, correct: false)))
            wrong += 1
            digitCount += 1
            
            // Auto-end only on genuine errors, not recognition gaps
            if wrong >= 10 {
                endSession(auto: true)
                return
            }
        }
    }

    // MARK: - Transcript rendering (AttributedString so it wraps downward)

    private func attributedTokens(_ tokens: [GradedToken]) -> AttributedString {
        var result = AttributedString("")
        for t in tokens {
            switch t.kind {
            case .digit(let d, let ok):
                var chunk = AttributedString(d)
                chunk.foregroundColor = ok ? .green : .red
                result.append(chunk)
            case .pause:
                var dash = AttributedString("–")
                dash.foregroundColor = .orange
                result.append(dash)
            }
        }
        return result
    }
}

// MARK: - UI Bits

struct StatBox: View {
    let title: String
    let value: String
    let color: Color
    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            Text(value).font(.title2).bold().foregroundColor(color)
        }
        .frame(width: 120)
    }
}

struct SessionRow: View {
    let record: SessionRecord
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(record.constant.title) • \(fmtDate(record.startDate))")
                    .font(.subheadline).foregroundColor(.secondary)
                Text("Recited: \(record.digitsRecited)  •  Correct: \(record.correct)  •  Wrong: \(record.wrong)  •  Pauses: \(record.pauses)")
                    .font(.footnote)
                Text("Accuracy: \(Int(round(record.accuracy * 100)))%  •  Time: \(fmtDuration(record.durationSec))")
                    .font(.footnote)
            }
            Spacer()
        }
        .padding(8)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
    }
}

struct ResultsView: View {
    let record: SessionRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Session Results").font(.title).bold()
            Text("\(record.constant.title) • \(fmtDate(record.startDate))")
                .foregroundColor(.secondary)

            HStack(spacing: 20) {
                StatBox(title: "Recited", value: "\(record.digitsRecited)", color: .yellow)
                StatBox(title: "Correct", value: "\(record.correct)", color: .green)
                StatBox(title: "Wrong",   value: "\(record.wrong)",   color: .red)
                StatBox(title: "Pauses",  value: "\(record.pauses)",  color: .orange)
            }

            Text("Accuracy: \(Int(round(record.accuracy * 100)))%  •  Time: \(fmtDuration(record.durationSec))")
                .font(.headline)

            Divider().padding(.vertical, 4)

            Text("Transcript").font(.headline)

            ScrollView(.vertical) {
                Text(attributedTokens(record.tokens))
                    .font(.title2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding()
    }

    private func attributedTokens(_ tokens: [GradedToken]) -> AttributedString {
        var result = AttributedString("")
        for t in tokens {
            switch t.kind {
            case .digit(let d, let ok):
                var chunk = AttributedString(d)
                chunk.foregroundColor = ok ? .green : .red
                result.append(chunk)
            case .pause:
                var dash = AttributedString("–")
                dash.foregroundColor = .orange
                result.append(dash)
            }
        }
        return result
    }
}

// MARK: - Helpers

func fmtDate(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f.string(from: d)
}

func fmtDuration(_ seconds: Double) -> String {
    let ms = Int((seconds * 1000).rounded()) % 1000
    let s  = Int(seconds) % 60
    let m  = (Int(seconds) / 60) % 60
    let h  = Int(seconds) / 3600
    return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
}

// MARK: - Preview

#Preview { ContentView() }
