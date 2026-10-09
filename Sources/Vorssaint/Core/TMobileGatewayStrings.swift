// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

struct TMobileGatewayStrings {
    let title: String
    let enable: String
    let configure: String
    let save: String
    let gatewayAddress: String
    let addressHelp: String
    let loading: String
    let unavailable: String
    let invalidAddress: String
    let authenticationRequired: String
    let invalidResponse: String
    let retry: String
    let lastUpdated: String
    let firmware: String
    let uptime: String
    let roaming: String
    let registered: String
    let notRegistered: String
    let unknown: String
    let usageUnavailable: String

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

private extension TMobileGatewayStrings {
    static let enUS = Self(
        title: "T-Mobile gateway",
        enable: "Show T-Mobile gateway",
        configure: "Configure gateway",
        save: "Save address",
        gatewayAddress: "Gateway address",
        addressHelp: "Use a private IPv4 address on this local network (default: http://192.168.12.1).",
        loading: "Loading gateway status…",
        unavailable: "Gateway unavailable",
        invalidAddress: "Enter a private IPv4 gateway address.",
        authenticationRequired: "This gateway firmware requires authentication and is not supported.",
        invalidResponse: "The gateway returned an unsupported response.",
        retry: "Retry",
        lastUpdated: "Last updated",
        firmware: "Firmware",
        uptime: "Uptime",
        roaming: "Roaming",
        registered: "Registered",
        notRegistered: "Not registered",
        unknown: "Unknown",
        usageUnavailable: "Plan usage is unavailable from the local gateway API."
    )

    static let ptBR = Self(
        title: "Gateway T-Mobile",
        enable: "Mostrar gateway T-Mobile",
        configure: "Configurar gateway",
        save: "Salvar endereço",
        gatewayAddress: "Endereço do gateway",
        addressHelp: "Use um endereço IPv4 privado nesta rede local (padrão: http://192.168.12.1).",
        loading: "Carregando status do gateway…",
        unavailable: "Gateway indisponível",
        invalidAddress: "Insira um endereço IPv4 privado do gateway.",
        authenticationRequired: "O firmware deste gateway exige autenticação e não é compatível.",
        invalidResponse: "O gateway retornou uma resposta não compatível.",
        retry: "Tentar novamente",
        lastUpdated: "Última atualização",
        firmware: "Firmware",
        uptime: "Tempo de atividade",
        roaming: "Roaming",
        registered: "Registrado",
        notRegistered: "Não registrado",
        unknown: "Desconhecido",
        usageUnavailable: "O uso do plano não está disponível na API local do gateway."
    )

    static let tr = Self(
        title: "T-Mobile ağ geçidi",
        enable: "T-Mobile ağ geçidini göster",
        configure: "Ağ geçidini yapılandır",
        save: "Adresi kaydet",
        gatewayAddress: "Ağ geçidi adresi",
        addressHelp: "Bu yerel ağda özel bir IPv4 adresi kullanın (varsayılan: http://192.168.12.1).",
        loading: "Ağ geçidi durumu yükleniyor…",
        unavailable: "Ağ geçidine ulaşılamıyor",
        invalidAddress: "Özel bir IPv4 ağ geçidi adresi girin.",
        authenticationRequired: "Bu ağ geçidinin ürün yazılımı kimlik doğrulaması gerektiriyor ve desteklenmiyor.",
        invalidResponse: "Ağ geçidi desteklenmeyen bir yanıt döndürdü.",
        retry: "Yeniden dene",
        lastUpdated: "Son güncelleme",
        firmware: "Ürün yazılımı",
        uptime: "Çalışma süresi",
        roaming: "Dolaşım",
        registered: "Kayıtlı",
        notRegistered: "Kayıtlı değil",
        unknown: "Bilinmiyor",
        usageUnavailable: "Tarife kullanımı yerel ağ geçidi API’sinden alınamıyor."
    )

