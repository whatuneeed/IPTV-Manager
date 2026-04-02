module("luci.controller.iptv-manager", package.seeall)

function index()
    entry({"admin", "services", "iptv-manager"}, alias("admin", "services", "iptv-manager", "playlist"), _("IPTV Manager"), 30).dependent = true
    entry({"admin", "services", "iptv-manager", "playlist"}, cbi("iptv-manager/playlist"), _("Плейлист"), 1)
    entry({"admin", "services", "iptv-manager", "epg"}, cbi("iptv-manager/epg"), _("Телепрограмма"), 2)
    entry({"admin", "services", "iptv-manager", "schedule"}, cbi("iptv-manager/schedule"), _("Расписание"), 3)
    entry({"admin", "services", "iptv-manager", "security"}, cbi("iptv-manager/security"), _("Безопасность"), 4)
    entry({"admin", "services", "iptv-manager", "channels"}, template("iptv-manager/channels"), _("Каналы"), 5)
    entry({"admin", "services", "iptv-manager", "player"}, template("iptv-manager/player"), _("Плеер"), 6)
end
