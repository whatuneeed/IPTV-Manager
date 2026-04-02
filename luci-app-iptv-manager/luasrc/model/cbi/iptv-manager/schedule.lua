local m, s, o

m = Map("iptv", translate("Расписание обновлений"),
    translate("Автоматическое обновление плейлиста и EPG по расписанию"))

m:chain("iptv")

o = m:option(ListValue, "playlist_interval", translate("Интервал обновления плейлиста"))
o:value("0", "Выкл")
o:value("1", "Каждый час")
o:value("6", "Каждые 6 часов")
o:value("12", "Каждые 12 часов")
o:value("24", "Раз в сутки")
o.default = "0"

o = m:option(ListValue, "epg_interval", translate("Интервал обновления EPG"))
o:value("0", "Выкл")
o:value("1", "Каждый час")
o:value("6", "Каждые 6 часов")
o:value("12", "Каждые 12 часов")
o:value("24", "Раз в сутки")
o.default = "0"

return m