    static let ru = Self(
        title: "Шлюз T-Mobile",
        enable: "Показывать шлюз T-Mobile",
        configure: "Настроить шлюз",
        save: "Сохранить адрес",
        gatewayAddress: "Адрес шлюза",
        addressHelp: "Используйте частный IPv4-адрес в этой локальной сети (по умолчанию: http://192.168.12.1).",
        loading: "Загрузка состояния шлюза…",
        unavailable: "Шлюз недоступен",
        invalidAddress: "Введите частный IPv4-адрес шлюза.",
        authenticationRequired: "Прошивка этого шлюза требует аутентификации и не поддерживается.",
        invalidResponse: "Шлюз вернул неподдерживаемый ответ.",
        retry: "Повторить",
        lastUpdated: "Последнее обновление",
        firmware: "Прошивка",
        uptime: "Время работы",
        roaming: "Роуминг",
        registered: "Зарегистрирован",
        notRegistered: "Не зарегистрирован",
        unknown: "Неизвестно",
        usageUnavailable: "Использование тарифа недоступно через локальный API шлюза."
    )

    static let es = Self(
        title: "Gateway T-Mobile",
        enable: "Mostrar gateway T-Mobile",
        configure: "Configurar gateway",
        save: "Guardar dirección",
        gatewayAddress: "Dirección del gateway",
        addressHelp: "Usa una dirección IPv4 privada de esta red local (predeterminada: http://192.168.12.1).",
        loading: "Cargando estado del gateway…",
        unavailable: "Gateway no disponible",
        invalidAddress: "Introduce una dirección IPv4 privada del gateway.",
        authenticationRequired: "El firmware de este gateway requiere autenticación y no es compatible.",
        invalidResponse: "El gateway devolvió una respuesta no compatible.",
        retry: "Reintentar",
        lastUpdated: "Última actualización",
        firmware: "Firmware",
        uptime: "Tiempo de actividad",
        roaming: "Itinerancia",
        registered: "Registrado",
        notRegistered: "No registrado",
        unknown: "Desconocido",
        usageUnavailable: "El consumo del plan no está disponible en la API local del gateway."
    )

    static let sk = Self(
        title: "Brána T-Mobile",
        enable: "Zobraziť bránu T-Mobile",
        configure: "Nastaviť bránu",
        save: "Uložiť adresu",
        gatewayAddress: "Adresa brány",
        addressHelp: "Použite súkromnú adresu IPv4 v tejto lokálnej sieti (predvolená: http://192.168.12.1).",
        loading: "Načítava sa stav brány…",
        unavailable: "Brána nie je dostupná",
        invalidAddress: "Zadajte súkromnú adresu IPv4 brány.",
        authenticationRequired: "Firmvér tejto brány vyžaduje overenie a nie je podporovaný.",
        invalidResponse: "Brána vrátila nepodporovanú odpoveď.",
        retry: "Skúsiť znova",
        lastUpdated: "Posledná aktualizácia",
        firmware: "Firmvér",
        uptime: "Čas prevádzky",
        roaming: "Roaming",
        registered: "Zaregistrované",
        notRegistered: "Nezaregistrované",
        unknown: "Neznáme",
        usageUnavailable: "Spotreba dátového programu nie je dostupná cez lokálne API brány."
    )

    static let de = Self(
        title: "T-Mobile-Gateway",
        enable: "T-Mobile-Gateway anzeigen",
        configure: "Gateway konfigurieren",
        save: "Adresse speichern",
        gatewayAddress: "Gateway-Adresse",
        addressHelp: "Verwende eine private IPv4-Adresse in diesem lokalen Netzwerk (Standard: http://192.168.12.1).",
        loading: "Gateway-Status wird geladen…",
        unavailable: "Gateway nicht verfügbar",
        invalidAddress: "Gib eine private IPv4-Adresse des Gateways ein.",
        authenticationRequired: "Die Firmware dieses Gateways erfordert eine Authentifizierung und wird nicht unterstützt.",
        invalidResponse: "Das Gateway hat eine nicht unterstützte Antwort zurückgegeben.",
        retry: "Erneut versuchen",
        lastUpdated: "Zuletzt aktualisiert",
        firmware: "Firmware",
        uptime: "Betriebszeit",
        roaming: "Roaming",
        registered: "Registriert",
        notRegistered: "Nicht registriert",
        unknown: "Unbekannt",
        usageUnavailable: "Der Tarifverbrauch ist über die lokale Gateway-API nicht verfügbar."
    )

