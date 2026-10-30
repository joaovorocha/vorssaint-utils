// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

struct TailscaleStrings {
    let enable: String
    let connected: String
    let stopped: String
    let needsLogin: String
    let starting: String
    let unavailable: String
    let exitNode: String
    let devices: String
    let direct: String
    let relay: String
    let offline: String
    let measureLatency: String

    /// The product name stays untranslated.
    let title = "Tailscale"

    static func localized(_ language: AppLanguage) -> Self {
        switch language {
        case .enUS: return .enUS
        case .ptBR: return .ptBR
        case .tr: return .tr
        case .ru: return .ru
        case .es: return .es
        case .sk: return .sk
        case .de: return .de
        case .fr: return .fr
        case .it: return .it
        case .ja: return .ja
        case .ko: return .ko
        case .uk: return .uk
        case .zhHans: return .zhHans
        case .zhTW: return .zhTW
        case .zhHK: return .zhHK
        }
    }
}

private extension TailscaleStrings {
    static let enUS = Self(
        enable: "Show Tailscale", connected: "Connected", stopped: "Stopped", needsLogin: "Needs login",
        starting: "Starting…", unavailable: "Tailscale status unavailable", exitNode: "Exit node",
        devices: "Devices", direct: "Direct", relay: "Relay", offline: "Offline", measureLatency: "Measure latency")
    static let ptBR = Self(
        enable: "Mostrar Tailscale", connected: "Conectado", stopped: "Parado", needsLogin: "Requer login",
        starting: "Iniciando…", unavailable: "Status do Tailscale indisponível", exitNode: "Nó de saída",
        devices: "Dispositivos", direct: "Direto", relay: "Relay", offline: "Offline", measureLatency: "Medir latência")
    static let tr = Self(
        enable: "Tailscale'i göster", connected: "Bağlı", stopped: "Durduruldu", needsLogin: "Giriş gerekli",
        starting: "Başlatılıyor…", unavailable: "Tailscale durumu alınamıyor", exitNode: "Çıkış düğümü",
        devices: "Cihazlar", direct: "Doğrudan", relay: "Aktarma", offline: "Çevrimdışı", measureLatency: "Gecikmeyi ölç")
    static let ru = Self(
        enable: "Показывать Tailscale", connected: "Подключено", stopped: "Остановлено", needsLogin: "Нужен вход",
        starting: "Запуск…", unavailable: "Статус Tailscale недоступен", exitNode: "Выходной узел",
        devices: "Устройства", direct: "Напрямую", relay: "Ретранслятор", offline: "Не в сети", measureLatency: "Измерить задержку")
    static let es = Self(
        enable: "Mostrar Tailscale", connected: "Conectado", stopped: "Detenido", needsLogin: "Requiere inicio de sesión",
        starting: "Iniciando…", unavailable: "Estado de Tailscale no disponible", exitNode: "Nodo de salida",
        devices: "Dispositivos", direct: "Directo", relay: "Relé", offline: "Sin conexión", measureLatency: "Medir latencia")
    static let sk = Self(
        enable: "Zobraziť Tailscale", connected: "Pripojené", stopped: "Zastavené", needsLogin: "Vyžaduje prihlásenie",
        starting: "Spúšťa sa…", unavailable: "Stav Tailscale nie je dostupný", exitNode: "Výstupný uzol",
        devices: "Zariadenia", direct: "Priamo", relay: "Relé", offline: "Offline", measureLatency: "Zmerať latenciu")
    static let de = Self(
        enable: "Tailscale anzeigen", connected: "Verbunden", stopped: "Gestoppt", needsLogin: "Anmeldung nötig",
        starting: "Wird gestartet…", unavailable: "Tailscale-Status nicht verfügbar", exitNode: "Exit-Node",
        devices: "Geräte", direct: "Direkt", relay: "Relay", offline: "Offline", measureLatency: "Latenz messen")
    static let fr = Self(
        enable: "Afficher Tailscale", connected: "Connecté", stopped: "Arrêté", needsLogin: "Connexion requise",
        starting: "Démarrage…", unavailable: "État de Tailscale indisponible", exitNode: "Nœud de sortie",
        devices: "Appareils", direct: "Direct", relay: "Relais", offline: "Hors ligne", measureLatency: "Mesurer la latence")
    static let it = Self(
        enable: "Mostra Tailscale", connected: "Connesso", stopped: "Arrestato", needsLogin: "Accesso richiesto",
        starting: "Avvio…", unavailable: "Stato di Tailscale non disponibile", exitNode: "Nodo di uscita",
        devices: "Dispositivi", direct: "Diretto", relay: "Relay", offline: "Offline", measureLatency: "Misura latenza")
    static let ja = Self(
        enable: "Tailscaleを表示", connected: "接続済み", stopped: "停止中", needsLogin: "ログインが必要",
        starting: "起動中…", unavailable: "Tailscaleの状態を取得できません", exitNode: "出口ノード",
        devices: "デバイス", direct: "直接", relay: "リレー", offline: "オフライン", measureLatency: "遅延を測定")
    static let ko = Self(
        enable: "Tailscale 표시", connected: "연결됨", stopped: "중지됨", needsLogin: "로그인 필요",
        starting: "시작 중…", unavailable: "Tailscale 상태를 사용할 수 없음", exitNode: "출구 노드",
        devices: "기기", direct: "직접", relay: "릴레이", offline: "오프라인", measureLatency: "지연 시간 측정")
    static let uk = Self(
        enable: "Показувати Tailscale", connected: "Під’єднано", stopped: "Зупинено", needsLogin: "Потрібен вхід",
        starting: "Запуск…", unavailable: "Стан Tailscale недоступний", exitNode: "Вихідний вузол",
        devices: "Пристрої", direct: "Напряму", relay: "Ретранслятор", offline: "Не в мережі", measureLatency: "Виміряти затримку")
    static let zhHans = Self(
        enable: "显示 Tailscale", connected: "已连接", stopped: "已停止", needsLogin: "需要登录",
        starting: "正在启动…", unavailable: "无法获取 Tailscale 状态", exitNode: "出口节点",
        devices: "设备", direct: "直连", relay: "中继", offline: "离线", measureLatency: "测量延迟")
    static let zhTW = Self(
        enable: "顯示 Tailscale", connected: "已連線", stopped: "已停止", needsLogin: "需要登入",
        starting: "正在啟動…", unavailable: "無法取得 Tailscale 狀態", exitNode: "出口節點",
        devices: "裝置", direct: "直連", relay: "中繼", offline: "離線", measureLatency: "測量延遲")
    static let zhHK = Self(
        enable: "顯示 Tailscale", connected: "已連線", stopped: "已停止", needsLogin: "需要登入",
        starting: "正在啟動…", unavailable: "無法取得 Tailscale 狀態", exitNode: "出口節點",
        devices: "裝置", direct: "直連", relay: "中繼", offline: "離線", measureLatency: "測量延遲")
}
