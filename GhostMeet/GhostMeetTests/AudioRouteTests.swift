import Foundation
import Testing
@testable import GhostMeet

/// Классификация маршрута звука по свойствам устройств.
///
/// Все наборы свойств здесь — настоящие, снятые `routeprobe` на целевой машине,
/// а не выдуманные. Это существенно: из четырёх устройств вывода на ней
/// опознаётся ровно одно, и весь смысл типа в том, чтобы честно сказать
/// «неизвестно» про остальные три, а не угадать.
@Suite("Маршрут звука: классификация")
struct AudioRouteTests {

    // MARK: - Настоящие устройства с машины пользователя

    private var builtInSpeakers: AudioEndpoint {
        AudioEndpoint(name: "Динамики MacBook Air", transport: "bltn", dataSource: "ispk")
    }

    private var builtInMicrophone: AudioEndpoint {
        AudioEndpoint(name: "Микрофон MacBook Air", transport: "bltn", dataSource: "imic")
    }

    /// Наушники в разъёме. Единственный набор здесь, снятый не с машины:
    /// проводных наушников в момент замера не было. См. `isHeadphoneJack`.
    private var headphoneJack: AudioEndpoint {
        AudioEndpoint(name: "Внешние наушники", transport: "bltn", dataSource: "hdpn")
    }

    private var bluetoothHeadset: AudioEndpoint {
        AudioEndpoint(name: "HUAWEI FreeBuds 5i", transport: "blue", dataSource: nil)
    }

    private var blackHole: AudioEndpoint {
        AudioEndpoint(name: "BlackHole 16ch", transport: "virt", dataSource: nil)
    }

    private var teamsAudio: AudioEndpoint {
        // `dataSource` из четырёх пробелов — ровно так его печатает драйвер.
        AudioEndpoint(name: "Microsoft Teams Audio", transport: "virt", dataSource: "    ")
    }

    private var aggregate: AudioEndpoint {
        AudioEndpoint(name: "Агрегатное устройство", transport: "grup", dataSource: nil)
    }

    // MARK: - Три ответа

    @Test("Встроенный микрофон и встроенные динамики — опасный маршрут")
    func builtInPairIsLeaky() {
        let route = AudioRoute.classify(input: builtInMicrophone, output: builtInSpeakers)

        #expect(route == .leaky(input: builtInMicrophone, output: builtInSpeakers))
        #expect(route.mayLeak)
        #expect(route.isCertainlyLeaky)
        #expect(route.notice != nil)
    }

    @Test("Наушники в разъёме — маршрут безопасный, строгий режим не нужен")
    func headphonesAreSafe() {
        let route = AudioRoute.classify(input: builtInMicrophone, output: headphoneJack)

        #expect(route == .safe(output: headphoneJack))
        #expect(!route.mayLeak)
        // Единственный случай, когда окну сказать нечего: не течёт и не гадаем.
        #expect(route.notice == nil)
    }

    @Test("Гарнитура на обоих концах — безопасно: одно устройство не бывает и в комнате, и в ушах")
    func oneDeviceOnBothEndsIsAHeadset() {
        let route = AudioRoute.classify(input: bluetoothHeadset, output: bluetoothHeadset)

        // Без этого правила самые распространённые наушники — Bluetooth —
        // навсегда остаются «неизвестными», а неизвестность включает строгий
        // режим. Пользователь терял бы начало каждого ответа, начатого поверх
        // собеседника, весь звонок и в конфигурации, где не течёт вовсе.
        #expect(route == .safe(output: bluetoothHeadset))
        #expect(!route.mayLeak)
        #expect(route.notice == nil)
    }

    @Test("Одно имя на обоих концах — ещё не гарнитура: агрегат и виртуальное устройство не считаются")
    func onlyAPeripheralBusCountsAsAHeadset() {
        // Агрегат может обёртывать те же встроенные динамики с микрофоном, а
        // виртуальное устройство про комнату не говорит ничего. Обе проверки
        // здесь потому, что правило «одно устройство на обоих концах» без
        // ограничения по шине объявило бы безопасным самый громкий маршрут.
        for device in [aggregate, blackHole] {
            let route = AudioRoute.classify(input: device, output: device)
            #expect(route.mayLeak, "«\(device.name)» — не гарнитура")
            #expect(!route.isCertainlyLeaky)
        }
    }

    @Test("Микрофон на столе рядом с динамиками остаётся опасным: концы разные")
    func aDeskMicrophoneNextToSpeakersIsNotSafe() {
        let deskMic = AudioEndpoint(name: "Yeti", transport: "usb", dataSource: nil)
        let route = AudioRoute.classify(input: deskMic, output: builtInSpeakers)

        #expect(route.mayLeak, "USB-микрофон и динамики — два устройства, звук идёт через комнату")
    }

    @Test("Виртуальное устройство неизвестно, даже когда транспорт прочитан")
    func virtualDeviceIsUnknown() {
        for device in [blackHole, teamsAudio] {
            let route = AudioRoute.classify(input: builtInMicrophone, output: device)
            #expect(route.mayLeak)
            #expect(!route.isCertainlyLeaky)
        }
    }