    static let fr = Self(
        title: "Passerelle T-Mobile",
        enable: "Afficher la passerelle T-Mobile",
        configure: "Configurer la passerelle",
        save: "Enregistrer l’adresse",
        gatewayAddress: "Adresse de la passerelle",
        addressHelp: "Utilisez une adresse IPv4 privée sur ce réseau local (par défaut : http://192.168.12.1).",
        loading: "Chargement de l’état de la passerelle…",
        unavailable: "Passerelle indisponible",
        invalidAddress: "Saisissez une adresse IPv4 privée pour la passerelle.",
        authenticationRequired: "Le micrologiciel de cette passerelle exige une authentification et n’est pas pris en charge.",
        invalidResponse: "La passerelle a renvoyé une réponse non prise en charge.",
        retry: "Réessayer",
        lastUpdated: "Dernière mise à jour",
        firmware: "Micrologiciel",
        uptime: "Durée de fonctionnement",
        roaming: "Itinérance",
        registered: "Enregistré",
        notRegistered: "Non enregistré",
        unknown: "Inconnu",
        usageUnavailable: "La consommation du forfait n’est pas disponible via l’API locale de la passerelle."
    )

    static let it = Self(
        title: "Gateway T-Mobile",
        enable: "Mostra gateway T-Mobile",
        configure: "Configura gateway",
        save: "Salva indirizzo",
        gatewayAddress: "Indirizzo del gateway",
        addressHelp: "Usa un indirizzo IPv4 privato su questa rete locale (predefinito: http://192.168.12.1).",
        loading: "Caricamento dello stato del gateway…",
        unavailable: "Gateway non disponibile",
        invalidAddress: "Inserisci un indirizzo IPv4 privato del gateway.",
        authenticationRequired: "Il firmware di questo gateway richiede l’autenticazione e non è supportato.",
        invalidResponse: "Il gateway ha restituito una risposta non supportata.",
        retry: "Riprova",
        lastUpdated: "Ultimo aggiornamento",
        firmware: "Firmware",
        uptime: "Tempo di attività",
        roaming: "Roaming",
        registered: "Registrato",
        notRegistered: "Non registrato",
        unknown: "Sconosciuto",
        usageUnavailable: "Il consumo del piano non è disponibile tramite l’API locale del gateway."
    )

    static let ja = Self(
        title: "T-Mobileゲートウェイ",
        enable: "T-Mobileゲートウェイを表示",
        configure: "ゲートウェイを設定",
        save: "アドレスを保存",
        gatewayAddress: "ゲートウェイのアドレス",
        addressHelp: "このローカルネットワーク上のプライベートIPv4アドレスを使用してください（既定値：http://192.168.12.1）。",
        loading: "ゲートウェイの状態を読み込み中…",
        unavailable: "ゲートウェイを利用できません",
        invalidAddress: "ゲートウェイのプライベートIPv4アドレスを入力してください。",
        authenticationRequired: "このゲートウェイのファームウェアは認証を必要とするため、対応していません。",
        invalidResponse: "ゲートウェイから未対応の応答が返されました。",
        retry: "再試行",
        lastUpdated: "最終更新",
        firmware: "ファームウェア",
        uptime: "稼働時間",
        roaming: "ローミング",
        registered: "登録済み",
        notRegistered: "未登録",
        unknown: "不明",
        usageUnavailable: "ローカルゲートウェイAPIから契約プランの使用量は取得できません。"
    )

    static let ko = Self(
        title: "T-Mobile 게이트웨이",
        enable: "T-Mobile 게이트웨이 표시",
        configure: "게이트웨이 구성",
        save: "주소 저장",
        gatewayAddress: "게이트웨이 주소",
        addressHelp: "이 로컬 네트워크의 사설 IPv4 주소를 사용하세요(기본값: http://192.168.12.1).",
        loading: "게이트웨이 상태 불러오는 중…",
        unavailable: "게이트웨이를 사용할 수 없음",
        invalidAddress: "게이트웨이의 사설 IPv4 주소를 입력하세요.",
        authenticationRequired: "이 게이트웨이의 펌웨어는 인증이 필요하여 지원되지 않습니다.",
        invalidResponse: "게이트웨이가 지원되지 않는 응답을 반환했습니다.",
        retry: "다시 시도",
        lastUpdated: "마지막 업데이트",
        firmware: "펌웨어",
        uptime: "가동 시간",
        roaming: "로밍",
        registered: "등록됨",
        notRegistered: "등록되지 않음",
        unknown: "알 수 없음",
        usageUnavailable: "로컬 게이트웨이 API에서는 요금제 사용량을 확인할 수 없습니다."
    )

