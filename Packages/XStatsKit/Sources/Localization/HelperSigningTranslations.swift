// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

extension L10n {
    /// 安全补丁分支早于九语言 enum；使用稳定的持久化值，同时覆盖主分支的语言。
    public static var helperSigningMessage: String {
        switch language.rawValue {
        case "chinese": "辅助工具需要团队签名；当前构建不支持风扇和合盖控制，维护操作可使用管理员授权。"
        case "traditionalChinese": "輔助工具需要團隊簽名；目前版本不支援風扇和合蓋控制，維護操作可使用管理員授權。"
        case "japanese": "ヘルパーにはチーム署名が必要です。このビルドではファン・蓋閉じ制御は使えません。メンテナンスは管理者認証で実行できます。"
        case "korean": "보조 도구에는 팀 서명이 필요합니다. 이 빌드에서는 팬 및 덮개 제어를 사용할 수 없으며 유지 관리 작업은 관리자 인증으로 실행할 수 있습니다."
        case "german": "Das Hilfsprogramm benötigt eine Teamsignatur. Lüfter- und Deckelsteuerung sind in diesem Build nicht verfügbar; Wartungsaufgaben können die Administratorfreigabe verwenden."
        case "spanish": "El asistente requiere una firma de equipo. Este compilado no permite controlar ventiladores ni la tapa; el mantenimiento puede usar autorización de administrador."
        case "french": "L’assistant nécessite une signature d’équipe. Le contrôle des ventilateurs et du capot est indisponible dans cette version ; la maintenance peut utiliser une autorisation administrateur."
        case "arabic": "تتطلب الأداة المساعدة توقيع فريق. لا يتوفر التحكم بالمراوح والغطاء في هذا الإصدار؛ يمكن تنفيذ الصيانة بتفويض المسؤول."
        default: "The helper requires team signing. Fan and lid-closed controls are unavailable in this build; maintenance can use administrator authorization."
        }
    }
}