    @Test("Агрегатное устройство на выходе неизвестно")
    func aggregateIsUnknown() {
        let route = AudioRoute.classify(input: builtInMicrophone, output: aggregate)

        #expect(route.mayLeak)
        #expect(!route.isCertainlyLeaky)
    }

    @Test("dataSource из пробелов — это отсутствие значения, а не значение")
    func blankDataSourceIsNoValue() {
        #expect(teamsAudio.dataSource == nil)
        #expect(AudioEndpoint(name: "x", transport: "usb ", dataSource: "").dataSource == nil)
        // Хвостовые пробелы четырёхбуквенного кода не мешают сравнению.
        #expect(AudioEndpoint(name: "x", transport: "usb ", dataSource: nil).transport == "usb")
    }

    @Test("Динамики при неопознанном микрофоне — приговор не выносим")
    func speakersWithUnknownMicrophoneStayUnknown() {
        // Микрофон гарнитуры эхо почти не ловит, микрофон на столе ловит целиком,
        // и различить их нечем. Поэтому — «неизвестно», но строгий режим включён.
        let route = AudioRoute.classify(input: bluetoothHeadset, output: builtInSpeakers)

        #expect(!route.isCertainlyLeaky)
        #expect(route.mayLeak)
        // Про то, что звук всё-таки идёт в комнату, сказать при этом можно.
        #expect(route.notice?.contains("динамики") == true)
    }

    @Test("Наушники решают вопрос сами, каким бы ни был микрофон")
    func headphonesOutrankTheMicrophone() {
        let route = AudioRoute.classify(input: bluetoothHeadset, output: headphoneJack)

        #expect(!route.mayLeak)
    }

    @Test("Пустой маршрут — неизвестный и опасный")
    func nothingReadIsUnknown() {
        let route = AudioRoute.classify(input: nil, output: nil)

        #expect(route == .unread)
        #expect(route.mayLeak)
        #expect(route.notice != nil)
    }

    @Test("Каждый ответ умеет назвать себя для журнала")
    func everyRouteHasASummary() {
        #expect(AudioRoute.safe(output: headphoneJack).summary.contains("безопасный"))
        #expect(
            AudioRoute.leaky(input: builtInMicrophone, output: builtInSpeakers)
                .summary.contains("Динамики MacBook Air")
        )
        #expect(AudioRoute.unread.summary.contains("неизвестный"))
    }
}

/// Слежение за маршрутом: чтение, подписка и то, что монитор отдаёт наружу.
@Suite("Маршрут звука: слежение")
struct AudioRouteMonitorTests {

    /// Источник, которым распоряжается тест: устройства меняются вызовом, а не
    /// втыканием наушников.
    private final class FakeRouteSource: AudioRouteSource, @unchecked Sendable {

        private let lock = NSLock()
        private var snapshot: AudioRouteSnapshot
        private var handler: (@Sendable () -> Void)?
        private(set) var reads = 0
        private(set) var isObserving = false

        init(_ snapshot: AudioRouteSnapshot) {
            self.snapshot = snapshot
        }

        func read() -> AudioRouteSnapshot {
            lock.lock()
            defer { lock.unlock() }
            reads += 1
            return snapshot
        }

        func startObserving(_ onChange: @escaping @Sendable () -> Void) {
            lock.lock()
            handler = onChange
            isObserving = true
            lock.unlock()
        }

        func stopObserving() {
            lock.lock()
            handler = nil
            isObserving = false
            lock.unlock()
        }

        /// Наушники воткнули (или выдернули) посреди звонка.
        func route(becomes snapshot: AudioRouteSnapshot) {
            lock.lock()
            self.snapshot = snapshot
            let handler = self.handler
            lock.unlock()
            handler?()
        }

        /// Устройство дёрнуло свойством, но маршрут остался прежним.
        func notifyWithoutChange() {
            lock.lock()
            let handler = self.handler
            lock.unlock()
            handler?()
        }
    }

    private static let speakers = AudioRouteSnapshot(
        input: AudioEndpoint(name: "Микрофон MacBook Air", transport: "bltn", dataSource: "imic"),
        output: AudioEndpoint(name: "Динамики MacBook Air", transport: "bltn", dataSource: "ispk")
    )

    private static let headphones = AudioRouteSnapshot(
        input: AudioEndpoint(name: "Микрофон MacBook Air", transport: "bltn", dataSource: "imic"),
        output: AudioEndpoint(name: "Внешние наушники", transport: "bltn", dataSource: "hdpn")
    )

    @Test("До первого чтения маршрут считается опасным")
    func unreadRouteIsLeaky() {
        let monitor = AudioRouteMonitor(source: FakeRouteSource(Self.speakers))

        // Ещё не стартовали — ничего не прочитано.
        #expect(monitor.route == .unread)
        #expect(monitor.mayLeak)
    }