    static let uk = Self(
        title: "Шлюз T-Mobile",
        enable: "Показувати шлюз T-Mobile",
        configure: "Налаштувати шлюз",
        save: "Зберегти адресу",
        gatewayAddress: "Адреса шлюзу",
        addressHelp: "Використовуйте приватну IPv4-адресу в цій локальній мережі (типова: http://192.168.12.1).",
        loading: "Завантаження стану шлюзу…",
        unavailable: "Шлюз недоступний",
        invalidAddress: "Введіть приватну IPv4-адресу шлюзу.",
        authenticationRequired: "Прошивка цього шлюзу потребує автентифікації та не підтримується.",
        invalidResponse: "Шлюз повернув непідтримувану відповідь.",
        retry: "Повторити",
        lastUpdated: "Останнє оновлення",
        firmware: "Прошивка",
        uptime: "Час роботи",
        roaming: "Роумінг",
        registered: "Зареєстровано",
        notRegistered: "Не зареєстровано",
        unknown: "Невідомо",
        usageUnavailable: "Використання тарифу недоступне через локальний API шлюзу."
    )

    static let zhHans = Self(
        title: "T-Mobile 网关",
        enable: "显示 T-Mobile 网关",
        configure: "配置网关",
        save: "保存地址",
        gatewayAddress: "网关地址",
        addressHelp: "请使用此局域网上的私有 IPv4 地址（默认：http://192.168.12.1）。",
        loading: "正在加载网关状态…",
        unavailable: "网关不可用",
        invalidAddress: "请输入网关的私有 IPv4 地址。",
        authenticationRequired: "此网关的固件需要身份验证，暂不支持。",
        invalidResponse: "网关返回了不支持的响应。",
        retry: "重试",
        lastUpdated: "上次更新",
        firmware: "固件",
        uptime: "运行时间",
        roaming: "漫游",
        registered: "已注册",
        notRegistered: "未注册",
        unknown: "未知",
        usageUnavailable: "本地网关 API 无法提供套餐用量。"
    )

    static let zhTW = Self(
        title: "T-Mobile 閘道器",
        enable: "顯示 T-Mobile 閘道器",
        configure: "設定閘道器",
        save: "儲存位址",
        gatewayAddress: "閘道器位址",
        addressHelp: "請使用此區域網路上的私人 IPv4 位址（預設：http://192.168.12.1）。",
        loading: "正在載入閘道器狀態…",
        unavailable: "閘道器無法使用",
        invalidAddress: "請輸入閘道器的私人 IPv4 位址。",
        authenticationRequired: "此閘道器的韌體需要驗證，尚不支援。",
        invalidResponse: "閘道器傳回了不支援的回應。",
        retry: "重試",
        lastUpdated: "上次更新",
        firmware: "韌體",
        uptime: "運作時間",
        roaming: "漫遊",
        registered: "已註冊",
        notRegistered: "未註冊",
        unknown: "未知",
        usageUnavailable: "本機閘道器 API 無法提供資費方案用量。"
    )

    static let zhHK = Self(
        title: "T-Mobile 閘道器",
        enable: "顯示 T-Mobile 閘道器",
        configure: "設定閘道器",
        save: "儲存位址",
        gatewayAddress: "閘道器位址",
        addressHelp: "請使用此區域網絡上的私人 IPv4 位址（預設：http://192.168.12.1）。",
        loading: "正在載入閘道器狀態…",
        unavailable: "閘道器無法使用",
        invalidAddress: "請輸入閘道器的私人 IPv4 位址。",
        authenticationRequired: "此閘道器的韌體需要認證，暫不支援。",
        invalidResponse: "閘道器傳回了不支援的回應。",
        retry: "重試",
        lastUpdated: "上次更新",
        firmware: "韌體",
        uptime: "運作時間",
        roaming: "漫遊",
        registered: "已註冊",
        notRegistered: "未註冊",
        unknown: "未知",
        usageUnavailable: "本機閘道器 API 無法提供服務計劃用量。"
    )
}