    @Test("Старт читает маршрут сразу")
    func startReadsOnce() {
        let source = FakeRouteSource(Self.headphones)
        let monitor = AudioRouteMonitor(source: source)

        monitor.start()

        #expect(!monitor.mayLeak)
        #expect(source.reads == 1)
        #expect(source.isObserving)
    }

    @Test("Наушники воткнули посреди звонка — вердикт меняется")
    func routeChangesMidCall() {
        let source = FakeRouteSource(Self.speakers)
        let monitor = AudioRouteMonitor(source: source)
        monitor.start()
        #expect(monitor.mayLeak)

        source.route(becomes: Self.headphones)

        #expect(!monitor.mayLeak)
    }

    @Test("Подписчику говорят только про изменившийся вердикт")
    func onlyChangesArePublished() {
        let source = FakeRouteSource(Self.speakers)
        let monitor = AudioRouteMonitor(source: source)
        let published = Published()
        monitor.onChange { route in published.append(route) }

        monitor.start()
        // Пачка уведомлений об одной и той же смене устройства.
        source.notifyWithoutChange()
        source.notifyWithoutChange()
        source.route(becomes: Self.headphones)

        #expect(published.routes.count == 2)
        #expect(published.routes.first?.isCertainlyLeaky == true)
        #expect(published.routes.last?.mayLeak == false)
    }

    @Test("Остановка снимает подписку")
    func stopUnsubscribes() {
        let source = FakeRouteSource(Self.speakers)
        let monitor = AudioRouteMonitor(source: source)
        monitor.start()

        monitor.stop()

        #expect(!source.isObserving)
    }

    /// Собирает опубликованные вердикты из чужого потока.
    private final class Published: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [AudioRoute] = []

        var routes: [AudioRoute] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func append(_ route: AudioRoute) {
            lock.lock()
            storage.append(route)
            lock.unlock()
        }
    }
}

/// Что маршрут делает с сессией: строгий режим и строка в окне.
@MainActor
@Suite("Маршрут звука в сессии")
struct AudioRouteSessionTests {

    private final class FixedRouteSource: AudioRouteSource, @unchecked Sendable {
        private let snapshot: AudioRouteSnapshot
        init(_ snapshot: AudioRouteSnapshot) { self.snapshot = snapshot }
        func read() -> AudioRouteSnapshot { snapshot }
        func startObserving(_ onChange: @escaping @Sendable () -> Void) {}
        func stopObserving() {}
    }

    private static let speakers = AudioRouteSnapshot(
        input: AudioEndpoint(name: "Микрофон MacBook Air", transport: "bltn", dataSource: "imic"),
        output: AudioEndpoint(name: "Динамики MacBook Air", transport: "bltn", dataSource: "ispk")
    )

    private static let headphones = AudioRouteSnapshot(
        input: AudioEndpoint(name: "Микрофон MacBook Air", transport: "bltn", dataSource: "imic"),
        output: AudioEndpoint(name: "Внешние наушники", transport: "bltn", dataSource: "hdpn")
    )

    @Test("Опасный маршрут доезжает до окна с первой отрисовки")
    func windowSeesTheRouteImmediately() {
        let controller = SessionController(engine: SessionEngine(), requestMicrophoneAccess: { false })

        controller.follow(route: AudioRouteMonitor(source: FixedRouteSource(Self.speakers)))

        #expect(controller.audioRoute?.isCertainlyLeaky == true)
    }

    @Test("Без классификатора окно про маршрут молчит")
    func withoutAClassifierTheWindowSaysNothing() {
        let controller = SessionController(engine: SessionEngine(), requestMicrophoneAccess: { false })

        // Не «неизвестно», а «никто не смотрел»: предпросмотр и тесты не должны
        // показывать предупреждение про динамики машины, которой у них нет.
        #expect(controller.audioRoute == nil)
    }

    @Test("Строгий режим слушается классификатора, а не умолчания")
    func strictModeFollowsTheClassifier() {
        let engine = SessionEngine()
        let controller = SessionController(engine: engine, requestMicrophoneAccess: { false })

        controller.follow(route: AudioRouteMonitor(source: FixedRouteSource(Self.headphones)))
        #expect(!engine.isLeakyRoute())

        controller.follow(route: AudioRouteMonitor(source: FixedRouteSource(Self.speakers)))
        #expect(engine.isLeakyRoute())
    }

    @Test("Исчезнувший монитор оставляет строгий режим включённым")
    func aGoneMonitorKeepsStrictModeOn() {
        let engine = SessionEngine()
        do {
            let controller = SessionController(engine: engine, requestMicrophoneAccess: { false })
            controller.follow(route: AudioRouteMonitor(source: FixedRouteSource(Self.headphones)))
            #expect(!engine.isLeakyRoute())
        }
        // Контроллер вместе с монитором ушёл; шов обязан вернуться к безопасной
        // стороне, а не остаться при последнем добром вердикте.
        #expect(engine.isLeakyRoute())
    }
}
